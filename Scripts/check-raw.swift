import Foundation
import CoreImage
import ImageIO
import CryptoKit

/// Manual, local-only check. Compile with Engine sources; pass an explicit RAW and
/// an output directory outside the repository. No personal photo becomes a fixture.
@main struct RAWCheck {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: raw-check INPUT.DNG OUTPUT_DIRECTORY") }
        try await Check().run(source: URL(fileURLWithPath: CommandLine.arguments[1]),output: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
}
private actor Check {
    func run(source: URL, output: URL) async throws {
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        let originalHash = try hash(source)
        var report: [String: Any] = ["environment": "macOS; actual Velyn engine; not iPhone execution", "inputBytes": try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0]
        let importer = OriginalImportService(root: output.appendingPathComponent("projects"))
        let asset = try await importer.importFile(at: source)
        try check(asset.isRAW && asset.sha256 == originalHash,"RAW detection and copied SHA")
        report["raw"] = asset.isRAW; report["dimensions"] = [asset.orientedWidth,asset.orientedHeight]
        report["orientation"] = asset.orientation; report["decoderVersions"] = asset.supportedRAWDecoders
        if let imageSource = CGImageSourceCreateWithURL(source as CFURL,nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(imageSource,CGImageSourceGetPrimaryImageIndex(imageSource),nil) as? [String: Any],
           let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            report["camera"] = tiff[kCGImagePropertyTIFFModel as String]
        }
        let service = EditingService(root: output.appendingPathComponent("projects"),asset: asset)
        var doc = try await service.load()
        try check(doc.raw != nil,"RAW development settings")
        let rawControls = try await service.rawControls(doc)!
        report["rawControls"] = Dictionary(uniqueKeysWithValues: rawControls.defaults.map { ($0.key.rawValue,$0.value) })
        let defaultPreview = try await service.render(doc,recipe: EditRecipe(),maxPixelSize: 768)
        var wb = EditRecipe(); var wbSettings = RAWAdjustments(); wbSettings[.temperature] = 3500; wbSettings[.tint] = 0
        wb.rawAdjustments = wbSettings
        let wbPreview = try await service.render(doc,recipe: wb,maxPixelSize: 768)
        try png(wbPreview.image,at: output.appendingPathComponent("raw-wb-3500K.png"))
        let baselinePixels = defaultPreview.image.dataProvider!.data! as Data
        let whiteBalancePixels = wbPreview.image.dataProvider!.data! as Data
        try check(baselinePixels != whiteBalancePixels,"native RAW white balance changes pixels")
        let resetPreview = try await service.render(doc,recipe: EditRecipe(),maxPixelSize: 768)
        try check(resetPreview.image.dataProvider!.data! as Data == baselinePixels,"RAW settings reset and cache key")
        report["nativeWhiteBalanceChangesPixels"] = true; report["nativeResetMatches"] = true
        var luminances: [Double] = []
        for ev in [-1.0,0,1] {
            var recipe = EditRecipe(); recipe[.exposure] = ev
            let started = Date()
            let preview = try await service.render(doc,recipe: recipe,maxPixelSize: 1536)
            report["previewEV\(ev)Seconds"] = Date().timeIntervalSince(started)
            luminances.append(mean(preview.image))
            if ev == 0 { try png(preview.image,at: output.appendingPathComponent("baseline.png")) }
        }
        try check(luminances[0] < luminances[1] && luminances[1] < luminances[2],"RAW exposure changes pixels monotonically")
        report["exposureMeans"] = luminances
        var recipe = EditRecipe(); recipe[.exposure] = 0.35; recipe[.highlights] = -35; recipe[.shadows] = 35; recipe[.warmth] = 5; recipe[.gamutExpansion] = 35
        var native = RAWAdjustments(); native[.temperature] = 5500; native[.toneCurve] = 70; native[.shadowBoost] = 110
        recipe.rawAdjustments = native
        let preview = try await service.render(doc,recipe: recipe,maxPixelSize: 1536)
        try png(preview.image,at: output.appendingPathComponent("edited.png"))
        doc.history.commit(recipe); doc.revision += 1
        doc.history.undo(); try check(doc.history.current == EditRecipe(),"undo")
        doc.history.redo(); try check(doc.history.current == recipe,"redo")
        try await service.save(doc)
        let reopened = try await EditingService(root: output.appendingPathComponent("projects"),asset: asset).load()
        try check(reopened == doc,"save and reopen")
        report["historyReopen"] = true
        var exports: [[String: Any]] = []
        for format in [ExportFormat.jpeg,.png,.heic] {
            var options = ExportSettings(); options.format = format; options.png16Bit = true; options.colorSpace = .displayP3
            let started = Date()
            let url = try await service.export(doc,settings: options,directory: output.appendingPathComponent("exports"))
            guard let src = CGImageSourceCreateWithURL(url as CFURL,nil),let props = CGImageSourceCopyPropertiesAtIndex(src,0,nil) as? [String: Any] else { throw CheckError.failed("export metadata") }
            try check(CGImageSourceGetType(src) as String? == format.typeIdentifier,"export type")
            try check(props[kCGImagePropertyPixelWidth as String] as? Int == asset.orientedWidth && props[kCGImagePropertyPixelHeight as String] as? Int == asset.orientedHeight,"full native resolution")
            try check(props[kCGImagePropertyGPSDictionary as String] == nil,"GPS removed")
            let profile = props[kCGImagePropertyProfileName as String] as? String ?? ""
            try check(profile.contains("P3"),"P3 profile")
            guard let decoded = CGImageSourceCreateImageAtIndex(src,0,[kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw CheckError.failed("export decode") }
            if format == .png { try check(decoded.bitsPerComponent == 16,"16-bit PNG") }
            try check(mean(decoded) > 0.001,"nonblack decoded export")
            exports.append(["format": format.rawValue,"bitsPerComponent": decoded.bitsPerComponent,"bytes": try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0,"seconds": Date().timeIntervalSince(started),"profile": profile,"width": decoded.width,"height": decoded.height])
            print("Verified \(format.rawValue) \(decoded.width)×\(decoded.height)")
        }
        report["exports"] = exports
        var originalOptions = ExportSettings(); originalOptions.format = .original
        let copy = try await service.export(doc,settings: originalOptions,directory: output.appendingPathComponent("exports"))
        try check(hash(copy) == originalHash && hash(source) == originalHash,"source and original export hashes")
        _ = try await importer.verify(asset)
        report["originalPreserved"] = true; report["originalExportByteIdentical"] = true; report["passed"] = true
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: output.appendingPathComponent("report.json"),options: .atomic)
        print("PASS — report at \(output.appendingPathComponent("report.json").path)")
    }
    private func check(_ condition: Bool,_ message: String) throws { if !condition { throw CheckError.failed(message) } }
    private func hash(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x",$0) }.joined() }
    private func png(_ image: CGImage,at url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil) else { throw CheckError.failed("preview output") }
        CGImageDestinationAddImage(dest,image,nil); try check(CGImageDestinationFinalize(dest),"preview output")
    }
    private func mean(_ image: CGImage) -> Double {
        var pixels = [UInt8](repeating: 0,count: 32*32*4)
        pixels.withUnsafeMutableBytes { data in
            let context = CGContext(data: data.baseAddress,width: 32,height: 32,bitsPerComponent: 8,bytesPerRow: 128,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image,in: CGRect(x: 0,y: 0,width: 32,height: 32))
        }
        return stride(from: 0,to: pixels.count,by: 4).reduce(0.0) { $0 + (Double(pixels[$1])+Double(pixels[$1+1])+Double(pixels[$1+2]))/(3*255*1024) }
    }
}
private enum CheckError: Error { case failed(String) }
