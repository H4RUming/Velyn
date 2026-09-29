import Testing
import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers
@testable import VelynEngine

struct EditingTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VelynEditor-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func fixture(_ base: URL, orientation: Int = 1) async throws -> SourceAsset {
        let source = base.appendingPathComponent("photo.jpg")
        let context = CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8, bytesPerRow: 320,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<80 {
            context.setFillColor(CGColor(red: CGFloat(x) / 100, green: 0.3, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: 60))
        }
        let destination = CGImageDestinationCreateWithURL(source as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 35.0, kCGImagePropertyGPSLatitudeRef: "N"]
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return try await OriginalImportService(root: base.appendingPathComponent("projects")).importFile(at: source)
    }

    @Test func linearExposureAndNeutralRecipe() throws {
        let rgba: [Float] = [0.1, 0.2, 0.3, 1]
        let data = rgba.withUnsafeBytes { Data($0) }
        let source = CIImage(bitmapData: data, bytesPerRow: 16, size: CGSize(width: 1, height: 1),
                             format: .RGBAf, colorSpace: RenderPipeline.linearSpace)
        let context = CIContext(options: [.workingColorSpace: RenderPipeline.linearSpace, .workingFormat: CIFormat.RGBAf])
        for exposure in [0.0, 1.0, -1.0] {
            var recipe = EditRecipe(); recipe[.exposure] = exposure
            let result = RenderPipeline.apply(source, recipe: recipe, rawExposureHandled: false, cube: nil)
            var pixels = [Float](repeating: 0, count: 4)
            pixels.withUnsafeMutableBytes { buffer in
                context.render(result, toBitmap: buffer.baseAddress!, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBAf, colorSpace: RenderPipeline.linearSpace)
            }
            for i in 0..<3 { #expect(abs(pixels[i] - rgba[i] * Float(pow(2, exposure))) < 0.001) }
            #expect(abs(pixels[3] - 1) < 0.0001)
        }
    }

    @Test func historyGroupsOneCommittedGestureAndSurvivesCoding() throws {
        var history = EditHistory()
        var recipe = EditRecipe()
        for value in 0..<100 { recipe[.contrast] = Double(value) }
        history.commit(recipe)
        #expect(history.undoStack.count == 1)
        history.undo(); #expect(history.current == EditRecipe())
        history.redo(); #expect(history.current[.contrast] == 99)
        let restored = try JSONDecoder().decode(EditHistory.self, from: JSONEncoder().encode(history))
        #expect(restored == history)
        history.undo(); recipe[.contrast] = 10; history.commit(recipe)
        #expect(history.redoStack.isEmpty)
    }

    @Test func persistenceReopenAndRevisionOrdering() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let asset = try await fixture(base)
        let root = base.appendingPathComponent("projects")
        let service = EditingService(root: root, asset: asset)
        let initial = try await service.load()
        var changed = initial
        var recipe = EditRecipe(); recipe[.exposure] = 1.25
        changed.history.commit(recipe); changed.revision = 1
        try await service.save(changed)
        try await service.save(initial) // Delayed saves must never overwrite a newer revision.
        let reopened = try await EditingService(root: root, asset: asset).load()
        #expect(reopened == changed)
        #expect(try await OriginalImportService(root: root).verify(asset) == asset)
    }

    @Test func corruptOrFutureDocumentIsPreserved() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let asset = try await fixture(base)
        let root = base.appendingPathComponent("projects")
        let file = root.appendingPathComponent("\(asset.id)/edits.json")
        let bytes = Data("{\"schemaVersion\":999}".utf8)
        try bytes.write(to: file)
        await #expect(throws: EditorFailure.self) { try await EditingService(root: root, asset: asset).load() }
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test(arguments: [ExportFormat.jpeg, .heic])
    func fullResolutionExportStripsGPSAndPreservesOriginal(format: ExportFormat) async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let asset = try await fixture(base, orientation: 6)
        let root = base.appendingPathComponent("projects")
        let service = EditingService(root: root, asset: asset)
        var document = try await service.load()
        var recipe = EditRecipe(); recipe[.exposure] = 0.5; recipe[.vibrance] = 20
        document.history.commit(recipe); document.revision = 1
        let preview = try await service.render(document, recipe: recipe, maxPixelSize: 64)
        #expect(max(preview.image.width, preview.image.height) <= 64)
        var settings = ExportSettings(); settings.format = format; settings.colorSpace = .displayP3
        let url = try await service.export(document, settings: settings, directory: base.appendingPathComponent("exports"))
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 60)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 80)
        #expect((props[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        #expect((props[kCGImagePropertyProfileName] as? String)?.contains("P3") == true)
        #expect(CGImageSourceGetType(source) as String? == (format == .jpeg ? UTType.jpeg.identifier : UTType.heic.identifier))
        #expect(try await OriginalImportService(root: root).verify(asset) == asset)
    }

    @Test(arguments: Array(1...8))
    func renderAppliesEXIFExactlyOnce(orientation: Int) async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let asset = try await fixture(base, orientation: orientation)
        let service = EditingService(root: base.appendingPathComponent("projects"), asset: asset)
        let document = try await service.load()
        let result = try await service.render(document, recipe: document.history.current)
        #expect(result.image.width == asset.orientedWidth)
        #expect(result.image.height == asset.orientedHeight)
    }

    @Test func allAdjustmentsRenderAndCrop() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let asset = try await fixture(base)
        let service = EditingService(root: base.appendingPathComponent("projects"), asset: asset)
        var document = try await service.load()
        var recipe = EditRecipe()
        for adjustment in Adjustment.allCases where ![.cropScale, .cropX, .cropY, .straighten].contains(adjustment) {
            recipe[adjustment] = adjustment == .exposure ? 0.5 : 15
        }
        recipe.colors[0].hue = 25; recipe.colors[1].saturation = -30; recipe.colors[3].luminance = 20
        recipe.aspect = .square; recipe.quarterTurns = 1; recipe.flipHorizontal = true
        recipe[.straighten] = 8
        document.history.commit(recipe); document.revision = 1
        let result = try await service.render(document, recipe: recipe)
        #expect(result.image.width == 60 && result.image.height == 60)
        let before = try await service.render(document, recipe: recipe.geometryOnly)
        #expect(before.image.width == result.image.width && before.image.height == result.image.height)
        let url = try await service.export(document, settings: ExportSettings(), directory: base.appendingPathComponent("exports"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func rawDevelopmentPersistsDecoderAndRendersNativeOrientation() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let source = Bundle.module.url(forResource: "synthetic", withExtension: "dng", subdirectory: "Fixtures")!
        let root = base.appendingPathComponent("projects")
        let asset = try await OriginalImportService(root: root).importFile(at: source)
        let service = EditingService(root: root, asset: asset)
        let document = try await service.load()
        #expect(document.raw?.decoder == asset.supportedRAWDecoders.last)
        let result = try await service.render(document, recipe: EditRecipe(), maxPixelSize: 640)
        #expect(result.image.width == 480 && result.image.height == 640)
        let url = try await service.export(document, settings: ExportSettings(), directory: base.appendingPathComponent("exports"))
        let info = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)! as NSDictionary
        #expect(info[kCGImagePropertyPixelWidth] as? Int == 480)
        #expect(info[kCGImagePropertyPixelHeight] as? Int == 640)
    }

    @Test func hslIdentityGrayAndChannelIsolation() {
        let bands = Array(repeating: ColorBand(), count: 8)
        for rgb in [SIMD3(0.2, 0.4, 0.6), SIMD3(1.0, 0.0, 0.0), SIMD3(0.2, 0.2, 0.2)] {
            let result = ColorMixer.transform(rgb, bands: bands)
            #expect(abs(result.x-rgb.x) < 0.00001 && abs(result.y-rgb.y) < 0.00001 && abs(result.z-rgb.z) < 0.00001)
        }
        var red = bands; red[0].saturation = -100
        let gray = ColorMixer.transform(SIMD3(0.3, 0.3, 0.3), bands: red)
        #expect(gray == SIMD3(0.3, 0.3, 0.3))
        let blue = ColorMixer.transform(SIMD3(0.0, 0.0, 1.0), bands: red)
        #expect(abs(blue.z - 1) < 0.00001 && abs(blue.x) < 0.00001)
    }

    @Test func libraryPreviewUsesLatestSavedRevision() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let asset = try await fixture(base)
        let root = base.appendingPathComponent("projects")
        let importer = OriginalImportService(root: root)
        let service = EditingService(root: root, asset: asset)
        var document = try await service.load()
        let first = try await importer.preview(asset, maxPixelSize: 128)
        #expect(first.image.width == 80)
        var recipe = EditRecipe(); recipe.aspect = .square
        document.history.commit(recipe); document.revision += 1
        try await service.save(document)
        let second = try await importer.preview(asset, maxPixelSize: 128)
        #expect(second.image.width == 60 && second.image.height == 60)
    }

    @Test func invalidRecipeAndPreCancelledExportNeverWriteResult() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let asset = try await fixture(base)
        let service = EditingService(root: base.appendingPathComponent("projects"), asset: asset)
        let document = try await service.load()
        var invalid = EditRecipe(); invalid.values["exposure"] = 999
        await #expect(throws: EditorFailure.self) { try await service.render(document, recipe: invalid) }
        let directory = base.appendingPathComponent("exports")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.export(document, settings: ExportSettings(), directory: directory)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func presetExcludesGeometryAndPersists() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let asset = try await fixture(base)
        let service = EditingService(root: base.appendingPathComponent("projects"), asset: asset)
        var recipe = EditRecipe(); recipe[.exposure] = 1; recipe.aspect = .square; recipe[.cropScale] = 50
        let preset = UserPreset(name: "테스트", recipe: recipe)
        #expect(preset.recipe.aspect == .original && preset.recipe[.cropScale] == 100)
        #expect(preset.recipe[.exposure] == 1)
        let presets = try await service.savePreset(preset)
        #expect(presets == [preset])
        #expect(try await service.presets() == [preset])
    }
}
