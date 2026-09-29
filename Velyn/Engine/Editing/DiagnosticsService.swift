import Foundation
import CoreImage

extension EditingService {
    public func diagnostics(_ document: EditDocument,recipe: EditRecipe) throws -> EditDiagnostics {
        try validate(document)
        let image = try processed(document,recipe: recipe,maxPixelSize: 256)
        try Task.checkCancellation()
        let width = Int(image.extent.width),height = Int(image.extent.height)
        var pixels = [Float](repeating: 0,count: width*height*4)
        pixels.withUnsafeMutableBytes { context.render(image,toBitmap: $0.baseAddress!,rowBytes: width*16,bounds: image.extent,format: .RGBAf,colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!) }
        return Self.measure(pixels)
    }
    static func measure(_ pixels: [Float]) -> EditDiagnostics {
        var red = [Int](repeating: 0,count: 128),green = red,blue = red
        var shadows = 0,above = 0,count = 0,peak = 0.0,total = 0.0
        func bin(_ v: Double) -> Int {
            let linear = min(1,max(0,v))
            let encoded = linear <= 0.0031308 ? 12.92*linear : 1.055*pow(linear,1/2.4)-0.055
            return min(127,max(0,Int((encoded*127).rounded())))
        }
        for i in stride(from: 0,to: pixels.count-3,by: 4) {
            let a = Double(pixels[i+3])
            guard a.isFinite,a > 0.001 else { continue }
            let r = Double(pixels[i])/a,g = Double(pixels[i+1])/a,b = Double(pixels[i+2])/a
            guard r.isFinite,g.isFinite,b.isFinite else { continue }
            let high = max(r,g,b),luma = max(0,0.2289746*r+0.6917385*g+0.0792869*b)
            peak = max(peak,high); total += luma; count += 1
            if luma <= 0.003 { shadows += 1 }
            if high > 1.001 { above += 1 }
            red[bin(r)] += 1; green[bin(g)] += 1; blue[bin(b)] += 1
        }
        let denominator = Double(max(1,count))
        return EditDiagnostics(red: red,green: green,blue: blue,shadowFraction: Double(shadows)/denominator,
                               aboveSDRFraction: Double(above)/denominator,peak: peak,averageLuminance: total/denominator,sampleCount: count)
    }

    /// Attach measured headroom so UIKit can adapt HDR content to the active display.
    func displayImage(_ image: CIImage,bounds: CGRect,hdr: Bool) throws -> CGImage {
        let space = CGColorSpace(name: hdr ? CGColorSpace.extendedLinearDisplayP3 : CGColorSpace.displayP3)!
        if #available(macOS 26,iOS 26,*) {
            guard let result = context.createCGImage(image,from: bounds,format: hdr ? .RGBAh : .RGBA8,colorSpace: space,deferred: false,calculateHDRStats: hdr) else { throw EditorFailure.renderFailed }
            return result
        }
        guard let result = context.createCGImage(image,from: bounds,format: hdr ? .RGBAh : .RGBA8,colorSpace: space) else { throw EditorFailure.renderFailed }
        return result
    }
}
