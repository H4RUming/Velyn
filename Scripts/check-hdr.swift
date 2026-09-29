import Foundation
import CoreImage
import CoreML
import ImageIO

/// Local manual HDR regression. Pass SDR input, output outside the repo, model package.
@main struct HDRCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Usage: hdr-check SDR_INPUT OUTPUT_DIRECTORY MODEL_PACKAGE") }
        let arguments = CommandLine.arguments
        try await CheckHDR().run(input: URL(fileURLWithPath: arguments[1]),directory: URL(fileURLWithPath: arguments[2]),model: URL(fileURLWithPath: arguments[3]))
    }
}
private actor CheckHDR {
    func run(input: URL,directory: URL,model: URL) async throws {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let compiled = try await MLModel.compileModel(at: model)
        defer { try? FileManager.default.removeItem(at: compiled) }
        let root = directory.appendingPathComponent("projects")
        let importer = OriginalImportService(root: root),asset = try await OriginalImportService(root: root).importFile(at: input)
        let sourceService = EditingService(root: root,asset: asset)
        let sourceDocument = try await sourceService.load()
        let sourceRange = try await sourceService.sourceDynamicRange()
        var testAsset = asset
        if sourceRange != .sdr {
            var settings = ExportSettings(); settings.format = .png; settings.colorSpace = .displayP3
            let sdr = try await sourceService.export(sourceDocument,settings: settings,directory: directory.appendingPathComponent("SDR-input"))
            testAsset = try await importer.importFile(at: sdr)
        }
        let service = EditingService(root: root,asset: testAsset)
        var document = try await service.load()
        let expansion = try await service.estimateHDRExpansion(document,recipe: EditRecipe(),modelURL: compiled)
        var recipe = EditRecipe(); recipe.enhancements.hdr = true; recipe.enhancements.hdrExpansion = expansion
        let baseline = try await service.diagnostics(document,recipe: EditRecipe())
        let protected = try await service.diagnostics(document,recipe: recipe)
        var legacy = recipe; legacy.enhancements.hdrExpansion?.protectMidtones = false
        let unprotected = try await service.diagnostics(document,recipe: legacy)
        let preview = try await service.render(document,recipe: recipe)
        var report: [String: Any] = ["environment": "macOS engine; user supplied local image; no display acceptance", "dimensions": [asset.orientedWidth,asset.orientedHeight],"inputDynamicRange": sourceRange.rawValue,"derivedSDRInput": sourceRange != .sdr,
            "sdr": stats(baseline),"legacyHDR": stats(unprotected),"protectedHDR": stats(protected),
            "previewContentHeadroom": CIImage(cgImage: preview.image).contentHeadroom]
        document.history.commit(recipe); document.revision += 1; try await service.save(document)
        var outputs: [[String: Any]] = []
        let context = CIContext(options: [.workingColorSpace: RenderPipeline.linearSpace])
        for format in [ExportFormat.jpeg,.heic] {
            var settings = ExportSettings(); settings.format = format; settings.hdr = true; settings.colorSpace = .displayP3
            let url = try await service.export(document,settings: settings,directory: directory)
            guard let source = CGImageSourceCreateWithURL(url as CFURL,nil),let restored = CIImage(contentsOf: url,options: [.expandToHDR: true]) else { throw EditorFailure.exportFailed }
            let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeHDRGainMap) != nil || CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,0,kCGImageAuxiliaryDataTypeISOGainMap) != nil
            let factor = min(1,256/max(restored.extent.width,restored.extent.height)),small = restored.transformed(by: CGAffineTransform(scaleX: factor,y: factor))
            let bounds = CGRect(x: 0,y: 0,width: floor(small.extent.width),height: floor(small.extent.height))
            var pixels = [Float](repeating: 0,count: Int(bounds.width*bounds.height)*4)
            pixels.withUnsafeMutableBytes { context.render(small,toBitmap: $0.baseAddress!,rowBytes: Int(bounds.width)*16,bounds: bounds,format: .RGBAf,colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!) }
            let decoded = EditingService.measure(pixels)
            guard auxiliary,decoded.peak > 1.01 else { throw EditorFailure.exportFailed }
            outputs.append(["format": format.rawValue,"gainMapPresent": auxiliary,"decodedPeak": decoded.peak,"decodedAboveSDR": decoded.aboveSDRFraction])
        }
        report["exports"] = outputs
        _ = try await importer.verify(asset); report["originalPreserved"] = true
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: directory.appendingPathComponent("report.json"))
        print(String(data: try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]),encoding: .utf8)!)
    }
    private func stats(_ value: EditDiagnostics) -> [String: Double] {
        ["peak": value.peak,"meanLuminance": value.averageLuminance,"aboveSDRFraction": value.aboveSDRFraction,"shadowFraction": value.shadowFraction]
    }
}
