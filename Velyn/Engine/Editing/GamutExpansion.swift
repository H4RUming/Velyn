import Foundation
import CoreImage

/// An analytical color look, not recovery of a photograph's unknown original colors.
/// The cube operates in linear Display P3 and moves chroma toward its boundary at constant Y.
enum GamutExpansion {
    static let dimension = 33
    static let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    // Initialized on the rendering actor, shared immutably, and reused for every strength.
    static let cube: Data = {
        var values = [Float](); values.reserveCapacity(dimension*dimension*dimension*4)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let output = expanded(SIMD3(Double(r),Double(g),Double(b))/Double(dimension-1))
            values += [Float(output.x),Float(output.y),Float(output.z),1]
        } } }
        return values.withUnsafeBytes { Data($0) }
    }()

    static func apply(_ image: CIImage, strength: Double) -> CIImage {
        guard strength > 0 else { return image }
        let expanded = image.applyingFilter("CIColorCubeWithColorSpace",parameters: [
            "inputCubeDimension": dimension,"inputCubeData": cube,"inputColorSpace": space,
            "inputExtrapolate": true
        ])
        return image.applyingFilter("CIDissolveTransition",parameters: [
            "inputTargetImage": expanded,"inputTime": min(1,strength/100)
        ]).cropped(to: image.extent)
    }

    static func expanded(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let y = p.x*0.2289745641 + p.y*0.6917385218 + p.z*0.0792869141
        let chroma = p-SIMD3(repeating: y)
        guard y > 0.00001, y < 0.99999, max(abs(chroma.x),abs(chroma.y),abs(chroma.z)) > 0.00001 else { return p }
        let sRGBDirection = toSRGB(chroma)
        let smallBoundary = boundary(y: y,direction: sRGBDirection)
        let wideBoundary = boundary(y: y,direction: chroma)
        guard smallBoundary > 0, wideBoundary > smallBoundary else { return p }
        // Low-chroma colors stay unchanged; approach the sRGB boundary smoothly.
        let saturation = smoothstep(0.35,1,1/smallBoundary)
        let rgb = toSRGB(p)
        let high = max(rgb.x,rgb.y,rgb.z), low = min(rgb.x,rgb.y,rgb.z)
        let delta = high-low
        var hue = 0.0
        if delta > 0.00001 {
            if high == rgb.x { hue = 60*((rgb.y-rgb.z)/delta).truncatingRemainder(dividingBy: 6) }
            else if high == rgb.y { hue = 60*((rgb.z-rgb.x)/delta+2) }
            else { hue = 60*((rgb.x-rgb.y)/delta+4) }
            if hue < 0 { hue += 360 }
        }
        let hueDistance = min(abs(hue-25),360-abs(hue-25))
        // This protects a broad warm hue range, not semantic face/skin detection.
        let warmProtection = 1-0.85*exp(-pow(hueDistance/25,2))
        let room = max(0,min(wideBoundary-smallBoundary,wideBoundary-1))
        let scale = 1 + 0.65*room*saturation*warmProtection
        return SIMD3(repeating: y)+chroma*scale
    }
    // D65 matrices derived from W3C CSS Color 4 sample conversions.
    static func toSRGB(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(1.2249401763*p.x-0.2249401763*p.y,
              -0.0420569547*p.x+1.0420569547*p.y,
              -0.0196375546*p.x-0.0786360456*p.y+1.0982736002*p.z)
    }
    private static func boundary(y: Double,direction: SIMD3<Double>) -> Double {
        var result = Double.infinity
        for i in 0..<3 {
            if direction[i] > 0.0000001 { result = min(result,(1-y)/direction[i]) }
            else if direction[i] < -0.0000001 { result = min(result,-y/direction[i]) }
        }
        return result
    }
    private static func smoothstep(_ low: Double,_ high: Double,_ value: Double) -> Double {
        let t = min(1,max(0,(value-low)/(high-low)))
        return t*t*(3-2*t)
    }
}
