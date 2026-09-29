import Testing
import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import VelynEngine

struct ProfessionalEditingTests {
    private func setup() async throws -> (URL,SourceAsset,EditingService) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("VelynPro-\(UUID())")
        try FileManager.default.createDirectory(at: base,withIntermediateDirectories: true)
        let cg = CGContext(data: nil,width: 240,height: 160,bitsPerComponent: 8,bytesPerRow: 960,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        cg.setFillColor(CGColor(red: 0.3,green: 0.4,blue: 0.5,alpha: 1)); cg.fill(CGRect(x: 0,y: 0,width: 240,height: 160))
        cg.setFillColor(CGColor(red: 0.9,green: 0.1,blue: 0.1,alpha: 1)); cg.fill(CGRect(x: 0,y: 80,width: 80,height: 80))
        let file = base.appendingPathComponent("chart.jpg")
        let destination = CGImageDestinationCreateWithURL(file as CFURL,UTType.jpeg.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,cg.makeImage()!,[kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let root = base.appendingPathComponent("projects")
        let asset = try await OriginalImportService(root: root).importFile(at: file)
        return (base,asset,EditingService(root: root,asset: asset))
    }
    private func pixels(_ image: CIImage) -> [Float] {
        let ctx = CIContext(options: [.workingColorSpace: RenderPipeline.linearSpace,.workingFormat: CIFormat.RGBAf])
        var values = [Float](repeating: 0,count: Int(image.extent.width*image.extent.height)*4)
        values.withUnsafeMutableBytes { ctx.render(image,toBitmap: $0.baseAddress!,rowBytes: Int(image.extent.width)*16,bounds: image.extent,format: .RGBAf,colorSpace: RenderPipeline.linearSpace) }
        return values
    }
    @Test func legacyRecipesDecodeAndAdvancedHistoryRoundTrips() throws {
        let old = Data("{\"values\":{},\"colors\":[{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0},{\"hue\":0,\"saturation\":0,\"luminance\":0}],\"aspect\":\"원본\",\"quarterTurns\":0,\"flipHorizontal\":false}".utf8)
        let original = try JSONDecoder().decode(EditRecipe.self,from: old)
        #expect(original == EditRecipe())
        var recipe = original
        recipe.enhancements.masks = [LocalMask(kind: .radial)]
        recipe.enhancements.retouches = [RetouchPatch()]
        recipe.enhancements.grading[0].hue = 230; recipe.enhancements.grading[0].saturation = 25
        var history = EditHistory(); history.commit(recipe); history.undo(); #expect(history.current == original); history.redo()
        #expect(try JSONDecoder().decode(EditHistory.self,from: JSONEncoder().encode(history)) == history)
        #expect(recipe.colorOnly.enhancements.masks.isEmpty)
        #expect(recipe.colorOnly.enhancements.retouches.isEmpty)
    }
    @Test func invalidSpatialAndCurveDataCannotBeSaved() async throws {
        let (base,_,service) = try await setup(); defer { try? FileManager.default.removeItem(at: base) }
        let document = try await service.load()
        var bad = EditRecipe(); var curve = PointCurve(); curve.points = [.init(0,0),.init(0.5,0.7),.init(0.5,0.2),.init(1,1)]
        bad.enhancements.curves["R"] = curve
        #expect(!bad.isValid)
        await #expect(throws: EditorFailure.self) { try await service.render(document,recipe: bad) }
        var invalidMask = LocalMask(kind: .subject); invalidMask.resourceID = nil
        bad = EditRecipe(); bad.enhancements.masks = [invalidMask]; #expect(!bad.isValid)
    }
    @Test func pointCurveMatchesGraphAndPreservesHDR() throws {
        var curve = PointCurve(); curve.points = [.init(0,0),.init(0.5,0.25),.init(1,1)]
        #expect(abs(curve.evaluate(0.25)-0.125) < 0.0001)
        var recipe = EditRecipe(); recipe.enhancements.curves["RGB"] = curve
        let image = CIImage(color: CIColor(red: 0.25,green: 0.25,blue: 0.25,colorSpace: RenderPipeline.linearSpace)!).cropped(to: CGRect(x: 0,y: 0,width: 1,height: 1))
        let result = pixels(AdvancedPipeline.global(image,recipe: recipe))
        #expect(abs(result[0]-0.125) < 0.01)
        recipe.enhancements.hdr = true
        let hdr = CIImage(color: CIColor(red: 2,green: 2,blue: 2,colorSpace: RenderPipeline.linearSpace)!).cropped(to: image.extent)
        #expect(pixels(AdvancedPipeline.global(hdr,recipe: recipe))[0] > 1.8)
    }
    @Test func localMaskChangesOnlySelectedRegionAndInvertSwapsIt() {
        let rect = CGRect(x: 0,y: 0,width: 100,height: 100)
        let source = CIImage(color: CIColor(red: 0.2,green: 0.2,blue: 0.2,colorSpace: RenderPipeline.linearSpace)!).cropped(to: rect)
        var mask = LocalMask(kind: .radial); mask.points = [.init(0.2,0.2),.init(0.8,0.8)]; mask.feather = 0; mask.exposure = 1
        var recipe = EditRecipe(); recipe.enhancements.masks = [mask]
        let result = pixels(AdvancedPipeline.spatial(source,recipe: recipe,resources: [:]))
        let center = (50*100+50)*4
        #expect(abs(result[0]-0.2) < 0.01); #expect(abs(result[center]-0.4) < 0.01)
        recipe.enhancements.masks[0].inverted = true
        let inverted = pixels(AdvancedPipeline.spatial(source,recipe: recipe,resources: [:]))
        #expect(abs(inverted[0]-0.4) < 0.01); #expect(abs(inverted[center]-0.2) < 0.01)
    }
    @Test func cloneUsesTopLeftNormalizedCoordinates() {
        let rect = CGRect(x: 0,y: 0,width: 100,height: 100)
        let gray = CIImage(color: CIColor(red: 0.2,green: 0.2,blue: 0.2)).cropped(to: rect)
        let red = CIImage(color: CIColor(red: 1,green: 0,blue: 0)).cropped(to: CGRect(x: 10,y: 70,width: 20,height: 20)).composited(over: gray)
        var patch = RetouchPatch(); patch.kind = .clone; patch.source = .init(0.2,0.2); patch.target = .init(0.7,0.7); patch.radius = 0.07; patch.feather = 0
        var recipe = EditRecipe(); recipe.enhancements.retouches = [patch]
        let processed = AdvancedPipeline.spatial(red,recipe: recipe,resources: [:])
        // Read a one-pixel CI region; bitmap rows from a full render have top-left origin.
        let target = pixels(processed.cropped(to: CGRect(x: 70,y: 30,width: 1,height: 1)))
        let source = pixels(processed.cropped(to: CGRect(x: 20,y: 80,width: 1,height: 1)))
        #expect(target[0] > 0.9 && target[1] < 0.01)
        #expect(source[0] > 0.9 && source[1] < 0.01)
    }
    @Test func analysisVersionsAndNewEffectsPreserveOriginal() async throws {
        let (base,asset,service) = try await setup(); defer { try? FileManager.default.removeItem(at: base) }
        var document = try await service.load()
        let originalPath = base.appendingPathComponent("projects/\(asset.id)/original/source")
        let hash = SHA256.hash(data: try Data(contentsOf: originalPath))
        var r = EditRecipe(); r[.texture] = 30; r[.dehaze] = 10; r[.grain] = 30; r[.colorNoiseReduction] = 15; r[.perspectiveVertical] = 10
        r.enhancements.grading[0].hue = 210; r.enhancements.grading[0].saturation = 25
        r.enhancements.retouches = [RetouchPatch()]
        var mask = LocalMask(kind: .linear); mask.exposure = 0.5; r.enhancements.masks = [mask]
        document.history.commit(r); document.revision += 1
        try await service.save(document)
        let render = try await service.render(document,recipe: r)
        #expect(render.image.width == 240)
        let stats = try await service.analyze(document,recipe: r)
        #expect(stats.histogram.reduce(0,+) == 240*160)
        let versions = try await service.saveVersion(name: "검토",recipe: r)
        #expect(try await service.versions() == versions)
        #expect(SHA256.hash(data: try Data(contentsOf: originalPath)) == hash)
    }
    @Test func tiff16BitAndOriginalExportAreRealFiles() async throws {
        let (base,asset,service) = try await setup(); defer { try? FileManager.default.removeItem(at: base) }
        let doc = try await service.load()
        var settings = ExportSettings(); settings.format = .tiff; settings.watermark = "Velyn"
        let tiff = try await service.export(doc,settings: settings,directory: base.appendingPathComponent("output"))
        let source = CGImageSourceCreateWithURL(tiff as CFURL,nil)!
        let info = CGImageSourceCopyPropertiesAtIndex(source,0,nil)! as NSDictionary
        #expect(CGImageSourceGetType(source) as String? == UTType.tiff.identifier)
        #expect(info[kCGImagePropertyDepth] as? Int == 16)
        #expect(info[kCGImagePropertyGPSDictionary] == nil)
        settings.format = .original
        let original = try await service.export(doc,settings: settings,directory: base.appendingPathComponent("output"))
        #expect(try Data(contentsOf: original) == Data(contentsOf: base.appendingPathComponent("projects/\(asset.id)/original/source")))
    }
    @Test func catalogTrashRestoreAndBatchPastePreserveGeometry() async throws {
        let (base,asset,editing) = try await setup(); defer { try? FileManager.default.removeItem(at: base) }
        let library = LibraryService(root: base.appendingPathComponent("projects"))
        let catalog = try await library.createAlbum("여행")
        let album = catalog.albums[0].id
        _ = try await library.update(ids: [asset.id],rating: 4,flag: .pick,album: album,trash: true)
        #expect(try await library.load()[asset.id].trashedAt != nil)
        let restored = try await library.update(ids: [asset.id],trash: false)
        #expect(restored[asset.id].rating == 4 && restored[asset.id].albumIDs == [album])
        var document = try await editing.load(); var recipe = EditRecipe(); recipe.aspect = .square; recipe[.cropScale] = 70; recipe.enhancements.masks = [LocalMask(kind: .radial)]; document.history.commit(recipe); document.revision += 1; try await editing.save(document)
        var paste = EditRecipe(); paste[.exposure] = 1
        try await library.pasteEdits(paste,to: asset)
        let newDocument = try await EditingService(root: base.appendingPathComponent("projects"),asset: asset).load()
        #expect(newDocument.history.current[.exposure] == 1)
        #expect(newDocument.history.current.aspect == .square && newDocument.history.current[.cropScale] == 70)
        #expect(newDocument.history.current.enhancements.masks.count == 1)
        #expect(try await OriginalImportService(root: base.appendingPathComponent("projects")).verify(asset) == asset)
    }
    @Test func hdrColorMixerDoesNotClipHighlights() {
        var recipe = EditRecipe(); recipe.enhancements.hdr = true; recipe.colors[0].saturation = 20
        let image = CIImage(color: CIColor(red: 3,green: 1.2,blue: 0.8,colorSpace: RenderPipeline.linearSpace)!).cropped(to: CGRect(x: 0,y: 0,width: 1,height: 1))
        let result = pixels(RenderPipeline.apply(image,recipe: recipe,rawExposureHandled: false,cube: ColorMixer.cube(bands: recipe.colors,hdr: true)))
        #expect(result[0] > 2.5)
        #expect(result.allSatisfy { $0.isFinite })
    }
    @Test(arguments: [ExportFormat.jpeg,.heic])
    func hdrExportsHaveGainMap(format: ExportFormat) async throws {
        let (base,_,service) = try await setup(); defer { try? FileManager.default.removeItem(at: base) }
        var doc = try await service.load(); var recipe = EditRecipe(); recipe[.exposure] = 2; recipe.enhancements.hdr = true; doc.history.commit(recipe); doc.revision += 1
        var settings = ExportSettings(); settings.hdr = true; settings.format = format
        let url = try await service.export(doc,settings: settings,directory: base.appendingPathComponent("output"))
        let source = CGImageSourceCreateWithURL(url as CFURL,nil)!
        let gainMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeHDRGainMap)
        let isoMap = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeISOGainMap)
        #expect(gainMap != nil || isoMap != nil)
    }

}

