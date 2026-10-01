import Foundation
import CoreImage
import ImageIO

/// Codec-only check for private candidate RGB fixtures; not a full-resolution export benchmark.
@main struct HDRRoundTrip {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Usage: hdr-roundtrip CANDIDATE_DIRECTORY") }
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        let linear = CGColorSpace(name:CGColorSpace.extendedLinearSRGB)!
        let p3 = CGColorSpace(name:CGColorSpace.displayP3)!
        let context = CIContext(options:[.workingColorSpace:linear,.workingFormat:CIFormat.RGBAf])
        for folder in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil).sorted(by:{$0.lastPathComponent<$1.lastPathComponent}) {
            let metadata = folder.appendingPathComponent("dimensions.json")
            guard FileManager.default.fileExists(atPath:metadata.path) else { continue }
            let info = try JSONSerialization.jsonObject(with:Data(contentsOf:metadata)) as! [String:Int]
            let w=info["width"]!,h=info["height"]!,bounds=CGRect(x:0,y:0,width:w,height:h)
            func image(_ name:String) throws -> CIImage {
                CIImage(bitmapData:try Data(contentsOf:folder.appendingPathComponent(name+".f32")),bytesPerRow:w*16,size:bounds.size,format:.RGBAf,colorSpace:linear)
            }
            let base=try image("base"),hdr=try image("candidate")
            var report:[String:Any]=[:]
            for format in ["jpeg","heic"] {
                let url=folder.appendingPathComponent("candidate."+format)
                let options:[CIImageRepresentationOption:Any]=[.hdrImage:hdr,CIImageRepresentationOption(rawValue:kCGImageDestinationLossyCompressionQuality as String):0.95]
                if format=="jpeg" { try context.writeJPEGRepresentation(of:base,to:url,colorSpace:p3,options:options) }
                else { try context.writeHEIFRepresentation(of:base,to:url,format:.RGBA8,colorSpace:p3,options:options) }
                let source=CGImageSourceCreateWithURL(url as CFURL,nil)!
                let primary=CGImageSourceGetPrimaryImageIndex(source)
                let hasGainMap=[kCGImageAuxiliaryDataTypeHDRGainMap,kCGImageAuxiliaryDataTypeISOGainMap].contains { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source,primary,$0) != nil }
                for expand in [false,true] {
                    let decoded=CIImage(contentsOf:url,options:[.expandToHDR:expand,.toneMapHDRtoSDR:false])!
                    var pixels=[Float](repeating:0,count:w*h*4)
                    pixels.withUnsafeMutableBytes { context.render(decoded,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:bounds,format:.RGBAf,colorSpace:linear) }
                    try pixels.withUnsafeBytes { try Data($0).write(to:folder.appendingPathComponent(format+(expand ? "-hdr.f32":"-sdr.f32"))) }
                }
                report[format]=["hasGainMap":hasGainMap,"bytes":try Data(contentsOf:url).count]
                guard hasGainMap else { fatalError("Missing exported gain map") }
            }
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("roundtrip.json"))
            print("Round-tripped \(folder.lastPathComponent)")
        }
    }
}
