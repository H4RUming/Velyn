import Foundation
import CoreImage
import CoreML
import CryptoKit

/// Export private, aligned float fixtures and production renders for local research.
/// Compile with the engine sources. Never commit the output directory or manifest.
@main struct PrepareHDRExperiments {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Usage: prepare-hdr MANIFEST OUTPUT MODEL_PACKAGE") }
        try await Preparation().run(manifest: URL(fileURLWithPath: CommandLine.arguments[1]), output: URL(fileURLWithPath: CommandLine.arguments[2]), model: URL(fileURLWithPath: CommandLine.arguments[3]))
    }
}

private actor Preparation {
    struct Input: Decodable { let id: String; let group: String; let input: String }
    let context = CIContext(options: [.workingColorSpace: RenderPipeline.linearSpace, .workingFormat: CIFormat.RGBAf])
    let fm = FileManager.default
    func rgba(_ image: CIImage, width: Int, height: Int, space: CGColorSpace) -> [Float] {
        let image = RenderPipeline.normalized(image)
        let small = image.transformed(by: .init(scaleX: Double(width)/image.extent.width,y: Double(height)/image.extent.height))
        var pixels = [Float](repeating: 0,count: width*height*4)
        pixels.withUnsafeMutableBytes { context.render(small,toBitmap: $0.baseAddress!,rowBytes: width*16,bounds: CGRect(x:0,y:0,width:width,height:height),format:.RGBAf,colorSpace:space) }
        return pixels
    }
    func save(_ pixels: [Float], _ url: URL) throws {
        try pixels.withUnsafeBytes { try Data($0).write(to:url,options:.atomic) }
    }
    func run(manifest: URL,output: URL,model: URL) async throws {
        let inputs = try JSONDecoder().decode([Input].self,from:Data(contentsOf:manifest))
        let compiled = try await MLModel.compileModel(at:model)
        defer { try? fm.removeItem(at:compiled) }
        for row in inputs {
            guard !row.id.isEmpty,row.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { fatalError("Invalid ID") }
            let directory = output.appendingPathComponent(row.id,isDirectory:true)
            if fm.fileExists(atPath:directory.appendingPathComponent("prepared.json").path) { print("Cached \(row.id)"); continue }
            try fm.createDirectory(at:directory,withIntermediateDirectories:true)
            let source = URL(fileURLWithPath:row.input)
            let digest = SHA256.hash(data:try Data(contentsOf:source))
            guard let reference = CIImage(contentsOf:source,options:[.applyOrientationProperty:true,.expandToHDR:true]),
                  let base = CIImage(contentsOf:source,options:[.applyOrientationProperty:true,.expandToHDR:false,.toneMapHDRtoSDR:false]),reference.contentHeadroom > 1.01 else { fatalError("Not an HDR pair: \(row.id)") }
            let sdr = directory.appendingPathComponent("embedded-sdr.png")
            try context.writePNGRepresentation(of:base,to:sdr,format:.RGBA16,colorSpace:CGColorSpace(name:CGColorSpace.displayP3)!)
            let root = directory.appendingPathComponent("projects")
            let importer = OriginalImportService(root:root),asset = try await importer.importFile(at:sdr)
            let service = EditingService(root:root,asset:asset),document = try await service.load()
            let proxy = try await service.processed(document,recipe:EditRecipe(),maxPixelSize:1536)
            let w = Int(proxy.extent.width),h = Int(proxy.extent.height)
            let sw = max(1,Int(floor(512*base.extent.width/max(base.extent.width,base.extent.height))))
            let sh = max(1,Int(floor(512*base.extent.height/max(base.extent.width,base.extent.height))))
            try save(rgba(proxy,width:w,height:h,space:CGColorSpace(name:CGColorSpace.sRGB)!),directory.appendingPathComponent("source-srgb.f32"))
            try save(rgba(proxy,width:256,height:256,space:CGColorSpace(name:CGColorSpace.sRGB)!),directory.appendingPathComponent("thumbnail-srgb.f32"))
            try save(rgba(base,width:sw,height:sh,space:RenderPipeline.linearSpace),directory.appendingPathComponent("base.f32"))
            try save(rgba(reference,width:sw,height:sh,space:RenderPipeline.linearSpace),directory.appendingPathComponent("reference.f32"))
            let start = ContinuousClock.now
            let expansion = try await service.estimateHDRExpansion(document,recipe:EditRecipe(),modelURL:compiled)
            let elapsed = start.duration(to:.now)
            var variants:[String:HDRExpansion] = [:]
            variants["v11"] = expansion
            var legacy = expansion; legacy.protectionBlend = nil; legacy.edgeAwareUpsampling = nil; variants["legacy"] = legacy
            var bilinear = expansion; bilinear.edgeAwareUpsampling = nil; variants["v11-bilinear"] = bilinear
            var full = expansion; full.protectMidtones = false; full.strength = 1; full.maximumBoostEV = log2(5); variants["full-edge"] = full
            full.edgeAwareUpsampling = nil; variants["full-bilinear"] = full
            for (name,value) in variants {
                var recipe = EditRecipe(); recipe.enhancements.hdr = true; recipe.enhancements.hdrExpansion = value
                let rendered = try await service.processed(document,recipe:recipe,maxPixelSize:nil)
                try save(rgba(rendered,width:sw,height:sh,space:RenderPipeline.linearSpace),directory.appendingPathComponent(name+".f32"))
            }
            let mapURL = root.appendingPathComponent(asset.id.uuidString).appendingPathComponent("masks/\(expansion.resourceID).png")
            guard let map = CIImage(contentsOf:mapURL,options:[.colorSpace:NSNull()]) else { fatalError("Missing numeric map") }
            try save(rgba(map,width:Int(map.extent.width),height:Int(map.extent.height),space:RenderPipeline.linearSpace),directory.appendingPathComponent("map.f32"))
            let preserved = digest == SHA256.hash(data:try Data(contentsOf:source))
            guard preserved else { fatalError("Original changed") }
            let report:[String:Any] = ["id":row.id,"group":row.group,"width":w,"height":h,"sampleWidth":sw,"sampleHeight":sh,"mapWidth":Int(map.extent.width),"mapHeight":Int(map.extent.height),"protectionBlend":expansion.protectionBlend ?? 0,"nativeHeadroom":reference.contentHeadroom,"originalPreserved":preserved,"predictionSeconds":Double(elapsed.components.seconds)+Double(elapsed.components.attoseconds)/1e18,"environment":"macOS Core Image/Core ML; not device display or timing evidence"]
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("prepared.json"),options:.atomic)
            print("Prepared \(row.id) \(sw)x\(sh)")
            fflush(stdout)
        }
    }
}
