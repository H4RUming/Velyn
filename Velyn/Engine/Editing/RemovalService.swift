import Foundation
import CoreML
import CoreImage

extension EditingService {
    /// AOT-GAN inference is local. Only the selected crop is synthesized; originals remain immutable.
    public func removeSelection(_ document: EditDocument,recipe: EditRecipe,maskID: UUID,modelURL: URL? = nil) throws -> RemovalPatch {
        guard let mask = recipe.enhancements.masks.first(where: { $0.id == maskID }) else { throw EditorFailure.invalidDocument }
        return try removeSelection(document,recipe: recipe,selection: mask,modelURL: modelURL)
    }
    public func removeSelection(_ document: EditDocument,recipe: EditRecipe,selection mask: LocalMask,modelURL: URL? = nil) throws -> RemovalPatch {
        try validate(document)
        guard recipe.isValid,mask.isValid,(recipe.enhancements.removals?.count ?? 0) < 30 else { throw EditorFailure.invalidDocument }
        try Task.checkCancellation()
        guard let url = modelURL ?? Bundle.main.url(forResource: "aotgan",withExtension: "mlmodelc") else { throw EditorFailure.modelUnavailable }
        let config = MLModelConfiguration(); config.computeUnits = .cpuAndGPU
        let model: MLModel
        if modelURL == nil, let cached = removalModel { model = cached }
        else {
            model = try MLModel(contentsOf: url,configuration: config)
            if modelURL == nil { removalModel = model }
        }
        var baseline = EditRecipe(); baseline.rawAdjustments = recipe.rawAdjustments; baseline.enhancements.removals = recipe.enhancements.removals
        let image = try processed(document,recipe: baseline,maxPixelSize: 2048)
        let bounds = image.extent, width = Int(bounds.width), height = Int(bounds.height)
        let selection = AdvancedPipeline.selection(mask,image: image,resources: try maskResources(recipe))
        var selectionBytes = [UInt8](repeating: 0,count: width*height)
        selectionBytes.withUnsafeMutableBytes { context.render(selection,toBitmap: $0.baseAddress!,rowBytes: width,bounds: bounds,format: .L8,colorSpace: nil) }
        var minX = width, minY = height, maxX = -1, maxY = -1, selected = 0
        for y in 0..<height { for x in 0..<width where selectionBytes[y*width+x] > 16 {
            minX = min(minX,x); maxX = max(maxX,x); minY = min(minY,y); maxY = max(maxY,y); selected += 1
        } }
        guard selected > 0, Double(selected)/Double(width*height) < 0.6 else { throw EditorFailure.removalSelection }
        let side = Double(max(maxX-minX+1,maxY-minY+1))*1.6
        let box = CGRect(x: Double(minX+maxX)/2-side/2,y: Double(height)-Double(minY+maxY)/2-side/2,width: side,height: side).integral.intersection(bounds)
        let cropped = RenderPipeline.normalized(image.cropped(to: box))
        let croppedMask = RenderPipeline.normalized(selection.cropped(to: box))
        let size = 512, count = size*size
        let transform = CGAffineTransform(scaleX: Double(size)/box.width,y: Double(size)/box.height)
        var rgb = [UInt8](repeating: 0,count: count*4), maskPixels = [UInt8](repeating: 0,count: count)
        let inputBounds = CGRect(x: 0,y: 0,width: size,height: size)
        rgb.withUnsafeMutableBytes { context.render(cropped.transformed(by: transform),toBitmap: $0.baseAddress!,rowBytes: size*4,bounds: inputBounds,format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
        maskPixels.withUnsafeMutableBytes { context.render(croppedMask.transformed(by: transform),toBitmap: $0.baseAddress!,rowBytes: size,bounds: inputBounds,format: .L8,colorSpace: nil) }
        let tensor = try MLMultiArray(shape: [1,4,512,512],dataType: .float32)
        let input = tensor.dataPointer.bindMemory(to: Float.self,capacity: count*4)
        for i in 0..<count {
            let value: Float = maskPixels[i] > 16 ? 1 : 0
            for channel in 0..<3 { input[channel*count+i] = (Float(rgb[i*4+channel])/127.5-1)*(1-value)+value }
            input[3*count+i] = value
        }
        try Task.checkCancellation()
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x_1": MLFeatureValue(multiArray: tensor)]))
        try Task.checkCancellation()
        guard let output = prediction.featureValue(for: "var_915")?.multiArrayValue,output.dataType == .float32,output.shape.map(\.intValue) == [1,3,512,512] else { throw EditorFailure.renderFailed }
        let data = output.dataPointer.bindMemory(to: Float.self,capacity: output.count)
        let strides = output.strides.map(\.intValue)
        var result = [UInt8](repeating: 255,count: count*4)
        for y in 0..<size { for x in 0..<size { for channel in 0..<3 {
            let v = data[channel*strides[1]+y*strides[2]+x*strides[3]]
            guard v.isFinite else { throw EditorFailure.renderFailed }
            result[(y*size+x)*4+channel] = UInt8(min(255,max(0,(v+1)*127.5)))
        } } }
        let repaired = CIImage(bitmapData: Data(result),bytesPerRow: size*4,size: inputBounds.size,format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let frozenMask = CIImage(bitmapData: Data(maskPixels),bytesPerRow: size,size: inputBounds.size,format: .L8,colorSpace: nil)
        let directory = package.appendingPathComponent("masks")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw EditorFailure.invalidDocument }
        let imageID = UUID(), maskID = UUID()
        let imageURL = directory.appendingPathComponent("\(imageID).png"), maskURL = directory.appendingPathComponent("\(maskID).png")
        let imageStaging = directory.appendingPathComponent(".\(imageID).png")
        let maskStaging = directory.appendingPathComponent(".\(maskID).png")
        defer { try? FileManager.default.removeItem(at: imageStaging); try? FileManager.default.removeItem(at: maskStaging) }
        do {
            try context.writePNGRepresentation(of: repaired,to: imageStaging,format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            try context.writePNGRepresentation(of: frozenMask,to: maskStaging,format: .L8,colorSpace: CGColorSpaceCreateDeviceGray())
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: imageStaging,to: imageURL)
            try FileManager.default.moveItem(at: maskStaging,to: maskURL)
            try Task.checkCancellation()
        } catch { try? FileManager.default.removeItem(at: imageURL); try? FileManager.default.removeItem(at: maskURL); throw error }
        return RemovalPatch(imageID: imageID,maskID: maskID,topLeft: .init(box.minX/bounds.width,1-box.maxY/bounds.height),bottomRight: .init(box.maxX/bounds.width,1-box.minY/bounds.height))
    }
    /// Only discard newly generated, uncommitted results rejected by the caller.
    public func discardUncommittedRemoval(_ patch: RemovalPatch) {
        for id in [patch.imageID,patch.maskID] {
            try? FileManager.default.removeItem(at: package.appendingPathComponent("masks/\(id).png"))
        }
    }
}
