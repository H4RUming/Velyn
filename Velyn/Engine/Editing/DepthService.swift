import Foundation
import CoreML
import CoreImage
import CoreVideo

extension EditingService {
    public func depthAtPoint(_ recipe: EditRecipe,point: PhotoPoint) throws -> Double {
        guard point.isValid,let depth = recipe.enhancements.depth,let map = try maskResources(recipe)[depth.resourceID] else { throw EditorFailure.invalidDocument }
        let rect = CGRect(x: min(map.extent.width-1,floor(point.x*map.extent.width)),y: min(map.extent.height-1,floor((1-point.y)*map.extent.height)),width: 1,height: 1)
        var pixel = [Float](repeating: 0,count: 4)
        pixel.withUnsafeMutableBytes { context.render(map,toBitmap: $0.baseAddress!,rowBytes: 16,bounds: rect,format: .RGBAf,colorSpace: RenderPipeline.linearSpace) }
        return min(1,max(0,Double(pixel[0])))
    }
    /// No network operations. The model is compiled into the application at build time.
    public func estimateDepth(_ document: EditDocument, modelURL: URL? = nil) throws -> DepthEffect {
        try Task.checkCancellation()
        guard let url = modelURL ?? Bundle.main.url(forResource: "DepthAnythingV2SmallF16",withExtension: "mlmodelc") else { throw EditorFailure.modelUnavailable }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator)
        configuration.computeUnits = .cpuAndGPU
        #else
        configuration.computeUnits = .all
        #endif
        let model = try MLModel(contentsOf: url,configuration: configuration)
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else { throw EditorFailure.modelUnavailable }
        let image = try processed(document,recipe: EditRecipe(),maxPixelSize: 1024)
        let w = constraint.pixelsWide, h = constraint.pixelsHigh
        var input: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,w,h,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,&input) == kCVReturnSuccess, let input else { throw EditorFailure.renderFailed }
        let resized = image.transformed(by: CGAffineTransform(scaleX: Double(w)/image.extent.width,y: Double(h)/image.extent.height))
        context.render(resized,to: input,bounds: CGRect(x: 0,y: 0,width: w,height: h),colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        try Task.checkCancellation()
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: input)]))
        try Task.checkCancellation()
        guard let buffer = result.featureValue(for: "depth")?.imageBufferValue else { throw EditorFailure.renderFailed }
        let depth = CIImage(cvPixelBuffer: buffer,options: [.colorSpace: NSNull()])
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var values = [Float](repeating: 0,count: width*height)
        values.withUnsafeMutableBytes { context.render(depth,toBitmap: $0.baseAddress!,rowBytes: width*4,bounds: depth.extent,format: .Rf,colorSpace: nil) }
        let finite = values.filter { $0.isFinite }.sorted()
        guard !finite.isEmpty else { throw EditorFailure.renderFailed }
        let low = finite[finite.count/100], high = finite[finite.count*99/100]
        let bytes = values.map { UInt8(min(255,max(0,($0.isFinite ? ($0-low)/max(0.0001,high-low) : 0)*255))) }
        // Core Image bitmap data uses top-left rows, matching the rendered buffer.
        let map = CIImage(bitmapData: Data(bytes),bytesPerRow: width,size: CGSize(width: width,height: height),format: .L8,colorSpace: nil)
        let directory = package.appendingPathComponent("masks")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let id = UUID(), staging = directory.appendingPathComponent(".\(UUID()).png"), final = directory.appendingPathComponent("\(id).png")
        defer { try? FileManager.default.removeItem(at: staging) }
        try context.writePNGRepresentation(of: map,to: staging,format: .L8,colorSpace: CGColorSpaceCreateDeviceGray())
        try Task.checkCancellation(); try FileManager.default.moveItem(at: staging,to: final)
        if Task.isCancelled { try? FileManager.default.removeItem(at: final); throw CancellationError() }
        return DepthEffect(resourceID: id)
    }
}
