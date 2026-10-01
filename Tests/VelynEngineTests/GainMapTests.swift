import Testing
import Foundation
import CoreImage
import CoreML
import ImageIO
@testable import VelynEngine

struct GainMapTests {
    @Test func acceleratorCalibrationRejectsSilentDriftAndWrongGeometry() throws {
        for size in [512,1024] { for pattern in 0..<2 {
            let output = try MLMultiArray(shape:[1,1,NSNumber(value:size),NSNumber(value:size)],dataType:.float32)
            output.dataPointer.bindMemory(to:Float.self,capacity:output.count).initialize(repeating:0,count:output.count)
            #expect(!GainModelCalibration.accepts(output,size:size,pattern:pattern))
            let positions = [size/8,size/2,size*7/8]
            let reference = GainModelCalibration.reference(size:size,pattern:pattern)
            for (i,y) in positions.enumerated() { for (j,x) in positions.enumerated() {
                output[[0,0,NSNumber(value:y),NSNumber(value:x)]] = NSNumber(value:reference[i*3+j])
            } }
            #expect(GainModelCalibration.accepts(output,size:size,pattern:pattern))
            output[[0,0,NSNumber(value:size/2),NSNumber(value:size/2)]] = NSNumber(value:Float.nan)
            #expect(!GainModelCalibration.accepts(output,size:size,pattern:pattern))
            output[[0,0,NSNumber(value:size/2),NSNumber(value:size/2)]] = NSNumber(value:reference[4]-0.1)
            #expect(!GainModelCalibration.accepts(output,size:size,pattern:pattern))
        } }
        let wrong = try MLMultiArray(shape:[1,1,128,128],dataType:.float32)
        #expect(!GainModelCalibration.accepts(wrong,size:512,pattern:0))
    }

    @Test func neuralEngineConversionMatchesCPUOnAsymmetricTensor() async throws {
        guard MLComputeDevice.allComputeDevices.contains(where: { if case .neuralEngine = $0 { return true }; return false }) else { return }
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let compiled = try await MLModel.compileModel(at:root.appendingPathComponent("Velyn/Models/VelynGainMap.mlpackage"))
        defer { try? FileManager.default.removeItem(at:compiled) }
        let input = try GainModelCalibration.input(size:512,pattern:1)
        // A synchronous helper keeps the prediction and mutable Core ML objects off MainActor.
        func evaluate(_ units: MLComputeUnits) throws -> [Float] {
            let config = MLModelConfiguration(); config.computeUnits = units
            let model = try MLModel(contentsOf:compiled,configuration:config)
            let output = try #require(model.prediction(from:input).featureValue(for:"log_gain")?.multiArrayValue)
            #expect(GainModelCalibration.accepts(output,size:512,pattern:1))
            return (0..<output.count).map { output[$0].floatValue }
        }
        let cpu = try evaluate(.cpuOnly),neural = try evaluate(.cpuAndNeuralEngine)
        let errors = zip(cpu,neural).map { abs($0-$1) }
        #expect(neural.allSatisfy { $0.isFinite })
        #expect((errors.max() ?? .infinity) < 0.06)
        #expect(errors.reduce(0,+)/Float(errors.count) < 0.015)
    }

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

    @Test(arguments: [ExportFormat.jpeg,.heic], [512,1024]) func realModelPersistsExportsHDRAndKeepsSDRBase(format: ExportFormat, size: Int) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let modelName = size == 1024 ? "VelynGainMap1024" : "VelynGainMap"
        let compiled = try await MLModel.compileModel(at: root.appendingPathComponent("Velyn/Models/\(modelName).mlpackage"))
        defer { try? FileManager.default.removeItem(at: compiled) }
        let (base,projects,asset,service) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        var document = try await service.load()
        #expect(try await service.sourceDynamicRange() == .sdr)
        let expansion = try await service.estimateHDRExpansion(document,recipe: EditRecipe(),modelURL: compiled)
        #expect(expansion.isValid)
        #expect(expansion.predictionFingerprint == EditRecipe().gainPredictionFingerprint)
        var recipe = EditRecipe(); recipe.enhancements.hdrExpansion = expansion; recipe.enhancements.hdr = true
        let map = try #require(await service.maskResources(recipe)[expansion.resourceID])
        #expect(map.extent.size == CGSize(width: size,height: size*3/4))
        // Asymmetric fixture catches top/bottom inversion through tensor and PNG conversion.
        #expect(pixel(map,x: Double(size)*0.4,y: Double(size)*0.66)[0] > pixel(map,x: Double(size)*0.4,y: Double(size)*0.08)[0]+0.1)
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

