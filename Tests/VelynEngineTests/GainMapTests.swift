import Testing
import Foundation
import CoreImage
import CoreML
import ImageIO
@testable import VelynEngine

struct GainMapTests {
    private let context = CIContext(options: [.workingColorSpace: RenderPipeline.linearSpace, .workingFormat: CIFormat.RGBAf])
    private func pixel(_ image: CIImage, x: Double = 1, y: Double = 1) -> [Float] {
        var result = [Float](repeating: 0, count: 4)
        result.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
            bounds: CGRect(x: x,y: y,width: 1,height: 1), format: .RGBAf, colorSpace: RenderPipeline.linearSpace) }
        return result
    }
    private func fixture() async throws -> (URL, URL, SourceAsset, EditingService) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("VelynGain-\(UUID())")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent("synthetic.jpg")
        let image = CIImage(color: .white).cropped(to: CGRect(x: 0,y: 90,width: 240,height: 90))
            .composited(over: CIImage(color: CIColor(red: 0.12,green: 0.12,blue: 0.12)).cropped(to: CGRect(x: 0,y: 0,width: 240,height: 180)))
        try context.writeJPEGRepresentation(of: image,to: path,colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let projects = base.appendingPathComponent("projects")
        let asset = try await OriginalImportService(root: projects).importFile(at: path)
        return (base,projects,asset,EditingService(root: projects,asset: asset))
    }

    @Test func gainMultiplicationPreservesChromaAlphaAndZeroStrength() throws {
        let rect = CGRect(x: 0,y: 0,width: 4,height: 4)
        let image = CIImage(color: CIColor(red: 0.8,green: 0.4,blue: 0.2,alpha: 0.5,colorSpace: RenderPipeline.linearSpace)!).cropped(to: rect)
        let map = CIImage(color: .white).cropped(to: rect)
        var expansion = HDRExpansion(resourceID: UUID()); expansion.strength = 1; expansion.maximumBoostEV = 1
        let before = pixel(image), after = pixel(GainMapPipeline.apply(image,map: map,expansion: expansion))
        for c in 0..<3 { #expect(abs(after[c]-before[c]*2) < 0.002) }
        #expect(abs(after[3]-before[3]) < 0.001)
        expansion.strength = 0
        #expect(pixel(GainMapPipeline.apply(image,map: map,expansion: expansion)) == before)
        expansion.strength = 1
        let black = CIImage(color: .black).cropped(to: rect)
        #expect(pixel(GainMapPipeline.apply(black,map: map,expansion: expansion))[0] == 0)
        let white = CIImage(color: .white).cropped(to: rect)
        #expect(pixel(GainMapPipeline.apply(white,map: map,expansion: expansion))[0] > 1.9)
    }

    @Test func midtoneProtectionPreservesDarkTonesAndColorRatios() {
        let rect = CGRect(x: 0,y: 0,width: 4,height: 4)
        let map = CIImage(color: .white).cropped(to: rect)
        var expansion = HDRExpansion(resourceID: UUID()); expansion.strength = 1; expansion.maximumBoostEV = log2(5)
        for level in [0.01,0.10,0.18] {
            let source = CIImage(color: CIColor(red: level,green: level,blue: level,colorSpace: RenderPipeline.linearSpace)!).cropped(to: rect)
            #expect(abs(pixel(GainMapPipeline.apply(source,map: map,expansion: expansion))[0]-Float(level)) < 0.001)
        }
        let source = CIImage(color: CIColor(red: 0.7,green: 0.5,blue: 0.3,colorSpace: RenderPipeline.linearSpace)!).cropped(to: rect)
        let result = pixel(GainMapPipeline.apply(source,map: map,expansion: expansion))
        #expect(abs(result[0]/result[1]-1.4) < 0.003 && abs(result[2]/result[1]-0.6) < 0.003)
        #expect(result[1] > 0.5 && result[1] < 2.5)
        let white = CIImage(color: .white).cropped(to: rect)
        #expect(pixel(GainMapPipeline.apply(white,map: map,expansion: expansion))[0] > 4.9)
        expansion.protectMidtones = nil
        #expect(pixel(GainMapPipeline.apply(source,map: map,expansion: expansion))[1] > result[1])
    }

    @Test func singleChannelModelMapAndLegacyPNGApplyEqualRGBGain() async throws {
        let (base,projects,asset,service) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let rect = CGRect(x: 0,y: 0,width: 4,height: 4)
        let samples = [Float](repeating: 0.6,count: 16)
        let rawMap = CIImage(bitmapData: samples.withUnsafeBytes { Data($0) },bytesPerRow: 16,
                             size: rect.size,format: .Rf,colorSpace: nil)
        // Match the actual model tensor conversion, not a synthetic RGB gray map.
        #expect(pixel(rawMap)[1] == 0 && pixel(rawMap)[2] == 0)
        let id = try await service.storeGainMap(rawMap)
        var recipe = EditRecipe(); recipe.enhancements.hdrExpansion = HDRExpansion(resourceID: id)
        let stored = try #require(await service.maskResources(recipe)[id])
        let storedPixel = pixel(stored)
        #expect(abs(storedPixel[0]-storedPixel[1]) < 0.001 && abs(storedPixel[0]-storedPixel[2]) < 0.001)
        // Recreate the old on-disk representation to check existing projects.
        let legacyID = UUID()
        try context.writePNGRepresentation(of: rawMap,to: projects.appendingPathComponent("\(asset.id)/masks/\(legacyID).png"),format: .RGBA16,colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        recipe.enhancements.hdrExpansion = HDRExpansion(resourceID: legacyID)
        let legacy = try #require(await service.maskResources(recipe)[legacyID])
        for map in [rawMap,stored,legacy] {
            for protection in [false,true] {
                var expansion = HDRExpansion(resourceID: id); expansion.protectMidtones = protection
                let gray = CIImage(color: CIColor(red: 0.8,green: 0.8,blue: 0.8,colorSpace: RenderPipeline.linearSpace)!).cropped(to: rect)
                let result = pixel(GainMapPipeline.apply(gray,map: map,expansion: expansion))
                #expect(result[0] > 1.2)
                #expect(abs(result[0]-result[1]) < 0.001 && abs(result[0]-result[2]) < 0.001)
                let color = CIImage(color: CIColor(red: 0.7,green: 0.5,blue: 0.3,colorSpace: RenderPipeline.linearSpace)!).cropped(to: rect)
                let rgb = pixel(GainMapPipeline.apply(color,map: map,expansion: expansion))
                #expect(abs(rgb[0]/rgb[1]-1.4) < 0.003 && abs(rgb[2]/rgb[1]-0.6) < 0.003)
            }
        }
    }

    @Test func numericMapRoundTripAndGeometryAlignment() async throws {
        let (base,_,_,service) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let document = try await service.load()
        let map = CIImage(color: .white).cropped(to: CGRect(x: 0,y: 90,width: 240,height: 90))
            .composited(over: CIImage(color: CIColor(red: 0.25,green: 0.25,blue: 0.25,colorSpace: RenderPipeline.linearSpace)!).cropped(to: CGRect(x: 0,y: 0,width: 240,height: 180)))
        let id = try await service.storeGainMap(map)
        var recipe = EditRecipe(); var expansion = HDRExpansion(resourceID: id); expansion.strength = 1; expansion.maximumBoostEV = 1
        recipe.enhancements.hdrExpansion = expansion
        let stored = try #require(await service.maskResources(recipe)[id])
        #expect(abs(pixel(stored,x: 10,y: 10)[0]-0.25) < 0.002)
        #expect(abs(pixel(stored,x: 10,y: 170)[0]-1) < 0.002)
        let sdr = try await service.processed(document,recipe: recipe,maxPixelSize: nil)
        recipe.enhancements.hdr = true
        let hdr = try await service.processed(document,recipe: recipe,maxPixelSize: nil)
        #expect(abs(pixel(hdr,x: 10,y: 170)[0] / pixel(sdr,x: 10,y: 170)[0]-2) < 0.005)
        recipe.quarterTurns = 1; recipe.aspect = .square
        let rotated = try await service.processed(document,recipe: recipe,maxPixelSize: nil)
        let expected = RenderPipeline.geometry(hdr,recipe: recipe)
        #expect(rotated.extent == expected.extent)
        for x in [10.0,90.0,170.0] { #expect(abs(pixel(rotated,x: x,y: 20)[0]-pixel(expected,x: x,y: 20)[0]) < 0.002) }
    }

    @Test func domainCompatibilityAndValidation() throws {
        var recipe = EditRecipe()
        recipe.enhancements.hdrExpansion = HDRExpansion(resourceID: UUID())
        #expect(recipe.isValid)
        #expect(recipe.colorOnly.enhancements.hdrExpansion == nil)
        var history = EditHistory(); history.commit(recipe); history.undo()
        #expect(history.current.enhancements.hdrExpansion == nil)
        history.redo(); #expect(history.current == recipe)
        recipe.enhancements.hdrExpansion?.strength = .nan; #expect(!recipe.isValid)
        var old = AdvancedEdits(); old.hdr = true
        let data = try JSONEncoder().encode(old)
        #expect(!String(decoding: data,as: UTF8.self).contains("hdrExpansion"))
        #expect(try JSONDecoder().decode(AdvancedEdits.self,from: data).hdrExpansion == nil)
    }

    @Test(arguments: [ExportFormat.jpeg,.heic]) func realModelPersistsExportsHDRAndKeepsSDRBase(format: ExportFormat) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let compiled = try await MLModel.compileModel(at: root.appendingPathComponent("Velyn/Models/VelynGainMap.mlpackage"))
        defer { try? FileManager.default.removeItem(at: compiled) }
        let (base,projects,asset,service) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        var document = try await service.load()
        #expect(try await service.sourceDynamicRange() == .sdr)
        let expansion = try await service.estimateHDRExpansion(document,recipe: EditRecipe(),modelURL: compiled)
        #expect(expansion.isValid)
        var recipe = EditRecipe(); recipe.enhancements.hdrExpansion = expansion; recipe.enhancements.hdr = true
        let map = try #require(await service.maskResources(recipe)[expansion.resourceID])
        #expect(map.extent.size == CGSize(width: 512,height: 384))
        // Asymmetric fixture catches top/bottom inversion through tensor and PNG conversion.
        #expect(pixel(map,x: 200,y: 340)[0] > pixel(map,x: 200,y: 40)[0]+0.1)
        let hdr = try await service.processed(document,recipe: recipe,maxPixelSize: nil)
        #expect(pixel(hdr,x: 100,y: 150)[0] > 1.2)
        let neutral = pixel(hdr,x: 100,y: 150)
        #expect(abs(neutral[0]-neutral[1]) < 0.005 && abs(neutral[0]-neutral[2]) < 0.005)
        let stats = try await service.diagnostics(document,recipe: recipe)
        #expect(stats.peak > 1.2 && stats.aboveSDRFraction > 0.4)
        let preview = try await service.render(document,recipe: recipe)
        #expect(preview.image.bitsPerComponent == 16)
        #expect(CIImage(cgImage: preview.image).contentHeadroom > 1.2)
        let previewNeutral = pixel(CIImage(cgImage: preview.image),x: 100,y: 150)
        #expect(abs(previewNeutral[0]-previewNeutral[1]) < 0.005 && abs(previewNeutral[0]-previewNeutral[2]) < 0.005)
        let clipping = try await service.render(document,recipe: recipe,showClipping: true)
        #expect(clipping.image.bitsPerComponent == 16)
        document.history.commit(recipe); document.revision += 1; try await service.save(document)
        let reopened = try await EditingService(root: projects,asset: asset).load()
        #expect(reopened.history.current == recipe)
        var settings = ExportSettings(); settings.quality = 1; settings.hdr = true; settings.format = format
        let url = try await service.export(document,settings: settings,directory: base)
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL,nil))
        #expect(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeHDRGainMap) != nil || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeISOGainMap) != nil)
        let expanded = try #require(CIImage(contentsOf: url,options: [.expandToHDR: true]))
        #expect(pixel(expanded,x: 100,y: 150)[0] > 1.2)
        let exportedNeutral = pixel(expanded,x: 100,y: 150)
        #expect(abs(exportedNeutral[0]-exportedNeutral[1]) < 0.02 && abs(exportedNeutral[0]-exportedNeutral[2]) < 0.02)
        settings.hdr = false
        let sdrURL = try await service.export(document,settings: settings,directory: base)
        let fallback = try #require(CIImage(contentsOf: url,options: [.expandToHDR: false,.toneMapHDRtoSDR: false]))
        let sdr = try #require(CIImage(contentsOf: sdrURL,options: [.expandToHDR: false]))
        for y in [20.0,150.0] { for c in 0..<3 { #expect(abs(pixel(fallback,x: 100,y: y)[c]-pixel(sdr,x: 100,y: y)[c]) < 0.015) } }
        let importedHDR = try await OriginalImportService(root: projects).importFile(at: url)
        let hdrService = EditingService(root: projects,asset: importedHDR)
        let hdrDocument = try await hdrService.load()
        #expect(try await hdrService.sourceDynamicRange() == .hdr)
        await #expect(throws: EditorFailure.self) { try await hdrService.estimateHDRExpansion(hdrDocument,recipe: EditRecipe(),modelURL: compiled) }
        _ = try await OriginalImportService(root: projects).verify(asset)
        await service.discardUncommittedGainMap(HDRExpansion(resourceID: UUID()))
    }

    @Test func canceledPredictionCreatesNoMap() async throws {
        let (base,projects,asset,service) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let document = try await service.load()
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await service.estimateHDRExpansion(document,recipe: EditRecipe()) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: projects.appendingPathComponent("\(asset.id)/masks").path))
    }
}
