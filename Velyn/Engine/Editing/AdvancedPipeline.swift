import Foundation
import CoreImage
import CoreGraphics

struct AdvancedPipeline {
    static func blend(_ foreground: CIImage, over background: CIImage, mask: CIImage) -> CIImage {
        foreground.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: mask]).cropped(to: background.extent)
    }
    static func global(_ input: CIImage, recipe r: EditRecipe) -> CIImage {
        var image = input
        let rect = input.extent, size = max(rect.width, rect.height)
        let advanced = r.enhancements
        switch advanced.profile {
        case .neutral: break
        case .portrait: image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": -0.08])
        case .landscape: image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.2]).applyingFilter("CIColorControls", parameters: ["inputContrast": 1.06])
        case .monochrome: image = image.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
        }
        if !advanced.curves.isEmpty {
            // Table domain includes HDR headroom, extending the endpoint slope beyond SDR white.
            var samples = [Float](); let domain = advanced.hdr ? 8.0 : 1.0
            for i in 0..<1024 {
                let x = Double(i) / 1023 * domain
                for channel in [CurveChannel.red, .green, .blue] {
                    func evaluate(_ curve: PointCurve?, _ value: Double) -> Double {
                        guard let curve else { return value }
                        if value <= 1 { return curve.evaluate(value) }
                        let a = curve.points[curve.points.count - 2], b = curve.points.last!
                        return b.y + (value - 1) * (b.y - a.y) / (b.x - a.x)
                    }
                    samples.append(Float(evaluate(advanced.curves[channel.rawValue], evaluate(advanced.curves[CurveChannel.rgb.rawValue], x))))
                }
            }
            image = image.applyingFilter("CIColorCurves", parameters: ["inputCurvesData": samples.withUnsafeBytes { Data($0) }, "inputCurvesDomain": CIVector(x: 0, y: domain), "inputColorSpace": RenderPipeline.linearSpace])
        }
        for (index, tone) in advanced.grading.enumerated() where tone != GradeTone() {
            var mask = LocalMask(kind: .luminance)
            mask.lower = [0, 0.2, 0.55][index]; mask.upper = [0.45, 0.8, 1][index]; mask.feather = 0.65
            let color = rgb(hue: tone.hue / 360)
            let strength = tone.saturation / 100 * 0.18
            let tint = image.applyingFilter("CIColorMatrix", parameters: [
                "inputBiasVector": CIVector(x: (color.0 - 0.5) * strength, y: (color.1 - 0.5) * strength, z: (color.2 - 0.5) * strength, w: 0)
            ]).applyingFilter("CIExposureAdjust", parameters: ["inputEV": tone.luminance / 100])
            image = blend(tint, over: image, mask: rangeMask(image, mask: mask))
        }
        if r[.dehaze] != 0 {
            let amount = r[.dehaze] / 100
            // Global atmospheric veil approximation. A local transmission model is a later quality upgrade.
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1 + amount * 0.55, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1 + amount * 0.55, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1 + amount * 0.55, w: 0),
                "inputBiasVector": CIVector(x: -amount * 0.08, y: -amount * 0.08, z: -amount * 0.08, w: 0)
            ])
        }
        if r[.texture] != 0 {
            image = image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: ["inputRadius": size / 1400, "inputIntensity": r[.texture] / 100]).cropped(to: rect)
        }
        if r[.colorNoiseReduction] > 0 || r[.defringe] > 0 {
            let smooth = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": size / 1500 * max(r[.colorNoiseReduction], r[.defringe]) / 50]).cropped(to: rect)
            // Color blend preserves luminance while smoothing chroma. This is not a lens-profile correction.
            image = smooth.applyingFilter("CIColorBlendMode", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: rect)
        }
        if r[.grain] > 0 {
            // A deterministic procedural tile keeps grain stable between preview and export.
            let side = 128
            var bytes = [UInt8](repeating: 0, count: side * side)
            var state: UInt32 = 0x13579bdf
            for i in bytes.indices { state = 1664525 &* state &+ 1013904223; bytes[i] = UInt8(state >> 24) }
            let data = Data(bytes)
            let grain = CIImage(bitmapData: data, bytesPerRow: side, size: CGSize(width: side, height: side), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
            let scale = max(0.25, size / 2000 * (0.5 + r[.grainSize] / 40))
            let tiled = grain.transformed(by: CGAffineTransform(scaleX: scale, y: scale)).applyingFilter("CIAffineTile").cropped(to: rect)
            let overlay = tiled.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            image = blend(overlay, over: image, mask: CIImage(color: CIColor(red: r[.grain] / 200, green: r[.grain] / 200, blue: r[.grain] / 200)).cropped(to: rect))
        }
        return image
    }

    static func spatial(_ input: CIImage, recipe: EditRecipe, resources: [UUID: CIImage]) -> CIImage {
        var image = input
        let bounds = input.extent
        for patch in recipe.enhancements.retouches {
            let dx = (patch.target.x - patch.source.x) * bounds.width
            let dy = (patch.source.y - patch.target.y) * bounds.height
            var source = image.clampedToExtent().transformed(by: CGAffineTransform(translationX: dx, y: dy)).cropped(to: bounds)
            if patch.kind == .heal {
                let radius = patch.radius * max(bounds.width, bounds.height) * 0.6
                let sourceLow = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
                let targetLow = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": radius])
                // Transfer source texture while adapting low-frequency color to the target.
                // Subtract blend mode clamps negative texture and reverses operand order.
                // Signed linear addition retains both darker and lighter source detail.
                let negativeLow = sourceLow.applyingFilter("CIColorMatrix",parameters: ["inputRVector": CIVector(x: -1,y: 0,z: 0,w: 0),"inputGVector": CIVector(x: 0,y: -1,z: 0,w: 0),"inputBVector": CIVector(x: 0,y: 0,z: -1,w: 0)])
                let high = source.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: negativeLow])
                source = high.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: targetLow]).cropped(to: bounds)
            }
            var mask = LocalMask(kind: .brush)
            mask.points = [patch.target]; mask.radius = patch.radius; mask.feather = patch.feather; mask.opacity = patch.opacity
            image = blend(source, over: image, mask: selection(mask, image: image, resources: [:]))
        }
        for mask in recipe.enhancements.masks where mask.enabled {
            let selection = selection(mask, image: image, resources: resources)
            var adjusted = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": mask.exposure])
            adjusted = adjusted.applyingFilter("CIColorControls", parameters: ["inputContrast": 1 + mask.contrast / 200, "inputSaturation": 1 + mask.saturation / 100])
            if mask.warmth != 0 { adjusted = adjusted.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500 + mask.warmth * 35, y: 0), "inputTargetNeutral": CIVector(x: 6500, y: 0)]) }
            if mask.texture != 0 { adjusted = adjusted.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: ["inputRadius": max(bounds.width, bounds.height) / 1400, "inputIntensity": mask.texture / 100]).cropped(to: bounds) }
            image = blend(adjusted, over: image, mask: selection)
        }
        if recipe[.lensBlur] > 0, let subject = recipe.enhancements.masks.first(where: { $0.kind == .subject && $0.resourceID != nil }), let id = subject.resourceID, let resource = resources[id] {
            let scaled = resource.transformed(by: CGAffineTransform(scaleX: bounds.width / resource.extent.width, y: bounds.height / resource.extent.height))
            let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": max(bounds.width, bounds.height) * recipe[.lensBlur] / 6000]).cropped(to: bounds)
            image = blend(image, over: blurred, mask: scaled)
        }
        if let depth = recipe.enhancements.depth, depth.amount > 0, let map = resources[depth.resourceID] {
            let scaled = map.transformed(by: CGAffineTransform(scaleX: bounds.width/map.extent.width,y: bounds.height/map.extent.height))
            var values = [Float]()
            for i in 0..<256 {
                let distance = abs(Double(i)/255-depth.focus)
                let weight = Float(min(1,max(0,(distance-depth.range/2)/max(0.05,depth.range))))
                values += [weight,weight,weight]
            }
            let blurMask = scaled.applyingFilter("CIColorCurves",parameters: ["inputCurvesData": values.withUnsafeBytes { Data($0) },"inputCurvesDomain": CIVector(x: 0,y: 1),"inputColorSpace": RenderPipeline.linearSpace])
            image = image.clampedToExtent().applyingFilter("CIMaskedVariableBlur",parameters: ["inputMask": blurMask,"inputRadius": max(bounds.width,bounds.height)*depth.amount/6000]).cropped(to: bounds)
        }
        return image
    }

    static func selection(_ mask: LocalMask, image: CIImage, resources: [UUID: CIImage]) -> CIImage {
        let bounds = image.extent
        var result: CIImage
        if let id = mask.resourceID, let resource = resources[id] {
            result = resource.transformed(by: CGAffineTransform(scaleX: bounds.width / resource.extent.width, y: bounds.height / resource.extent.height)).cropped(to: bounds)
            if mask.feather > 0 { result = result.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": mask.feather * max(bounds.width,bounds.height) / 200]).cropped(to: bounds) }
            if mask.kind == .background { result = result.applyingFilter("CIColorInvert") }
        } else if mask.kind == .luminance || mask.kind == .color { result = rangeMask(image, mask: mask) }
        else { result = drawnMask(mask, extent: bounds) }
        if mask.inverted { result = result.applyingFilter("CIColorInvert") }
        return result.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: mask.opacity, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: mask.opacity, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: mask.opacity, w: 0)])
    }

    static func drawnMask(_ mask: LocalMask, extent: CGRect) -> CIImage {
        var result = baseDrawnMask(mask,extent: extent)
        for stroke in mask.strokes ?? [] {
            var item = LocalMask(kind: .brush); item.points = stroke.points; item.radius = stroke.radius; item.feather = stroke.feather
            let shape = baseDrawnMask(item,extent: extent)
            result = stroke.erasing ? result.applyingFilter("CIMultiplyCompositing",parameters: [kCIInputBackgroundImageKey: shape.applyingFilter("CIColorInvert")]) : result.applyingFilter("CIMaximumCompositing",parameters: [kCIInputBackgroundImageKey: shape])
        }
        return result.cropped(to: extent)
    }
    private static func baseDrawnMask(_ mask: LocalMask, extent: CGRect) -> CIImage {
        let scale = min(1, 2048 / max(extent.width, extent.height))
        let w = max(1, Int(extent.width * scale)), h = max(1, Int(extent.height * scale))
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return CIImage(color: .black).cropped(to: extent) }
        context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let points = mask.points.map { CGPoint(x: $0.x * Double(w), y: (1 - $0.y) * Double(h)) }
        context.setFillColor(gray: 1, alpha: 1); context.setStrokeColor(gray: 1, alpha: 1)
        if mask.kind == .linear, points.count >= 2 {
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)] as CFArray, locations: [0, 1])!
            context.drawLinearGradient(gradient, start: points[0], end: points[1], options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else if mask.kind == .radial, points.count >= 2 {
            let box = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y), width: max(1, abs(points[1].x - points[0].x)), height: max(1, abs(points[1].y - points[0].y)))
            context.fillEllipse(in: box)
        } else if let first = points.first {
            let radius = mask.radius * Double(max(w, h))
            context.setLineWidth(radius * 2); context.setLineCap(.round); context.setLineJoin(.round)
            context.move(to: first); for point in points.dropFirst() { context.addLine(to: point) }; context.strokePath()
            context.fillEllipse(in: CGRect(x: first.x - radius, y: first.y - radius, width: radius * 2, height: radius * 2))
        }
        guard let cg = context.makeImage() else { return CIImage(color: .black).cropped(to: extent) }
        var result = CIImage(cgImage: cg)
        if mask.kind != .linear { result = result.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": mask.feather * mask.radius * Double(max(w, h)) * 0.7]) }
        return result.cropped(to: CGRect(x: 0, y: 0, width: w, height: h)).transformed(by: CGAffineTransform(scaleX: extent.width / Double(w), y: extent.height / Double(h))).cropped(to: extent)
    }
    static func rangeMask(_ image: CIImage, mask: LocalMask) -> CIImage {
        let n = 16; var values = [Float](); values.reserveCapacity(n*n*n*4)
        let feather = max(0.005, mask.feather * 0.25)
        func smooth(_ x: Double) -> Double { let t = min(1, max(0, x)); return t*t*(3-2*t) }
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let red = Double(r) / Double(n-1), green = Double(g) / Double(n-1), blue = Double(b) / Double(n-1)
            let value: Double
            if mask.kind == .color {
                let maxC = max(red, green, blue), minC = min(red, green, blue), delta = maxC - minC
                var hue = 0.0
                if delta > 0.001 {
                    if maxC == red { hue = (green-blue)/delta }
                    else if maxC == green { hue = 2+(blue-red)/delta }
                    else { hue = 4+(red-green)/delta }
                    hue = (hue / 6 + 1).truncatingRemainder(dividingBy: 1)
                }
                let distance = abs(hue - mask.hue/360)
                let width = max(0.02, mask.upper - mask.lower) / 2
                value = smooth((width - min(distance, 1-distance)) / feather) * smooth(delta * 8)
            } else {
                let l = 0.2126*red + 0.7152*green + 0.0722*blue
                value = smooth((l - mask.lower + feather) / feather) * smooth((mask.upper - l + feather) / feather)
            }
            values += [Float(value), Float(value), Float(value), 1]
        } } }
        return image.applyingFilter("CIColorCubeWithColorSpace", parameters: ["inputCubeDimension": n, "inputCubeData": values.withUnsafeBytes { Data($0) }, "inputColorSpace": RenderPipeline.linearSpace])
    }
    static func rgb(hue: Double) -> (Double, Double, Double) {
        let h = hue * 6, x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(h) % 6 { case 0: return (1,x,0); case 1: return (x,1,0); case 2: return (0,1,x); case 3: return (0,x,1); case 4: return (x,0,1); default: return (1,0,x) }
    }
}
