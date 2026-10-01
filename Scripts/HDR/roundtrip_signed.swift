import Foundation
import CoreImage
import ImageIO

/// Private experiment: actual model EV fields through the app's signed storage,
/// preview and JPEG/HEIC export. Compile alongside engine sources. No inference
/// or networking here; inputs are produced by compare_signed_models.py.
@main struct SignedModelRoundTrip {
    static func main() async throws {
        guard CommandLine.arguments.count == 4 else { fatalError("Usage: signed-roundtrip FIXTURES PREDICTIONS OUTPUT") }
        try await Runner().run(fixtures:URL(fileURLWithPath:CommandLine.arguments[1]),
                               predictions:URL(fileURLWithPath:CommandLine.arguments[2]),
                               output:URL(fileURLWithPath:CommandLine.arguments[3]))
    }
}
private actor Runner {
    let context = CIContext(options:[.workingColorSpace:RenderPipeline.linearSpace,.workingFormat:CIFormat.RGBAf])
    func floats(_ url:URL) throws -> [Float] {
        let data = try Data(contentsOf:url)
        guard data.count % 4 == 0 else { throw EditorFailure.invalidDocument }
        return data.withUnsafeBytes { bytes in (0..<data.count/4).map { bytes.loadUnaligned(fromByteOffset:$0*4,as:Float.self) } }
    }
    func pixels(_ image:CIImage,w:Int,h:Int) -> [Float] {
        var values = [Float](repeating:0,count:w*h*4)
        values.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:CGRect(x:0,y:0,width:w,height:h),format:.RGBAf,colorSpace:RenderPipeline.linearSpace) }
        return values
    }
    func dump(_ values:[Float],_ path:URL) throws { try values.withUnsafeBytes { try Data($0).write(to:path) } }
    func decodedPixels(_ image:CGImage) throws -> [Float] {
        var values = [Float](repeating:0,count:image.width*image.height*4)
        try values.withUnsafeMutableBytes { bytes in
            let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            guard let bitmap = CGContext(data:bytes.baseAddress,width:image.width,height:image.height,bitsPerComponent:32,bytesPerRow:image.width*16,
                                         space:RenderPipeline.linearSpace,bitmapInfo:info) else { throw EditorFailure.renderFailed }
            bitmap.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        }
        return values
    }
    func run(fixtures:URL,predictions:URL,output:URL) async throws {
        let fm = FileManager.default
        var rows = [[String:Any]]()
        for source in try fm.contentsOfDirectory(at:fixtures,includingPropertiesForKeys:nil).sorted(by:{$0.lastPathComponent<$1.lastPathComponent}) {
            let metadata = source.appendingPathComponent("prepared.json")
            guard fm.fileExists(atPath:metadata.path) else { continue }
            let info = try JSONSerialization.jsonObject(with:Data(contentsOf:metadata)) as! [String:Any]
            let w = info["sampleWidth"] as! Int,h = info["sampleHeight"] as! Int,id = source.lastPathComponent
            let base = try floats(source.appendingPathComponent("base.f32"))
            guard base.count == w*h*4 else { throw EditorFailure.invalidDocument }
            for model in ["ditm","hdrunet-srgb"] {
                let folder = output.appendingPathComponent(id+"-"+model)
                try fm.createDirectory(at:folder,withIntermediateDirectories:true)
                let input = folder.appendingPathComponent("base.png")
                let image = CIImage(bitmapData:base.withUnsafeBytes { Data($0) },bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:RenderPipeline.linearSpace)
                try context.writePNGRepresentation(of:image,to:input,format:.RGBA16,colorSpace:CGColorSpace(name:CGColorSpace.displayP3)!)
                let root = folder.appendingPathComponent("projects")
                let importer = OriginalImportService(root:root),asset = try await importer.importFile(at:input)
                let service = EditingService(root:root,asset:asset)
                var document = try await service.load(),recipe = EditRecipe()
                let ev = try floats(predictions.appendingPathComponent(id+"-"+model+"-signed.f32"))
                let expansion = try await service.storeSignedHDRExpansion(logGains:ev,width:w,height:h,recipe:recipe)
                recipe.enhancements.hdrExpansion = expansion; recipe.enhancements.hdr = true
                document.history.commit(recipe); document.revision += 1; try await service.save(document)
                let reopened = try await EditingService(root:root,asset:asset).load()
                guard reopened.history.current == recipe else { throw EditorFailure.invalidDocument }
                let hdr = try await service.processed(reopened,recipe:recipe,maxPixelSize:nil)
                let rendered = pixels(hdr,w:w,h:h)
                try dump(rendered,folder.appendingPathComponent("rendered.f32"))
                var baseRecipe = recipe; baseRecipe.enhancements.hdr = false
                let sdr = try await service.processed(reopened,recipe:baseRecipe,maxPixelSize:nil)
                try dump(pixels(sdr,w:w,h:h),folder.appendingPathComponent("sdr-rendered.f32"))
                let preview = try await service.render(reopened,recipe:recipe)
                try dump(pixels(CIImage(cgImage:preview.image),w:w,h:h),folder.appendingPathComponent("preview.f32"))
                var record:[String:Any] = ["id":id,"model":model,"width":w,"height":h,"hdrContentHeadroom":hdr.contentHeadroom,"negativeFraction":Double(ev.filter{$0 < -0.02}.count)/Double(ev.count)]
                for format in [ExportFormat.jpeg,.heic] {
                    var settings = ExportSettings(); settings.format = format; settings.hdr = true; settings.quality = 1
                    let url:URL
                    do { url = try await service.export(reopened,settings:settings,directory:folder) }
                    catch EditorFailure.exportFailed {
                        record[format.fileExtension] = ["rejected":true,"hasGainMap":false]
                        continue
                    }
                    guard let encoded = CGImageSourceCreateWithURL(url as CFURL,nil) else { throw EditorFailure.exportFailed }
                    let primary = CGImageSourceGetPrimaryImageIndex(encoded)
                    let hasGainMap = [kCGImageAuxiliaryDataTypeHDRGainMap,kCGImageAuxiliaryDataTypeISOGainMap].contains { CGImageSourceCopyAuxiliaryDataInfoAtIndex(encoded,primary,$0) != nil }
                    for expand in [false,true] {
                        // Keep the embedded SDR base. A DecodeToSDR request may
                        // instead tone-map the reconstructed HDR. Eager CG decode
                        // avoids a macOS 27 CI direct-copy readback crash observed
                        // on these 512px fixtures (not an iPhone finding).
                        var options:[CFString:Any] = [kCGImageSourceShouldCacheImmediately:true,kCGImageSourceShouldAllowFloat:true]
                        if expand { options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR }
                        guard let decoded = CGImageSourceCreateImageAtIndex(encoded,primary,options as CFDictionary) else { throw EditorFailure.exportFailed }
                        try dump(decodedPixels(decoded),folder.appendingPathComponent(format.fileExtension+(expand ? "-hdr.f32":"-sdr.f32")))
                    }
                    record[format.fileExtension] = ["rejected":false,"hasGainMap":hasGainMap,"bytes":try Data(contentsOf:url).count]
                }
                _ = try await importer.verify(asset)
                record["originalPreserved"] = true
                rows.append(record)
                print("Verified \(id) \(model)"); fflush(stdout)
            }
        }
        try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("roundtrip.json"))
    }
}
