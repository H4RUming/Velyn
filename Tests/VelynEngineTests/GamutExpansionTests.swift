import Testing
import Foundation
import CoreImage
import ImageIO
@testable import VelynEngine

struct GamutExpansionTests {
    private let context = CIContext(options: [.workingColorSpace: RenderPipeline.linearSpace,.workingFormat: CIFormat.RGBAf])
    private func sample(_ image: CIImage,space: CGColorSpace = RenderPipeline.linearSpace) -> [Float] {
        var values = [Float](repeating: 0,count: 4)
        values.withUnsafeMutableBytes { context.render(image,toBitmap: $0.baseAddress!,rowBytes: 16,bounds: CGRect(x: 1,y: 1,width: 1,height: 1),format: .RGBAf,colorSpace: space) }
        return values
    }
    private func image(_ r: CGFloat,_ g: CGFloat,_ b: CGFloat,_ a: CGFloat = 1) -> CIImage {
        CIImage(color: CIColor(red: r,green: g,blue: b,alpha: a,colorSpace: RenderPipeline.linearSpace)!).cropped(to: CGRect(x: 0,y: 0,width: 240,height: 180))
    }
    @Test func neutralAndHDRHeadroomStayNeutral() {
        for gray in [CGFloat(0),0.005,0.18,0.5,1,2,5] {
            let input = image(gray,gray,gray)
            let output = sample(GamutExpansion.apply(input,strength: 100))
            // Core Image color-space/cube interpolation has finite precision; HDR uses a relative bound.
            for c in 0..<3 { #expect(abs(output[c]-Float(gray)) < max(0.003,Float(gray)*0.002)) }
            #expect(abs(output[0]-output[1]) < 0.0005)
            #expect(abs(output[1]-output[2]) < 0.0005)
        }
    }
    @Test func expansionAddsWideColorsWithSmoothStrengthAndPreservesAlpha() {
        let input = image(0,0.8,0,0.6)
        let zero = sample(GamutExpansion.apply(input,strength: 0))
        let half = sample(GamutExpansion.apply(input,strength: 50))
        let full = sample(GamutExpansion.apply(input,strength: 100))
        #expect(full[0] < -0.01) // A real out-of-sRGB color, not just a different ICC label.
        #expect(full[3] > 0.599 && full[3] < 0.601)
        for c in 0..<3 { #expect(abs(half[c]-(zero[c]+full[c])/2) < 0.003) }
        let p3 = sample(GamutExpansion.apply(input,strength: 100),space: GamutExpansion.space)
        #expect(p3.prefix(3).allSatisfy { $0 >= -0.001 && $0 <= 0.601 })
        let beforeY = zero[0]*0.212639 + zero[1]*0.715169 + zero[2]*0.072192
        let afterY = full[0]*0.212639 + full[1]*0.715169 + full[2]*0.072192
        #expect(abs(beforeY-afterY) < 0.003)
        #expect(sample(GamutExpansion.apply(image(1,0,0,0),strength: 100))[3] == 0)
    }
    @Test func historyAndLegacyRecipesKeepExpansionOptional() throws {
        let old = try JSONDecoder().decode(EditRecipe.self,from: JSONEncoder().encode(EditRecipe()))
        #expect(old[.gamutExpansion] == 0)
        var recipe = old; recipe[.gamutExpansion] = 70
        var history = EditHistory(); history.commit(recipe); history.undo()
        #expect(history.current[.gamutExpansion] == 0)
        history.redo(); #expect(history.current[.gamutExpansion] == 70)
        #expect(recipe.geometryOnly[.gamutExpansion] == 0)
        #expect(recipe.colorOnly[.gamutExpansion] == 70)
        #expect(try JSONDecoder().decode(EditRecipe.self,from: JSONEncoder().encode(recipe)) == recipe)
        recipe.values[Adjustment.gamutExpansion.rawValue] = 101; #expect(!recipe.isValid)
    }
    @Test(arguments: [ExportFormat.png,.jpeg,.heic])
    func p3ExportAndPreviewPreserveExpandedColors(format: ExportFormat) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GamutTest-\(UUID())")
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic-green.png")
        try context.writePNGRepresentation(of: image(0,0.8,0),to: source,format: .RGBA8,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let projects = root.appendingPathComponent("projects")
        let importer = OriginalImportService(root: projects)
        let asset = try await importer.importFile(at: source)
        let service = EditingService(root: projects,asset: asset)
        var doc = try await service.load(); var recipe = EditRecipe(); recipe[.gamutExpansion] = 100
        doc.history.commit(recipe); doc.revision += 1; try await service.save(doc)
        let preview = try await service.render(doc,recipe: recipe)
        #expect(preview.image.colorSpace?.name == CGColorSpace.displayP3)
        #expect(sample(CIImage(cgImage: preview.image))[0] < -0.01)
        let detail = try await service.renderDetail(doc,center: PhotoPoint(0.5,0.5))
        #expect(sample(CIImage(cgImage: detail.image))[0] < -0.01)
        var settings = ExportSettings(); settings.format = format; settings.colorSpace = .displayP3
        let url = try await service.export(doc,settings: settings,directory: root)
        let output = try #require(CIImage(contentsOf: url))
        #expect(output.extent.width == 240 && output.extent.height == 180)
        #expect(sample(output)[0] < -0.01)
        let io = try #require(CGImageSourceCreateWithURL(url as CFURL,nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(io,0,nil) as? [String: Any])
        #expect((props[kCGImagePropertyProfileName as String] as? String)?.contains("P3") == true)
        settings.colorSpace = .sRGB
        let narrow = try await service.export(doc,settings: settings,directory: root)
        #expect(sample(try #require(CIImage(contentsOf: narrow)))[0] > -0.005)
        settings.format = .original
        let copy = try await service.export(doc,settings: settings,directory: root)
        #expect(try Data(contentsOf: copy) == Data(contentsOf: source))
        _ = try await importer.verify(asset)
    }
}
