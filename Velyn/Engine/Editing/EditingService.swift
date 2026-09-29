import Foundation
import CoreImage
import CoreML
import ImageIO
import UniformTypeIdentifiers

public actor EditingService {
    let root: URL
    let asset: SourceAsset
    let package: URL
    let original: URL
    let context = CIContext(options: [
        .workingColorSpace: RenderPipeline.linearSpace,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .memoryTarget: 256
    ])
    private let previewSources: NSCache<NSString, CIImage> = {
        let cache = NSCache<NSString, CIImage>()
        cache.countLimit = 4
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()
    private var cachedBands: [ColorBand]?
    private var cachedCube: Data?
    private var cachedCubeHDR = false
    var removalModel: MLModel?
    var gainMapModel: MLModel?
    private var lastSavedRevision = -1

    public init(root: URL, asset: SourceAsset) {
        self.root = root
        self.asset = asset
        self.package = root.appendingPathComponent(asset.id.uuidString)
        self.original = root.appendingPathComponent(asset.id.uuidString).appendingPathComponent("original/source")
    }

    public static func applicationService(asset: SourceAsset) throws -> EditingService {
        EditingService(root: try OriginalImportService.applicationRoot(), asset: asset)
    }

    public func load() async throws -> EditDocument {
        _ = try await OriginalImportService(root: root).verify(asset)
        let file = package.appendingPathComponent("edits.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let document = try JSONDecoder().decode(EditDocument.self, from: Data(contentsOf: file))
                try validate(document)
                lastSavedRevision = document.revision
                return document
            } catch { throw EditorFailure.invalidDocument }
        }
        var document = EditDocument(sourceSHA256: asset.sha256)
        if asset.isRAW {
            guard let filter = CIRAWFilter(imageURL: original),
                  let version = filter.supportedDecoderVersions.last else { throw EditorFailure.unsupportedRAW }
            filter.decoderVersion = version
            document.raw = RAWDevelopment(decoder: version.rawValue, baselineExposure: filter.baselineExposure,
                boost: filter.boostAmount, boostShadows: filter.boostShadowAmount, shadowBias: filter.shadowBias,
                temperature: filter.neutralTemperature, tint: filter.neutralTint)
        }
        try save(document)
        return document
    }

    public func save(_ document: EditDocument) throws {
        try validate(document)
        guard document.revision >= lastSavedRevision else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(document)
            try bytes.write(to: package.appendingPathComponent("edits.json"), options: .atomic)
            lastSavedRevision = document.revision
        } catch { throw EditorFailure.saveFailed }
    }

    public func render(_ document: EditDocument, recipe: EditRecipe, maxPixelSize: Int = 1536, showClipping: Bool = false, overlayMaskID: UUID? = nil) throws -> PhotoPreview {
        try validate(document)
        guard recipe.isValid else { throw EditorFailure.invalidDocument }
        try Task.checkCancellation()
        var image = try processed(document, recipe: recipe, maxPixelSize: min(max(maxPixelSize, 64), 4096))
        if let overlayMaskID, let mask = recipe.enhancements.masks.first(where: { $0.id == overlayMaskID }) {
            let selection = AdvancedPipeline.selection(mask,image: image,resources: try maskResources(recipe))
            let tint = CIImage(color: CIColor(red: 1,green: 0.05,blue: 0.05,alpha: 0.4)).cropped(to: image.extent).composited(over: image)
            image = AdvancedPipeline.blend(tint,over: image,mask: selection)
        }
        try Task.checkCancellation()
        if showClipping {
            let warningSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
            let w = Int(image.extent.width),h = Int(image.extent.height)
            var pixels = [Float](repeating: 0,count: w*h*4)
            pixels.withUnsafeMutableBytes { context.render(image,toBitmap: $0.baseAddress!,rowBytes: w*16,bounds: image.extent,format: .RGBAf,colorSpace: warningSpace) }
            for i in stride(from: 0,to: pixels.count,by: 4) {
                if max(pixels[i],pixels[i+1],pixels[i+2]) >= 0.98 { pixels[i] = pixels[i+3]; pixels[i+1] = 0; pixels[i+2] = 0 }
                else if max(pixels[i],pixels[i+1],pixels[i+2]) <= 0.003 { pixels[i] = 0; pixels[i+1] = 0.08*pixels[i+3]; pixels[i+2] = pixels[i+3] }
            }
            image = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) },bytesPerRow: w*16,size: CGSize(width: w,height: h),format: .RGBAf,colorSpace: warningSpace)
        }
        let result = try displayImage(image,bounds: image.extent,hdr: recipe.enhancements.hdr)
        try Task.checkCancellation()
        return PhotoPreview(image: result)
    }

    public func export(_ document: EditDocument, settings: ExportSettings, directory: URL) throws -> URL {
        try validate(document)
        guard settings.quality.isFinite, (0.1...1).contains(settings.quality),
              settings.longEdge.map({ (64...20_000).contains($0) }) ?? true else { throw EditorFailure.exportFailed }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if settings.format == .original {
            let rawExtension = URL(fileURLWithPath: asset.originalFilename).pathExtension
            let ext = rawExtension.isEmpty ? (asset.isRAW ? "dng" : "jpg") : String(rawExtension.prefix(12))
            let url = directory.appendingPathComponent("Velyn-original-\(UUID()).\(ext)")
            try FileManager.default.copyItem(at: original, to: url)
            if Task.isCancelled { try? FileManager.default.removeItem(at: url); throw CancellationError() }
            return url
        }
        guard !settings.hdr || settings.format.supportsHDR else { throw EditorFailure.exportFailed }
        var recipe = document.history.current
        recipe.enhancements.hdr = settings.hdr
        var image = try processed(document, recipe: recipe, maxPixelSize: nil)
        if let edge = settings.longEdge {
            let scale = min(1, Double(edge) / max(image.extent.width, image.extent.height))
            if scale < 1 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        }
        let bounds = CGRect(x: 0, y: 0, width: floor(image.extent.width), height: floor(image.extent.height))
        image = watermarked(image.cropped(to: bounds), text: settings.watermark).settingProperties([:])
        let colorSpace = CGColorSpace(name: settings.colorSpace == .sRGB ? CGColorSpace.sRGB : CGColorSpace.displayP3)!
        guard let type = UTType(settings.format.typeIdentifier), ImageFormats.encodableExportFormats.contains(settings.format) else { throw EditorFailure.exportFailed }
        if !settings.format.preservesAlpha {
            image = image.composited(over: CIImage(color: .white).cropped(to: bounds))
        }
        let name = "Velyn-\(UUID()).\(settings.format.fileExtension)"
        let temporary = directory.appendingPathComponent(".\(name)")
        let final = directory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if settings.hdr {
            let sdr: CIImage
            if recipe.enhancements.hdrExpansion != nil {
                var baseRecipe = recipe; baseRecipe.enhancements.hdr = false
                var base = try processed(document, recipe: baseRecipe, maxPixelSize: nil)
                if let edge = settings.longEdge {
                    let scale = min(1, Double(edge)/max(base.extent.width, base.extent.height))
                    if scale < 1 { base = base.transformed(by: CGAffineTransform(scaleX: scale,y: scale)) }
                }
                sdr = watermarked(base.cropped(to: bounds), text: settings.watermark)
                    .composited(over: CIImage(color: .white).cropped(to: bounds)).settingProperties([:])
            } else {
                sdr = image.applyingFilter("CIToneMapHeadroom", parameters: ["inputSourceHeadroom": 8.0, "inputTargetHeadroom": 1.0])
            }
            let options: [CIImageRepresentationOption: Any] = [.hdrImage: image, CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): settings.quality]
            if settings.format == .jpeg { try context.writeJPEGRepresentation(of: sdr, to: temporary, colorSpace: colorSpace, options: options) }
            else { try context.writeHEIFRepresentation(of: sdr, to: temporary, format: .RGBA8, colorSpace: colorSpace, options: options) }
        } else {
            let format: CIFormat = ((settings.format == .tiff && settings.tiff16Bit) || (settings.format == .png && settings.png16Bit)) ? .RGBA16 : .RGBA8
            guard let pixels = context.createCGImage(image, from: bounds, format: format, colorSpace: colorSpace),
                  let destination = CGImageDestinationCreateWithURL(temporary as CFURL, type.identifier as CFString, 1, nil) else { throw EditorFailure.exportFailed }
            CGImageDestinationAddImage(destination, pixels, [kCGImageDestinationLossyCompressionQuality: settings.quality, kCGImagePropertyOrientation: 1] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw EditorFailure.exportFailed }
        }
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              CGImageSourceGetType(source) as String? == type.identifier,
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              info[kCGImagePropertyPixelWidth as String] as? Int == Int(bounds.width),
              info[kCGImagePropertyPixelHeight as String] as? Int == Int(bounds.height),
              (info[kCGImagePropertyOrientation as String] as? Int ?? 1) == 1,
              info[kCGImagePropertyGPSDictionary as String] == nil,
              info[kCGImagePropertyProfileName as String] != nil else { throw EditorFailure.exportFailed }
        try FileManager.default.moveItem(at: temporary, to: final)
        if Task.isCancelled { try? FileManager.default.removeItem(at: final); throw CancellationError() }
        return final
    }

    public func presets() throws -> [UserPreset] {
        let url = root.appendingPathComponent("presets.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try JSONDecoder().decode([UserPreset].self, from: Data(contentsOf: url))
        guard values.allSatisfy({ $0.recipe.isValid }) else { throw EditorFailure.invalidDocument }
        return values
    }

    public func savePreset(_ preset: UserPreset) throws -> [UserPreset] {
        guard preset.recipe.isValid, !preset.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EditorFailure.invalidDocument
        }
        var values = try presets()
        values.append(preset)
        try JSONEncoder().encode(values).write(to: root.appendingPathComponent("presets.json"), options: .atomic)
        return values
    }

    func validate(_ document: EditDocument) throws {
        guard document.schemaVersion == 1, document.rendererVersion == 1, document.revision >= 0,
              document.workingSpace == "extended-linear-sRGB", document.tonePolicy == "SDR-base-v1",
              document.sourceSHA256 == asset.sha256, document.history.isValid,
              asset.relativePath == "original/source", (document.raw != nil) == asset.isRAW else {
            throw EditorFailure.invalidDocument
        }
        if let raw = document.raw {
            guard [raw.baselineExposure, raw.boost, raw.boostShadows, raw.shadowBias, raw.temperature, raw.tint].allSatisfy(\.isFinite) else {
                throw EditorFailure.invalidDocument
            }
        }
    }

    func processed(_ document: EditDocument, recipe: EditRecipe, maxPixelSize: Int?) throws -> CIImage {
        let sourceHDR = recipe.enhancements.hdr && recipe.enhancements.hdrExpansion == nil
        let developmentKey = document.raw.map { "\($0.decoder)-\($0.baselineExposure)-\($0.boost)-\($0.boostShadows)-\($0.shadowBias)-\($0.temperature)-\($0.tint)" } ?? "raster"
        let key = "\(recipe.rawAdjustments?.cacheKey ?? "")-\(sourceHDR)-\(maxPixelSize ?? 0)-\(asset.isRAW ? recipe[.exposure] : 0)-\(developmentKey)"
        let input: CIImage
        if maxPixelSize != nil, let cached = previewSources.object(forKey: key as NSString) { input = cached }
        else {
            let decoded: CIImage
            if let development = document.raw {
                let filter = try RAWDeveloper.filter(at: original,development: development,adjustments: recipe.rawAdjustments)
                filter.extendedDynamicRangeAmount = sourceHDR ? 1 : 0
                filter.exposure = Float(recipe[.exposure])
                filter.scaleFactor = maxPixelSize.map { min(1, Float($0) / Float(max(asset.pixelWidth, asset.pixelHeight))) } ?? 1
                guard let output = filter.outputImage else { throw EditorFailure.unsupportedRAW }
                decoded = output // CIRAWFilter already applies its stored EXIF orientation.
            } else {
                guard let output = CIImage(contentsOf: original, options: [
                    .applyOrientationProperty: true, .expandToHDR: sourceHDR, .toneMapHDRtoSDR: !sourceHDR
                ]) else { throw EditorFailure.renderFailed }
                decoded = output
            }
            var normalized = RenderPipeline.normalized(decoded)
            if let limit = maxPixelSize {
                let scale = min(1, Double(limit) / max(normalized.extent.width, normalized.extent.height))
                if scale < 1 { normalized = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
            }
            let rect = CGRect(x: 0, y: 0, width: floor(normalized.extent.width), height: floor(normalized.extent.height))
            let cropped = normalized.cropped(to: rect)
            if let maxPixelSize, maxPixelSize <= 1536 {
                // Materialize the decoded proxy once. A lazy CIImage can decode the original again on each draw.
                try Task.checkCancellation()
                guard let pixels = context.createCGImage(cropped,from: rect,format: .RGBAh,colorSpace: RenderPipeline.linearSpace,deferred: false) else { throw EditorFailure.renderFailed }
                input = CIImage(cgImage: pixels)
                previewSources.setObject(input,forKey: key as NSString,cost: pixels.bytesPerRow*pixels.height)
            } else { input = cropped }
        }
        let cube: Data?
        if recipe.colors.contains(where: { $0 != ColorBand() }) {
            if cachedBands != recipe.colors || cachedCubeHDR != sourceHDR { cachedCube = ColorMixer.cube(bands: recipe.colors,hdr: sourceHDR); cachedBands = recipe.colors; cachedCubeHDR = sourceHDR }
            cube = cachedCube
        } else { cube = nil }
        let resources = try maskResources(recipe)
        return RenderPipeline.apply(input, recipe: recipe, rawExposureHandled: asset.isRAW, cube: cube, resources: resources)
    }
}