extension ProfessionalEditingTests {
    @Test func cloneOpacityAndMaskOverlayStayOutOfExports() async throws {
        let (base,_,service) = try await setup(); defer { try? FileManager.default.removeItem(at: base) }
        let document = try await service.load()
        var r = EditRecipe(); var mask = LocalMask(kind: .radial); mask.feather = 0; r.enhancements.masks = [mask]
        let plain = try await service.render(document,recipe: r)
        let overlay = try await service.render(document,recipe: r,overlayMaskID: mask.id)
        let a = pixels(CIImage(cgImage: plain.image)), b = pixels(CIImage(cgImage: overlay.image))
        #expect(a != b)
        let source = CIImage(color: .red).cropped(to: CGRect(x: 0,y: 0,width: 50,height: 50)).composited(over: CIImage(color: .blue).cropped(to: CGRect(x: 0,y: 0,width: 100,height: 100)))
        var patch = RetouchPatch(); patch.kind = .clone; patch.source = .init(0.25,0.75); patch.target = .init(0.75,0.25); patch.opacity = 0
        r = EditRecipe(); r.enhancements.retouches = [patch]
        #expect(pixels(AdvancedPipeline.spatial(source,recipe: r,resources: [:])) == pixels(source))
    }
}

extension ProfessionalEditingTests {
    @Test func brushAddsAndErasesAcrossSeparateStrokes() {
        let extent = CGRect(x: 0,y: 0,width: 100,height: 100)
        var mask = LocalMask(kind: .brush); mask.points = []; mask.feather = 0
        mask.strokes = [MaskStroke(points: [.init(0.3,0.5),.init(0.7,0.5)],radius: 0.1,feather: 0,erasing: false),MaskStroke(points: [.init(0.5,0.5)],radius: 0.06,feather: 0,erasing: true)]
        let image = AdvancedPipeline.drawnMask(mask,extent: extent)
        #expect(pixels(image.cropped(to: CGRect(x: 30,y: 50,width: 1,height: 1)))[0] > 0.99)
        #expect(pixels(image.cropped(to: CGRect(x: 50,y: 50,width: 1,height: 1)))[0] < 0.01)
        #expect(pixels(image.cropped(to: CGRect(x: 5,y: 5,width: 1,height: 1)))[0] < 0.01)
    }
    @Test func depthFocusPreservesNearAndBlursFar() {
        let extent = CGRect(x: 0,y: 0,width: 100,height: 100)
        let source = CIFilter(name: "CICheckerboardGenerator",parameters: ["inputWidth": 2,"inputSharpness": 1])!.outputImage!.cropped(to: extent)
        let map = CIImage(color: .white).cropped(to: CGRect(x: 0,y: 0,width: 50,height: 100)).composited(over: CIImage(color: .black).cropped(to: extent))
        var depth = DepthEffect(resourceID: UUID()); depth.amount = 100; depth.focus = 1; depth.range = 0.1
        var recipe = EditRecipe(); recipe.enhancements.depth = depth
        let rendered = AdvancedPipeline.spatial(source,recipe: recipe,resources: [depth.resourceID: map])
        func sample(_ image: CIImage,_ x: Int) -> Float { pixels(image.cropped(to: CGRect(x: x,y: 50,width: 1,height: 1)))[0] }
        #expect(abs(sample(rendered,20)-sample(source,20)) < 0.01)
        #expect(abs(sample(rendered,80)-sample(source,80)) > 0.1)
    }
    @Test func positiveWarmthRaisesRedRelativeToBlue() {
        let source = CIImage(color: CIColor(red: 0.3,green: 0.3,blue: 0.3,colorSpace: RenderPipeline.linearSpace)!).cropped(to: CGRect(x: 0,y: 0,width: 1,height: 1))
        var recipe = EditRecipe(); recipe[.warmth] = 40
        let result = pixels(RenderPipeline.apply(source,recipe: recipe,rawExposureHandled: false,cube: nil))
        #expect(result[0] > result[2])
    }
}

