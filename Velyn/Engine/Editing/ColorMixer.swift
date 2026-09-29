import Foundation

/// The LUT is sampled in linear sRGB; hue/saturation/lightness controls operate in encoded sRGB.
enum ColorMixer {
    static let centers: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]
    static func transform(_ rgb: SIMD3<Double>, bands: [ColorBand]) -> SIMD3<Double> {
        let encoded = SIMD3(encode(rgb.x), encode(rgb.y), encode(rgb.z))
        let hi = max(encoded.x, encoded.y, encoded.z), lo = min(encoded.x, encoded.y, encoded.z)
        let delta = hi - lo, light = (hi + lo) / 2
        guard delta > 0.000001 else { return rgb }
        var hue: Double
        if hi == encoded.x { hue = ((encoded.y - encoded.z) / delta).truncatingRemainder(dividingBy: 6) }
        else if hi == encoded.y { hue = (encoded.z - encoded.x) / delta + 2 }
        else { hue = (encoded.x - encoded.y) / delta + 4 }
        hue = (hue * 60 + 360).truncatingRemainder(dividingBy: 360)
        let saturation = delta / max(0.000001, 1 - abs(2 * light - 1))
        var weight = 0.0, dh = 0.0, ds = 0.0, dl = 0.0
        for index in 0..<8 {
            let distance = min(abs(hue - centers[index]), 360 - abs(hue - centers[index]))
            let w = pow(max(0, 1 - distance / 65), 2)
            weight += w; dh += bands[index].hue * w; ds += bands[index].saturation * w; dl += bands[index].luminance * w
        }
        guard weight > 0 else { return rgb }
        let h = (hue + dh / weight * 0.3 + 360).truncatingRemainder(dividingBy: 360) / 60
        let s = min(max(saturation * (1 + ds / weight / 100), 0), 1)
        let l = min(max(light + dl / weight / 250 * saturation, 0), 1)
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let value: SIMD3<Double>
        switch h {
        case ..<1: value = SIMD3(c, x, 0)
        case ..<2: value = SIMD3(x, c, 0)
        case ..<3: value = SIMD3(0, c, x)
        case ..<4: value = SIMD3(0, x, c)
        case ..<5: value = SIMD3(x, 0, c)
        default: value = SIMD3(c, 0, x)
        }
        return SIMD3(decode(value.x + m), decode(value.y + m), decode(value.z + m))
    }
    static func cube(bands: [ColorBand], dimension: Int = 32, hdr: Bool = false) -> Data {
        var values = [Float]()
        values.reserveCapacity(dimension * dimension * dimension * 4)
        for b in 0..<dimension { for g in 0..<dimension { for r in 0..<dimension {
            let unit = SIMD3(Double(r), Double(g), Double(b)) / Double(dimension - 1)
            let input = hdr ? SIMD3(pow(9,unit.x)-1,pow(9,unit.y)-1,pow(9,unit.z)-1) : unit
            let headroom = max(1,max(input.x,input.y,input.z))
            let rgb = transform(input / headroom, bands: bands) * headroom
            let output = hdr ? SIMD3(log2(1+rgb.x)/log2(9),log2(1+rgb.y)/log2(9),log2(1+rgb.z)/log2(9)) : rgb
            values.append(contentsOf: [Float(output.x), Float(output.y), Float(output.z), 1])
        } } }
        return values.withUnsafeBytes { Data($0) }
    }
    private static func encode(_ x: Double) -> Double { x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055 }
    private static func decode(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
}
