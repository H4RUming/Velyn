import Testing
import Foundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers
@testable import VelynEngine

struct ImageFormatTests {
    @Test func saveMenuHasFourChoicesIncludingRequiredFormats() {
        #expect(ImageFormats.exportFormats == [.jpeg,.png,.heic,.original])
        #expect(ImageFormats.encodableExportFormats.contains(.jpeg))
        #expect(ImageFormats.encodableExportFormats.contains(.png))
        #expect(ImageFormats.encodableExportFormats.contains(.heic))
    }

    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VelynFormats-\(UUID())")
        try FileManager.default.createDirectory(at: url,withIntermediateDirectories: true)
        return url
    }
    private func image() -> CGImage {
        let context = CGContext(data: nil,width: 240,height: 180,bitsPerComponent: 8,bytesPerRow: 960,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<180 {
            context.setFillColor(CGColor(red: Double(y)/180,green: 0.45,blue: 0.7,alpha: 0.6))
            context.fill(CGRect(x: 0,y: y,width: 120,height: 1))
        }
        return context.makeImage()!
    }
    private func write(_ type: String,to url: URL,frames: Int = 1) throws {
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL,type as CFString,frames,nil))
        for _ in 0..<frames { CGImageDestinationAddImage(destination,image(),[kCGImagePropertyOrientation: 1] as CFDictionary) }
        #expect(CGImageDestinationFinalize(destination))
    }
    private func alpha(_ cg: CGImage,x: Int = 200) -> Float {
        var value = [Float](repeating: 0,count: 4)
        value.withUnsafeMutableBytes { CIContext().render(CIImage(cgImage: cg),toBitmap: $0.baseAddress!,rowBytes: 16,
            bounds: CGRect(x: x,y: 40,width: 1,height: 1),format: .RGBAf,colorSpace: RenderPipeline.linearSpace) }
        return value[3]
    }
    @Test(arguments: ["public.png","public.tiff","com.compuserve.gif","com.microsoft.bmp","public.avif","public.jpeg-2000"])
    func importsRasterByContentAndRenders(type: String) async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("misleading.jpg"); try write(type,to: file)
        let importer = OriginalImportService(root: base.appendingPathComponent("projects"))
        let asset = try await importer.importFile(at: file)
        #expect(asset.typeIdentifier == type)
        _ = try await importer.verify(asset)
        let service = EditingService(root: base.appendingPathComponent("projects"),asset: asset)
        let document = try await service.load()
        let rendered = try await service.render(document,recipe: EditRecipe())
        #expect(rendered.image.width == 240 && rendered.image.height == 180)
        if type == "public.png" { #expect(asset.hasAlpha == true); #expect(alpha(rendered.image) < 0.01) }
    }
    @Test func previewCachePreservesPixelsAcrossSizesAnalysisAndHDR() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("transparent.png"); try write("public.png",to: file)
        let projects = base.appendingPathComponent("projects")
        let asset = try await OriginalImportService(root: projects).importFile(at: file)
        let service = EditingService(root: projects,asset: asset)
        let document = try await service.load()
        var recipe = EditRecipe(); recipe[.exposure] = 0.8; recipe[.warmth] = 15
        let first = try await service.render(document,recipe: recipe,maxPixelSize: 1536)
        _ = try await service.render(document,recipe: recipe,maxPixelSize: 128)
        _ = try await service.analyze(document,recipe: recipe)
        var hdr = recipe; hdr.enhancements.hdr = true
        _ = try await service.render(document,recipe: hdr,maxPixelSize: 1536)
        let again = try await service.render(document,recipe: recipe,maxPixelSize: 1536)
        let firstBytes = try #require(first.image.dataProvider?.data) as Data
        let againBytes = try #require(again.image.dataProvider?.data) as Data
        #expect(firstBytes == againBytes)
        #expect(again.image.width == 240 && again.image.height == 180)
        #expect(alpha(again.image) < 0.01)
        _ = try await OriginalImportService(root: projects).verify(asset)
    }
    @Test(arguments: [false,true]) func pngBitDepthAndAlpha(sixteen: Bool) async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("transparent.png"); try write("public.png",to: file)
        let root = base.appendingPathComponent("projects")
        let asset = try await OriginalImportService(root: root).importFile(at: file)
        let service = EditingService(root: root,asset: asset); let doc = try await service.load()
        var settings = ExportSettings(); settings.format = .png; settings.png16Bit = sixteen; settings.colorSpace = .displayP3
        let output = try await service.export(doc,settings: settings,directory: base.appendingPathComponent("exports"))
        let src = try #require(CGImageSourceCreateWithURL(output as CFURL,nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(src,0,nil))
        #expect(decoded.bitsPerComponent == (sixteen ? 16 : 8))
        #expect(alpha(decoded) < 0.001 && abs(alpha(decoded,x: 60)-0.6) < 0.01)
        #expect(decoded.width == 240 && decoded.height == 180)
    }
    @Test func webPImportsAndOriginalCopyIsExact() async throws {
        let file = try #require(Bundle.module.url(forResource: "synthetic",withExtension: "webp",subdirectory: "Fixtures"))
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let projects = base.appendingPathComponent("projects")
        let asset = try await OriginalImportService(root: projects).importFile(at: file)
        #expect(asset.typeIdentifier == "org.webmproject.webp" && asset.hasAlpha == true)
        let service = EditingService(root: projects,asset: asset)
        let doc = try await service.load()
        let preview = try await service.render(doc,recipe: EditRecipe())
        #expect(preview.image.width == 128 && preview.image.height == 96)
        var options = ExportSettings(); options.format = .original
        let prepared = try await service.prepareExport(doc,settings: options)
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        #expect(prepared.url.pathExtension == "webp")
        #expect(try Data(contentsOf: prepared.url) == Data(contentsOf: file))
        #expect(prepared.byteCount == asset.byteCount)
    }
    @Test func animatedOriginalIsPreservedAndEditsAreStillImages() async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("two-frames.gif"); try write("com.compuserve.gif",to: file,frames: 2)
        let projects = base.appendingPathComponent("projects")
        let asset = try await OriginalImportService(root: projects).importFile(at: file)
        #expect(asset.frameCount == 2)
        let service = EditingService(root: projects,asset: asset); let doc = try await service.load()
        var settings = ExportSettings(); settings.format = .png
        let output = try await service.prepareExport(doc,settings: settings)
        #expect(output.frameCount == 1)
        await service.discardExport(output.url)
    }
    @Test(arguments: [ExportFormat.jpeg,.png,.avif,.heic,.tiff])
    func preparedSizeMatchesSavedCopyAndAlphaPolicy(format: ExportFormat) async throws {
        let base = try workspace(); defer { try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("transparent.png"); try write("public.png",to: file)
        let projects = base.appendingPathComponent("projects")
        let asset = try await OriginalImportService(root: projects).importFile(at: file)
        let service = EditingService(root: projects,asset: asset)
        var document = try await service.load(); var recipe = EditRecipe(); recipe.aspect = .square
        document.history.commit(recipe)
        var settings = ExportSettings(); settings.format = format; settings.longEdge = 100
        let prepared = try await service.prepareExport(document,settings: settings)
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        #expect(prepared.width == 100 && prepared.height == 100)
        let copied = try await service.copyPreparedExport(prepared)
        defer { try? FileManager.default.removeItem(at: copied) }
        #expect(Int64(try Data(contentsOf: copied).count) == prepared.byteCount)
        #expect(try Data(contentsOf: copied) == Data(contentsOf: prepared.url))
        #expect(copied.pathExtension == format.fileExtension)
        let source = try #require(CGImageSourceCreateWithURL(copied as CFURL,nil))
        let cg = try #require(CGImageSourceCreateImageAtIndex(source,0,nil))
        if format.preservesAlpha { #expect(alpha(cg,x: 90) < 0.02) }
        else { #expect(abs(alpha(cg,x: 90)-1) < 0.001) }
        await service.discardExport(prepared.url)
        #expect(!FileManager.default.fileExists(atPath: prepared.url.path))
    }
}
