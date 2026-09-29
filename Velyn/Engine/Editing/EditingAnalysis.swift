import Foundation
import CoreImage
import Vision
import ImageIO
import UniformTypeIdentifiers
import CoreText

extension EditingService {
    func maskResources(_ recipe: EditRecipe) throws -> [UUID: CIImage] {
        var result: [UUID: CIImage] = [:]
        let gainIDs = recipe.enhancements.hdrExpansion.map { [$0.resourceID] } ?? []
        let depthIDs = recipe.enhancements.depth.map { [$0.resourceID] } ?? []
        let removalIDs = (recipe.enhancements.removals ?? []).flatMap { [$0.imageID,$0.maskID] }
        for id in Set(recipe.enhancements.masks.compactMap(\.resourceID) + depthIDs + removalIDs + gainIDs) {
            let url = package.appendingPathComponent("masks/\(id.uuidString).png")
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                  let image = CIImage(contentsOf: url, options: gainIDs.contains(id) ? [.colorSpace: NSNull()] : [:]) else { throw EditorFailure.invalidDocument }
            result[id] = RenderPipeline.normalized(image)
        }
        return result
    }

    public func analyze(_ document: EditDocument, recipe: EditRecipe) throws -> ImageAnalysis {
        let image = try processed(document, recipe: recipe, maxPixelSize: 256)
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: w*h*4)
        pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: w*4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) }
        var bins = [Int](repeating: 0, count: 256), mean = 0.0, red = 0.0, green = 0.0, blue = 0.0, neutral = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i])/255, g = Double(pixels[i+1])/255, b = Double(pixels[i+2])/255
            let l = 0.2126*r+0.7152*g+0.0722*b
            bins[min(255, Int(l*255))] += 1; mean += l
            if (0.1...0.9).contains(l) && max(r,g,b)-min(r,g,b) < 0.2 { red += r; green += g; blue += b; neutral += 1 }
        }
        let count = Double(max(1, w*h)); mean /= count
        return ImageAnalysis(histogram: bins, shadows: Double(bins[0...2].reduce(0,+))/count, highlights: Double(bins[253...255].reduce(0,+))/count,
            suggestedExposure: min(2, max(-2, log2(0.42 / max(0.03, mean)))),
            suggestedWarmth: neutral > 0 ? min(60,max(-60,(blue-red)/neutral*180)) : 0,
            suggestedTint: neutral > 0 ? min(60,max(-60,(green-(red+blue)/2)/neutral*180)) : 0)
    }

    public func sampleWhiteBalance(_ document: EditDocument, recipe: EditRecipe, point: PhotoPoint) throws -> (Double, Double) {
        guard point.isValid else { throw EditorFailure.invalidDocument }
        let image = try processed(document, recipe: recipe, maxPixelSize: 512)
        let x = min(image.extent.width-1, floor(point.x*image.extent.width)), y = min(image.extent.height-1, floor((1-point.y)*image.extent.height))
        let area = CGRect(x: max(0,x-2), y: max(0,y-2), width: 5, height: 5).intersection(image.extent)
        let average = image.applyingFilter("CIAreaAverage", parameters: ["inputExtent": CIVector(cgRect: area)])
        var p = [Float](repeating: 0, count: 4)
        p.withUnsafeMutableBytes { context.render(average, toBitmap: $0.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0,y: 0,width: 1,height: 1), format: .RGBAf, colorSpace: RenderPipeline.linearSpace) }
        let r = Double(p[0]), g = Double(p[1]), b = Double(p[2]), averageL = max(0.03, (r+g+b)/3)
        return (min(100,max(-100,(b-r)/averageL*55)), min(100,max(-100,(g-(r+b)/2)/averageL*55)))
    }

    public func makeSubjectMask(_ document: EditDocument, background: Bool) throws -> LocalMask {
        try Task.checkCancellation()
        let image = try processed(document, recipe: EditRecipe(), maxPixelSize: 1024)
        guard let cg = context.createCGImage(image, from: image.extent) else { throw EditorFailure.renderFailed }
        let handler = VNImageRequestHandler(cgImage: cg)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        try Task.checkCancellation()
        guard let result = request.results?.first, !result.allInstances.isEmpty else { throw EditorFailure.noSubject }
        let buffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        let mask = CIImage(cvPixelBuffer: buffer)
        let directory = package.appendingPathComponent("masks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(), url = directory.appendingPathComponent("\(UUID().uuidString).tmp")
        let final = directory.appendingPathComponent("\(id.uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try context.writePNGRepresentation(of: mask, to: url, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: url, to: final)
        if Task.isCancelled { try? FileManager.default.removeItem(at: final); throw CancellationError() }
        var selection = LocalMask(kind: background ? .background : .subject)
        selection.resourceID = id
        return selection
    }

    public func versions() throws -> [EditVersion] {
        let url = package.appendingPathComponent("versions.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try JSONDecoder().decode([EditVersion].self, from: Data(contentsOf: url))
        guard values.count <= 100, values.allSatisfy({ $0.recipe.isValid }) else { throw EditorFailure.invalidDocument }
        return values
    }
    public func saveVersion(name: String, recipe: EditRecipe) throws -> [EditVersion] {
        guard recipe.isValid, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw EditorFailure.invalidDocument }
        var values = try versions()
        guard values.count < 100 else { throw EditorFailure.versionLimit }
        values.insert(EditVersion(name: String(name.prefix(80)), recipe: recipe), at: 0)
        try JSONEncoder().encode(values).write(to: package.appendingPathComponent("versions.json"), options: .atomic)
        return values
    }
    public func importPreset(at url: URL) throws -> [UserPreset] {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 2_000_000 else { throw EditorFailure.invalidDocument }
        let preset = try JSONDecoder().decode(UserPreset.self, from: Data(contentsOf: url))
        return try savePreset(UserPreset(name: preset.name, recipe: preset.recipe))
    }
    public func exportPreset(_ recipe: EditRecipe, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Velyn-Preset-\(UUID()).velynpreset")
        try JSONEncoder().encode(UserPreset(name: name, recipe: recipe)).write(to: url, options: .atomic)
        return url
    }
    public func deletePreset(_ id: UUID) throws -> [UserPreset] {
        var values = try presets(); values.removeAll { $0.id == id }
        try JSONEncoder().encode(values).write(to: root.appendingPathComponent("presets.json"), options: .atomic)
        return values
    }
    public func renderDetail(_ document: EditDocument, center: PhotoPoint, side: Int = 768) throws -> PhotoPreview {
        try Task.checkCancellation()
        let image = try processed(document, recipe: document.history.current, maxPixelSize: nil)
        let size = min(Double(side), image.extent.width, image.extent.height)
        let x = min(max(0, center.x*image.extent.width-size/2), image.extent.width-size)
        let y = min(max(0, (1-center.y)*image.extent.height-size/2), image.extent.height-size)
        let cg = try displayImage(image,bounds: CGRect(x: x,y: y,width: size,height: size),hdr: document.history.current.enhancements.hdr)
        try Task.checkCancellation(); return PhotoPreview(image: cg)
    }

    func watermarked(_ image: CIImage, text: String) -> CIImage {
        guard !text.isEmpty else { return image }
        let w = Int(image.extent.width), h = Int(image.extent.height)
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(max(w,h))/45, nil)
        let value = NSAttributedString(string: String(text.prefix(80)), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1,alpha: 0.8)])
        let line = CTLineCreateWithAttributedString(value)
        let length = CTLineGetTypographicBounds(line, nil,nil,nil)
        cg.textPosition = CGPoint(x: max(16, Double(w)-length-Double(w)/30), y: Double(h)/30)
        cg.setShadow(offset: CGSize(width: 1,height: -1), blur: 3, color: CGColor(gray: 0,alpha: 0.8))
        CTLineDraw(line,cg)
        guard let overlay = cg.makeImage() else { return image }
        return CIImage(cgImage: overlay).composited(over: image)
    }
}

