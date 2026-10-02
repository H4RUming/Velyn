import Foundation
import ImageIO
import CoreGraphics

// Explicit research utility. Output is private pixel data, never a repo fixture.
// Decode both representations from the same source and draw into float bitmaps;
// this avoids the macOS 27 direct CI float-readback issue documented previously.
@main struct DecodeCameraPairs {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("Usage: decode-camera INPUT_MANIFEST OUTPUT") }
        let inputs = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [[String:String]]
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var records = [[String:Any]]()
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func pixels(_ image: CGImage) throws -> [Float] {
            var values = [Float](repeating: 0, count: image.width * image.height * 4)
            try values.withUnsafeMutableBytes { bytes in
                let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                guard let ctx = CGContext(data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 32, bytesPerRow: image.width * 16, space: space, bitmapInfo: info) else { throw CocoaError(.fileReadCorruptFile) }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return values
        }
        for (index, row) in inputs.enumerated() {
            let record: [String:Any] = autoreleasepool {
                let id = row["id"]!
                var result: [String:Any] = ["id":id]
                do {
                    guard id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                          let source = CGImageSourceCreateWithURL(URL(fileURLWithPath:row["path"]!) as CFURL,nil) else { throw CocoaError(.fileReadCorruptFile) }
                    let primary = CGImageSourceGetPrimaryImageIndex(source)
                    guard let properties = CGImageSourceCopyPropertiesAtIndex(source,primary,nil) as? [String:Any],
                          properties[kCGImagePropertyPixelWidth as String] != nil else { throw CocoaError(.fileReadCorruptFile) }
                    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String:Any] ?? [:]
                    result["captureTime"] = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String ?? ""
                    let hasMap = [kCGImageAuxiliaryDataTypeHDRGainMap,kCGImageAuxiliaryDataTypeISOGainMap].contains { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,primary,$0) != nil }
                    result["hasGainMap"] = hasMap
                    guard hasMap else { result["status"] = "no-gain-map"; return result }
                    var options: [CFString:Any] = [kCGImageSourceShouldAllowFloat:true,kCGImageSourceShouldCacheImmediately:true,
                        kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:512]
                    guard let base = CGImageSourceCreateThumbnailAtIndex(source,primary,options as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
                    options[kCGImageSourceDecodeRequest] = kCGImageSourceDecodeToHDR
                    guard let hdr = CGImageSourceCreateThumbnailAtIndex(source,primary,options as CFDictionary),base.width == hdr.width,base.height == hdr.height else { throw CocoaError(.fileReadCorruptFile) }
                    let a = try pixels(base), b = try pixels(hdr)
                    guard a.allSatisfy({$0.isFinite}), b.allSatisfy({$0.isFinite}) else { throw CocoaError(.fileReadCorruptFile) }
                    let folder = output.appendingPathComponent(id,isDirectory:true)
                    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                    for (name,values) in [("base",a),("reference",b)] {
                        try values.withUnsafeBytes { try Data($0).write(to:folder.appendingPathComponent(name+".f32"),options:.atomic) }
                    }
                    result["width"] = base.width; result["height"] = base.height
                    result["baseBits"] = base.bitsPerComponent; result["hdrBits"] = hdr.bitsPerComponent
                    result["status"] = "decoded"
                } catch { result["status"] = "decode-error" }
                return result
            }
            records.append(record)
            if (index+1)%25 == 0 || index+1 == inputs.count {
                print("Decoded \(index+1)/\(inputs.count); paired \(records.filter { $0["status"] as? String == "decoded" }.count)"); fflush(stdout)
                try JSONSerialization.data(withJSONObject:records,options:[.sortedKeys]).write(to:output.appendingPathComponent("decoded.json"),options:.atomic)
            }
        }
    }
}
