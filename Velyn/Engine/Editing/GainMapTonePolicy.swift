import Foundation
import CoreImage

/// A bounded tone-protection policy, not an estimate of the original scene's luminance.
/// Strong-contrast SDR keeps the legacy highlight-only protection. Compressed SDR
/// transitions toward protection in perceptual brightness, retaining more midtone gain.
enum GainMapTonePolicy {
    static func blend(luminances: [Float]) -> Double {
        let values = luminances.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard values.count >= 32 else { return 0 }
        let low = max(0.0001,Double(values[values.count/10]))
        let high = max(low,Double(values[min(values.count-1,values.count*9/10)]))
        let span = log2(high/low)
        guard span >= 0.25 else { return 0 } // A flat field is not evidence of compressed HDR.
        let t = min(1,max(0,(6-span)/2))
        return t*t*(3-2*t)
    }
    static func protection(luminance: Double,blend: Double) -> Double {
        let linear = min(1,max(0,luminance))
        let perceptual = linear <= 0.0031308 ? 12.92*linear : 1.055*pow(linear,1/2.4)-0.055
        func gate(_ value: Double) -> Double {
            let t = min(1,max(0,(value-0.18)/0.62))
            return t*t*(3-2*t)
        }
        return gate(linear)*(1-blend)+gate(perceptual)*blend
    }
}

extension EditingService {
    func gainProtectionBlend(_ image: CIImage) throws -> Double {
        let bounds = image.extent
        let scale = 256/max(bounds.width,bounds.height)
        let small = RenderPipeline.normalized(image).transformed(by: .init(scaleX: scale,y: scale))
        let w = max(1,Int(small.extent.width)),h = max(1,Int(small.extent.height))
        var pixels = [Float](repeating: 0,count: w*h*4)
        pixels.withUnsafeMutableBytes { context.render(small,toBitmap: $0.baseAddress!,rowBytes: w*16,bounds: CGRect(x:0,y:0,width:w,height:h),format:.RGBAf,colorSpace:RenderPipeline.linearSpace) }
        try Task.checkCancellation()
        var luminances = [Float](); luminances.reserveCapacity(w*h)
        for i in stride(from:0,to:pixels.count,by:4) where pixels[i+3] > 0.01 {
            luminances.append(max(0,(pixels[i]*0.2126+pixels[i+1]*0.7152+pixels[i+2]*0.0722)/pixels[i+3]))
        }
        return GainMapTonePolicy.blend(luminances:luminances)
    }
}
