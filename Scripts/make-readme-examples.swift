import Foundation
import CoreImage
import CoreML
import ImageIO

/// Reproduces README examples with the production engine. No photo upload.
/// Compile together with Velyn/Engine/**/*.swift; see Docs/Images/README.md.
@main struct ReadmeExamples {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Usage: readme-examples INPUT OUTPUT_DIRECTORY MODEL_PACKAGE") }
        try await ExampleRenderer().run(input: URL(fileURLWithPath: CommandLine.arguments[1]),
            directory: URL(fileURLWithPath: CommandLine.arguments[2]),model: URL(fileURLWithPath: CommandLine.arguments[3]))
    }
}
private actor ExampleRenderer {
    let context = CIContext(options: [.workingColorSpace: RenderPipeline.linearSpace,.workingFormat: CIFormat.RGBAf])
    func run(input: URL,directory: URL,model: URL) async throws {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let projects = directory.appendingPathComponent("projects")
        let importer = OriginalImportService(root: projects)
        let asset = try await importer.importFile(at: input)
        let service = EditingService(root: projects,asset: asset)
        var document = try await service.load()
        var settings = ExportSettings(); settings.quality = 0.94; settings.colorSpace = .displayP3
        let original = try await service.export(document,settings: settings,directory: directory)
        try FileManager.default.moveItem(at: original,to: directory.appendingPathComponent("alpine-before.jpg"))
        var recipe = EditRecipe()
        recipe[.exposure] = 0.35; recipe[.shadows] = 24; recipe[.highlights] = -20
        recipe[.contrast] = -6; recipe[.vibrance] = 16; recipe[.warmth] = 4; recipe[.clarity] = 4
        document.history.commit(recipe); document.revision += 1
        let edited = try await service.export(document,settings: settings,directory: directory)
        try FileManager.default.moveItem(at: edited,to: directory.appendingPathComponent("alpine-after.jpg"))
        try await service.save(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(document).write(to: directory.appendingPathComponent("document-sdr.json"))
        let sdr = try await service.processed(document,recipe: recipe,maxPixelSize: nil)
        let compiled = try await MLModel.compileModel(at: model)
        defer { try? FileManager.default.removeItem(at: compiled) }
        recipe.enhancements.hdrExpansion = try await service.estimateHDRExpansion(document,recipe: recipe,modelURL: compiled)
        recipe.enhancements.hdr = true
        document.history.commit(recipe); document.revision += 1; try await service.save(document)
        try encoder.encode(document).write(to: directory.appendingPathComponent("document-hdr.json"))
        let hdr = try await service.processed(document,recipe: recipe,maxPixelSize: nil)
        var exports = [[String: Any]]()
        for format in [ExportFormat.jpeg,.heic] {
            settings.hdr = true; settings.format = format
            let url = try await service.export(document,settings: settings,directory: directory)
            let final = directory.appendingPathComponent("alpine-hdr.\(format.fileExtension)")
            try FileManager.default.moveItem(at: url,to: final)
            guard let src = CGImageSourceCreateWithURL(final as CFURL,nil) else { throw EditorFailure.exportFailed }
            let hasGain = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src,0,kCGImageAuxiliaryDataTypeHDRGainMap) != nil || CGImageSourceCopyAuxiliaryDataInfoAtIndex(src,0,kCGImageAuxiliaryDataTypeISOGainMap) != nil
            guard hasGain else { throw EditorFailure.exportFailed }
            exports.append(["format":format.rawValue,"hasGainMap":hasGain,"bytes":try Data(contentsOf:final).count])
        }
        // A common fixed scale preserves relative scene brightness on SDR displays.
        // This is an explanatory exposure-normalized view, not an HDR screenshot.
        for (name,image) in [("hdr-reference-sdr.jpg",sdr),("hdr-reference-hdr.jpg",hdr)] {
            try context.writeJPEGRepresentation(of: image.applyingFilter("CIExposureAdjust",parameters:["inputEV":-2]),
                to: directory.appendingPathComponent(name),colorSpace: CGColorSpace(name:CGColorSpace.sRGB)!,
                options:[CIImageRepresentationOption(rawValue:kCGImageDestinationLossyCompressionQuality as String):0.94])
        }
        let bounds=sdr.extent,w=Int(bounds.width),h=Int(bounds.height)
        func pixels(_ image: CIImage)->[Float] {
            var p=[Float](repeating:0,count:w*h*4)
            p.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:bounds,format:.RGBAf,colorSpace:RenderPipeline.linearSpace) }
            return p
        }
        let a=pixels(sdr),b=pixels(hdr)
        var gain=[Float](repeating:0,count:w*h*4),peakGain=1.0
        for i in 0..<w*h {
            let n=i*4,denom=Double(a[n]+a[n+1]+a[n+2])
            let ratio=denom>0.0001 ? max(1,Double(b[n]+b[n+1]+b[n+2])/denom) : 1
            peakGain=max(peakGain,ratio)
            let value=Float(min(1,log2(ratio)/2))
            gain[n]=value;gain[n+1]=value;gain[n+2]=value;gain[n+3]=1
        }
        let gainImage=CIImage(bitmapData:gain.withUnsafeBytes{Data($0)},bytesPerRow:w*16,size:bounds.size,format:.RGBAf,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        try context.writePNGRepresentation(of:gainImage,to:directory.appendingPathComponent("hdr-applied-gain.png"),format:.RGBA8,colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!)
        let stats=try await service.diagnostics(document,recipe:recipe)
        _ = try await importer.verify(asset)
        // Gallery variants are genuine engine crops/grades of the same synthetic source.
        for index in 0..<3 {
            let galleryAsset = try await importer.importFile(at:input)
            let galleryService = EditingService(root:projects,asset:galleryAsset)
            var galleryDocument = try await galleryService.load()
            var variant = EditRecipe(); variant.aspect = .square; variant[.cropScale] = 55
            variant[.cropX] = [15,50,85][index]; variant[.cropY] = [30,70,45][index]
            variant[.warmth] = [-12,5,12][index]; variant[.exposure] = [0.1,0.25,0.15][index]
            galleryDocument.history.commit(variant); galleryDocument.revision += 1
            try await galleryService.save(galleryDocument)
        }
        let report:[String:Any] = ["environment":"macOS production engine; synthetic AI-generated SDR PNG; not RAW or device display validation",
            "sourceSHA256":asset.sha256,"width":w,"height":h,"adjustments":["exposure":0.35,"shadows":24,"highlights":-20,"contrast":-6,"vibrance":16,"warmth":4,"clarity":4],
            "adaptiveProtectionBlend":recipe.enhancements.hdrExpansion?.protectionBlend ?? -1,"edgeAwareUpsampling":recipe.enhancements.hdrExpansion?.edgeAwareUpsampling == true,"hdrStrength":0.75,"maximumGain":4,"protectMidtones":true,"measuredPeakGain":peakGain,
            "hdrPeakChannel":stats.peak,"aboveSDRFraction":stats.aboveSDRFraction,"exports":exports,
            "comparisonExposureEV":-2,"gainVisualization":"black=1x, white=4x; log2 scale; effective applied gain",
            "originalPreserved":true,"assetID":asset.id.uuidString]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("report.json"))
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
