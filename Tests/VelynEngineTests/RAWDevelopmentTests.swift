import Testing
import Foundation
import CoreImage
import CryptoKit
@testable import VelynEngine

struct RAWDevelopmentTests {
    @Test func sparseSettingsPreserveOldDocumentsAndHistory() throws {
        let old = try JSONDecoder().decode(EditRecipe.self,from: Data("{\"values\":{},\"colors\":[{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0}],\"aspect\":\"원본\",\"quarterTurns\":0,\"flipHorizontal\":false}".utf8))
        #expect(old.rawAdjustments == nil)
        var raw = RAWAdjustments(); raw[.temperature] = 4200; raw[.toneCurve] = 65
        var recipe = old; recipe.rawAdjustments = raw
        var history = EditHistory(); history.commit(recipe); history.undo(); #expect(history.current == old)
        history.redo(); #expect(history.current == recipe)
        #expect(try JSONDecoder().decode(EditRecipe.self,from: JSONEncoder().encode(recipe)) == recipe)
        #expect(recipe.geometryOnly.rawAdjustments == nil && recipe.colorOnly.rawAdjustments == nil)
        raw[.temperature] = 0; #expect(!raw.isValid)
        raw[.temperature] = .nan; #expect(!raw.isValid)
        raw[.temperature] = 4200; raw[.highlightRecovery] = 0.5; #expect(!raw.isValid)
    }
    @Test func nativeSettingsChangePixelsInvalidateCacheAndRestore() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("RAWControls-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = try #require(Bundle.module.url(forResource: "synthetic",withExtension: "dng",subdirectory: "Fixtures"))
        let asset = try await OriginalImportService(root: base).importFile(at: source)
        let service = EditingService(root: base,asset: asset)
        var document = try await service.load()
        let development = try #require(document.raw)
        let controls = try #require(try await service.rawControls(document))
        #expect(controls.parameters.contains(.temperature) && controls.parameters.contains(.toneCurve))
        var settings = RAWAdjustments(); settings[.temperature] = 3200; settings[.tint] = -10; settings[.toneCurve] = 65
        let filter = try RAWDeveloper.filter(at: source,development: development,adjustments: settings)
        #expect(filter.neutralTemperature == 3200 && filter.neutralTint == -10 && abs(filter.boostAmount-0.65) < 0.001)
        #expect(controls.parameters.contains(.luminanceNoise) == filter.isLuminanceNoiseReductionSupported)
        #expect(controls.parameters.contains(.colorNoise) == filter.isColorNoiseReductionSupported)
        #expect(controls.parameters.contains(.lensCorrection) == filter.isLensCorrectionSupported)
        if #available(macOS 26,iOS 26,*) { #expect(controls.parameters.contains(.highlightRecovery) == filter.isHighlightRecoverySupported) }
        var edited = EditRecipe(); edited.rawAdjustments = settings
        func digest(_ image: CGImage) -> String { SHA256.hash(data: image.dataProvider!.data! as Data).description }
        let first = try await service.render(document,recipe: EditRecipe(),maxPixelSize: 320)
        let changed = try await service.render(document,recipe: edited,maxPixelSize: 320)
        let reset = try await service.render(document,recipe: EditRecipe(),maxPixelSize: 320)
        #expect(digest(first.image) != digest(changed.image))
        #expect(digest(first.image) == digest(reset.image))
        document.history.commit(edited); document.revision += 1; try await service.save(document)
        #expect(try await EditingService(root: base,asset: asset).load() == document)
        _ = try await OriginalImportService(root: base).verify(asset)
        let library = LibraryService(root: base)
        var preset = EditRecipe(); preset[.contrast] = 15
        try await library.pasteEdits(preset,to: asset)
        #expect(try await service.load().history.current.rawAdjustments == settings)
    }
}