    @Test func predictionFingerprintTracksColorButNotGainOrGeometry() async throws {
        var recipe = EditRecipe()
        let fingerprint = try #require(recipe.gainPredictionFingerprint)
        var expansion = HDRExpansion(resourceID: UUID()); expansion.predictionFingerprint = fingerprint
        recipe.enhancements.hdrExpansion = expansion; recipe.enhancements.hdr = true
        recipe.aspect = .square; recipe.quarterTurns = 1; recipe[.cropScale] = 0.8; recipe[.vignette] = 10; recipe[.vignetteFeather] = 25
        #expect(recipe.gainPredictionFingerprint == fingerprint)
        recipe.enhancements.hdrExpansion?.strength = 0.2
        #expect(recipe.gainPredictionFingerprint == fingerprint)
        #expect(try await GainPredictionContext.shared.matches(recipe))
        recipe[.exposure] = 0.5
        #expect(try await !GainPredictionContext.shared.matches(recipe))
        #expect(recipe.gainPredictionFingerprint != fingerprint)
        recipe[.exposure] = 0
        #expect(recipe.gainPredictionFingerprint == fingerprint)
        let legacy = Data("{\"resourceID\":\"\(UUID().uuidString)\",\"strength\":0.75,\"maximumBoostEV\":2}".utf8)
        #expect(try JSONDecoder().decode(HDRExpansion.self,from: legacy).predictionFingerprint == nil)
    }

    @Test func adaptiveProtectionKeepsLegacyAndRejectsInvalidMetadata() throws {
        let compressed = (0..<256).map { Float(0.04+Double($0)/255*0.4) }
        let contrast = (0..<256).map { Float(pow(10,Double($0)/255*3-3)) }
        #expect(GainMapTonePolicy.blend(luminances: compressed) > 0.95)
        #expect(GainMapTonePolicy.blend(luminances: contrast) < 0.05)
        #expect(GainMapTonePolicy.blend(luminances: Array(repeating:0.4,count:256)) == 0)
        #expect(GainMapTonePolicy.blend(luminances: [.nan,.infinity]) == 0)
        var expansion = HDRExpansion(resourceID: UUID())
        expansion.protectionBlend = .nan; #expect(!expansion.isValid)
        expansion.protectionBlend = 1.1; #expect(!expansion.isValid)
        expansion.protectionBlend = 1; expansion.edgeAwareUpsampling = true
        #expect(try JSONDecoder().decode(HDRExpansion.self,from: JSONEncoder().encode(expansion)) == expansion)
        #expect(GainMapTonePolicy.protection(luminance:0.01,blend:1) == 0)
        #expect(GainMapTonePolicy.protection(luminance:0.35,blend:1) > GainMapTonePolicy.protection(luminance:0.35,blend:0))
        #expect(GainMapTonePolicy.protection(luminance:1,blend:1) == 1)
    }

    @Test func edgeAwareGainReducesBleedAcrossSharpBoundaries() {
        let rect = CGRect(x:0,y:0,width:128,height:128)
        let dark = CIImage(color: CIColor(red:0.01,green:0.01,blue:0.01,colorSpace:RenderPipeline.linearSpace)!).cropped(to:rect)
        let source = CIImage(color:.white).cropped(to:CGRect(x:64,y:0,width:64,height:128)).composited(over:dark)
        let samples = (0..<256).map { $0 % 16 >= 8 ? Float(1) : Float(0) }
        let map = CIImage(bitmapData:samples.withUnsafeBytes { Data($0) },bytesPerRow:64,size:CGSize(width:16,height:16),format:.Rf,colorSpace:nil)
        var expansion = HDRExpansion(resourceID:UUID()); expansion.protectMidtones = false; expansion.strength = 1; expansion.maximumBoostEV = 1
        let old = GainMapPipeline.apply(source,map:map,expansion:expansion)
        expansion.edgeAwareUpsampling = true
        let new = GainMapPipeline.apply(source,map:map,expansion:expansion)
        let oldLeak = abs(pixel(old,x:62,y:64)[0]-0.01)
        let newLeak = abs(pixel(new,x:62,y:64)[0]-0.01)
        #expect(newLeak < oldLeak)
        let bright = pixel(new,x:96,y:64)
        #expect(abs(bright[0]-2) < 0.005 && abs(bright[0]-bright[1]) < 0.001)
    }

    @Test func adaptiveMapPreservesAlphaChromaAndBounds() {
        let rect = CGRect(x:0,y:0,width:64,height:64)
        let source = CIImage(color:CIColor(red:0.6,green:0.3,blue:0.15,alpha:0.5,colorSpace:RenderPipeline.linearSpace)!).cropped(to:rect)
        let map = CIImage(color:.white).cropped(to:CGRect(x:0,y:0,width:16,height:16))
        var expansion = HDRExpansion(resourceID:UUID()); expansion.protectionBlend = 1; expansion.edgeAwareUpsampling = true; expansion.maximumBoostEV = 1
        let a = pixel(source),b = pixel(GainMapPipeline.apply(source,map:map,expansion:expansion))
        #expect(abs(a[3]-b[3]) < 0.001)
        #expect(abs(b[0]/b[1]-2) < 0.003 && abs(b[1]/b[2]-2) < 0.003)
        #expect(b[0] <= a[0]*2.001)
        expansion.strength = 0
        #expect(pixel(GainMapPipeline.apply(source,map:map,expansion:expansion)) == a)
    }

    @Test func canceledPredictionCreatesNoMap() async throws {
        let (base,projects,asset,service) = try await fixture(); defer { try? FileManager.default.removeItem(at: base) }
        let document = try await service.load()
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await service.estimateHDRExpansion(document,recipe: EditRecipe()) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: projects.appendingPathComponent("\(asset.id)/masks").path))
    }
}