extension ProfessionalEditingTests {
    @Test func healingTransfersBothLightAndDarkTexture() {
        let bounds = CGRect(x: 0,y: 0,width: 200,height: 100)
        func gray(_ value: CGFloat,_ rect: CGRect) -> CIImage { CIImage(color: CIColor(red: value,green: value,blue: value,colorSpace: RenderPipeline.linearSpace)!).cropped(to: rect) }
        let input = gray(0.1,CGRect(x: 45,y: 40,width: 5,height: 20)).composited(over: gray(0.7,CGRect(x: 50,y: 40,width: 5,height: 20))).composited(over: gray(0.4,CGRect(x: 0,y: 0,width: 100,height: 100))).composited(over: gray(0.6,bounds))
        var patch = RetouchPatch(); patch.source = .init(0.25,0.5); patch.target = .init(0.75,0.5); patch.radius = 0.15; patch.feather = 0
        var recipe = EditRecipe(); recipe.enhancements.retouches = [patch]
        let healed = AdvancedPipeline.spatial(input,recipe: recipe,resources: [:])
        let dark = pixels(healed.cropped(to: CGRect(x: 147,y: 50,width: 1,height: 1)))[0]
        let light = pixels(healed.cropped(to: CGRect(x: 152,y: 50,width: 1,height: 1)))[0]
        #expect(dark < 0.5); #expect(light > 0.7)
    }
}