extension EditingService {
    @available(iOS 27,macOS 27,*)
    public func prepareSelectionAssets() async throws {
        // Only invoked by the explicit in-app model preparation button. No photo is passed here.
        let request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: 0.5,y: 0.5))
        try await request.downloadAssets()
    }
    @available(iOS 27,macOS 27,*)
    public func makePointMask(_ document: EditDocument,points: [PhotoPoint],excluding: [PhotoPoint]) async throws -> LocalMask {
        guard let first = points.first,points.count+excluding.count <= 20,points.allSatisfy(\.isValid),excluding.allSatisfy(\.isValid) else { throw EditorFailure.invalidDocument }
        let request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: first.x,y: 1-first.y))
        guard await request.assetStatus == .ready else { throw EditorFailure.selectionAssetsUnavailable }
        request.qualityLevel = .accurate
        for point in points.dropFirst() { try request.addIncludedPoint(NormalizedPoint(x: point.x,y: 1-point.y)) }
        for point in excluding { try request.addExcludedPoint(NormalizedPoint(x: point.x,y: 1-point.y)) }
        let image = try processed(document,recipe: EditRecipe(),maxPixelSize: 1536)
        guard let cg = context.createCGImage(image,from: image.extent) else { throw EditorFailure.renderFailed }
        try Task.checkCancellation()
        guard let result = try await request.perform(on: cg) else { throw EditorFailure.noSubject }
        try Task.checkCancellation()
        let maskImage = CIImage(cgImage: try result.cgImage)
        let directory = package.appendingPathComponent("masks")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let id = UUID(), url = directory.appendingPathComponent(".\(UUID()).png")
        let final = directory.appendingPathComponent("\(id).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try context.writePNGRepresentation(of: maskImage,to: url,format: .L8,colorSpace: CGColorSpaceCreateDeviceGray())
        try Task.checkCancellation(); try FileManager.default.moveItem(at: url,to: final)
        if Task.isCancelled { try? FileManager.default.removeItem(at: final); throw CancellationError() }
        var mask = LocalMask(kind: .object); mask.resourceID = id; mask.points = points; mask.excludedPoints = excluding
        return mask
    }
}
