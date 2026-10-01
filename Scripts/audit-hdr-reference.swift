import Foundation
import CoreImage
import CoreML
import ImageIO
import CryptoKit

/// Local paired comparison: predict from the embedded SDR base, keep native HDR as reference.
/// Outputs stay in the explicit local directory. Never add real photo files to the repository.
@main struct HDRAudit {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Usage: hdr-audit HDR_INPUT OUTPUT_DIRECTORY MODEL_PACKAGE") }
        try await Audit().run(input: URL(fileURLWithPath: CommandLine.arguments[1]),out: URL(fileURLWithPath: CommandLine.arguments[2]),model: URL(fileURLWithPath: CommandLine.arguments[3]))
    }
}
private actor Audit {
    let context = CIContext(options: [.workingColorSpace: RenderPipeline.linearSpace,.workingFormat: CIFormat.RGBAf])
    func samples(_ image: CIImage) -> [Float] {
        let normalized = RenderPipeline.normalized(image)
        let scale = 256/max(normalized.extent.width,normalized.extent.height)
        let small = normalized.transformed(by: .init(scaleX: scale,y: scale))
        let bounds = CGRect(x: 0,y: 0,width: floor(small.extent.width),height: floor(small.extent.height))
        var values = [Float](repeating: 0,count: Int(bounds.width*bounds.height)*4)
        values.withUnsafeMutableBytes { context.render(small,toBitmap: $0.baseAddress!,rowBytes: Int(bounds.width)*16,bounds: bounds,format: .RGBAf,colorSpace: RenderPipeline.linearSpace) }
        return values
    }
    func compare(_ candidate: [Float],_ reference: [Float],base: [Float]) -> [String:Double] {
        var errors = [Double](),gains = [Double](),referenceGains = [Double](),sum = 0.0,referenceSum = 0.0
        func y(_ a: [Float],_ i: Int) -> Double { max(0,Double(a[i])*0.2126+Double(a[i+1])*0.7152+Double(a[i+2])*0.0722) }
        for i in stride(from: 0,to: min(candidate.count,reference.count),by: 4) {
            let a = y(candidate,i),b = y(reference,i),s = y(base,i)
            sum += a; referenceSum += b
            if s > 0.01 && b > 0.01 { errors.append(abs(log2(max(a,0.00001)/b))); gains.append(log2(max(a,0.00001)/s)); referenceGains.append(log2(b/s)) }
        }
        let n = Double(errors.count),ma = gains.reduce(0,+)/n,mb = referenceGains.reduce(0,+)/n
        let cov = zip(gains,referenceGains).reduce(0) { $0+($1.0-ma)*($1.1-mb) }
        let va = gains.reduce(0) { $0+pow($1-ma,2) },vb = referenceGains.reduce(0) { $0+pow($1-mb,2) }
        errors.sort()
        return ["meanAbsoluteLuminanceErrorEV":errors.reduce(0,+)/n,"p95AbsoluteLuminanceErrorEV":errors[min(errors.count-1,Int(n*0.95))],"gainCorrelation": cov/max(1e-12,sqrt(va*vb)),"meanGainEV":ma,"referenceMeanGainEV":mb,"meanLuminanceRatio":sum/referenceSum]
    }
    func run(input: URL,out: URL,model: URL) async throws {
        let initialHash = SHA256.hash(data: try Data(contentsOf: input)).map { String(format: "%02x",$0) }.joined()
        guard let reference = CIImage(contentsOf: input,options: [.applyOrientationProperty:true,.expandToHDR:true]),
              let base = CIImage(contentsOf: input,options: [.applyOrientationProperty:true,.expandToHDR:false,.toneMapHDRtoSDR:false]),reference.contentHeadroom > 1.01 else { throw EditorFailure.hdrExpansionRequiresSDR }
        try FileManager.default.createDirectory(at: out,withIntermediateDirectories: true)
        let sdrURL = out.appendingPathComponent("embedded-sdr.png")
        try context.writePNGRepresentation(of: base,to: sdrURL,format: .RGBA16,colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)
        let importer = OriginalImportService(root: out.appendingPathComponent("projects")),asset = try await importer.importFile(at: sdrURL)
        let service = EditingService(root: out.appendingPathComponent("projects"),asset: asset),document = try await service.load()
        let compiled = try await MLModel.compileModel(at: model); defer { try? FileManager.default.removeItem(at: compiled) }
        let modelBase = try await service.processed(document,recipe: EditRecipe(),maxPixelSize: 1536)
        let factor = 512/max(modelBase.extent.width,modelBase.extent.height)
        let w = Int((modelBase.extent.width*factor).rounded()),h = Int((modelBase.extent.height*factor).rounded())
        let local = modelBase.transformed(by: .init(scaleX: Double(w)/modelBase.extent.width,y: Double(h)/modelBase.extent.height))
            .transformed(by: .init(translationX: CGFloat((512-w)/2),y: CGFloat((512-h)/2))).clampedToExtent().cropped(to: CGRect(x:0,y:0,width:512,height:512))
        let thumb = modelBase.transformed(by:.init(scaleX:256/modelBase.extent.width,y:256/modelBase.extent.height))
        let localTensor = try await service.gainMapTensor(local,size:512),thumbTensor = try await service.gainMapTensor(thumb,size:256)
        try Data(bytes:localTensor.dataPointer,count:localTensor.count*4).write(to:out.appendingPathComponent("model-input.f32"))
        try Data(bytes:thumbTensor.dataPointer,count:thumbTensor.count*4).write(to:out.appendingPathComponent("thumbnail-input.f32"))
        let config = MLModelConfiguration(); config.computeUnits = .cpuOnly
        let coreModel = try MLModel(contentsOf:compiled,configuration:config)
        let predicted = try await coreModel.prediction(from: MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(multiArray:localTensor),"thumbnail":MLFeatureValue(multiArray:thumbTensor)]))
        if let tensor = predicted.featureValue(for:"log_gain")?.multiArrayValue {
            let stride = tensor.strides.map(\.intValue)
            let values = (0..<512).flatMap { y in (0..<512).map { x in tensor[y*stride[2]+x*stride[3]].floatValue } }
            try values.withUnsafeBytes { try Data($0).write(to:out.appendingPathComponent("coreml-log-gain.f32")) }
        }
        let expansion = try await service.estimateHDRExpansion(document,recipe: EditRecipe(),modelURL: compiled)
        let baseSamples = samples(base),referenceSamples = samples(reference)
        var report: [String:Any] = ["environment":"macOS engine; one real local HDR/SDR pair; no display measurements","originalSHA256":initialHash,"nativeHeadroom":reference.contentHeadroom,"protectionBlend":expansion.protectionBlend ?? -1,"SDR":compare(baseSamples,referenceSamples,base:baseSamples)]
        for mode in ["legacy","app-default","model-full"] {
            var recipe = EditRecipe(); recipe.enhancements.hdr = true; recipe.enhancements.hdrExpansion = expansion
            if mode == "legacy" { recipe.enhancements.hdrExpansion?.protectionBlend = nil; recipe.enhancements.hdrExpansion?.edgeAwareUpsampling = nil }
            if mode == "model-full" { recipe.enhancements.hdrExpansion?.strength = 1; recipe.enhancements.hdrExpansion?.maximumBoostEV = log2(5); recipe.enhancements.hdrExpansion?.protectMidtones = false }
            let image = try await service.processed(document,recipe: recipe,maxPixelSize: nil)
            report[mode] = compare(samples(image),referenceSamples,base:baseSamples)
            // Shared SDR viewing scale only, not an HDR screenshot.
            try context.writeJPEGRepresentation(of: image.applyingFilter("CIExposureAdjust",parameters:["inputEV":-2]),to:out.appendingPathComponent("\(mode)-minus2ev.jpg"),colorSpace:CGColorSpace(name:CGColorSpace.displayP3)!)
        }
        try context.writeJPEGRepresentation(of: reference.applyingFilter("CIExposureAdjust",parameters:["inputEV":-2]),to:out.appendingPathComponent("native-minus2ev.jpg"),colorSpace:CGColorSpace(name:CGColorSpace.displayP3)!)
        report["originalPreserved"] = initialHash == SHA256.hash(data: try Data(contentsOf:input)).map { String(format:"%02x",$0) }.joined()
        let data = try JSONSerialization.data(withJSONObject: report,options:[.prettyPrinted,.sortedKeys]); try data.write(to:out.appendingPathComponent("report.json")); print(String(decoding:data,as:UTF8.self))
    }
}
