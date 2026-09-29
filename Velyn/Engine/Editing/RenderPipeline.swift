import Foundation
import CoreImage

struct RenderPipeline {
    static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func apply(_ source: CIImage, recipe: EditRecipe, rawExposureHandled: Bool, cube: Data?, resources: [UUID: CIImage] = [:]) -> CIImage {
        var r = recipe
        // The predicted gain is relative to the edited SDR base, including SDR color operations.
        if r.enhancements.hdrExpansion != nil { r.enhancements.hdr = false }
        var image = source
        let extent = source.extent
        for patch in r.enhancements.removals ?? [] {
            guard let replacement = resources[patch.imageID],let mask = resources[patch.maskID] else { continue }
            let box = CGRect(x: patch.topLeft.x*extent.width,y: (1-patch.bottomRight.y)*extent.height,width: (patch.bottomRight.x-patch.topLeft.x)*extent.width,height: (patch.bottomRight.y-patch.topLeft.y)*extent.height)
            let transform = CGAffineTransform(scaleX: box.width/replacement.extent.width,y: box.height/replacement.extent.height).concatenating(CGAffineTransform(translationX: box.minX,y: box.minY))
            var fixed = replacement.transformed(by: transform)
            if rawExposureHandled { fixed = fixed.applyingFilter("CIExposureAdjust",parameters: ["inputEV": r[.exposure]]) }
            let fixedMask = mask.transformed(by: CGAffineTransform(scaleX: box.width/mask.extent.width,y: box.height/mask.extent.height).concatenating(CGAffineTransform(translationX: box.minX,y: box.minY)))
            image = AdvancedPipeline.blend(fixed,over: image,mask: fixedMask)
        }
        if !rawExposureHandled && r[.exposure] != 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: ["inputEV": r[.exposure]])
        }
        if r[.warmth] != 0 || r[.tint] != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + r[.warmth] * 35, y: r[.tint] * 0.5),
                "inputTargetNeutral": CIVector(x: 6500, y: 0)
            ])
        }
        if [Adjustment.shadows, .highlights, .whites, .blacks].contains(where: { r[$0] != 0 }) {
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: r[.blacks] * 0.0015),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + r[.shadows] * 0.0015),
                "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: 0.75 + r[.highlights] * 0.0015),
                "inputPoint4": CIVector(x: 1, y: 1 + r[.whites] * 0.0015)
            ])
        }
        if r[.contrast] != 0 || r[.saturation] != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                "inputContrast": 1 + r[.contrast] / 200,
                "inputSaturation": 1 + r[.saturation] / 100
            ])
        }
        if r[.vibrance] != 0 { image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": r[.vibrance] / 100]) }
        if [Adjustment.curveShadows, .curveMidtones, .curveHighlights].contains(where: { r[$0] != 0 }) {
            // Keep the curve monotonic even at extreme user values.
            let middle = 0.5 + r[.curveMidtones] * 0.0017
            let low = min(0.25 + r[.curveShadows] * 0.0017, middle - 0.01)
            let high = max(0.75 + r[.curveHighlights] * 0.0017, middle + 0.01)
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0.25, y: low),
                "inputPoint2": CIVector(x: 0.5, y: middle), "inputPoint3": CIVector(x: 0.75, y: high),
                "inputPoint4": CIVector(x: 1, y: 1)
            ])
        }
        if let cube {
            if r.enhancements.hdr {
                var table = [Float]()
                for i in 0..<2048 { let v = Float(log2(1+Double(i)/2047*8)/log2(9)); table += [v,v,v] }
                image = image.applyingFilter("CIColorCurves",parameters: ["inputCurvesData": table.withUnsafeBytes { Data($0) },"inputCurvesDomain": CIVector(x: 0,y: 8),"inputColorSpace": linearSpace])
            }
            image = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": 32, "inputCubeData": cube, "inputColorSpace": linearSpace
            ])
            if r.enhancements.hdr {
                var inverse = [Float]()
                for i in 0..<2048 { let v = Float(pow(9,Double(i)/2047)-1); inverse += [v,v,v] }
                image = image.applyingFilter("CIColorCurves",parameters: ["inputCurvesData": inverse.withUnsafeBytes { Data($0) },"inputCurvesDomain": CIVector(x: 0,y: 1),"inputColorSpace": linearSpace])
            }
        }
        image = AdvancedPipeline.global(image, recipe: r)
        if r[.noiseReduction] > 0 {
            let original = image
            image = image.clampedToExtent().applyingFilter("CINoiseReduction", parameters: [
                "inputNoiseLevel": r[.noiseReduction] * 0.0008 * (1.5 - r[.noiseDetail] / 100), "inputSharpness": 0
            ]).cropped(to: extent)
            if r[.noiseDetail] > 50 { image = AdvancedPipeline.blend(original, over: image, mask: CIImage(color: CIColor(red: (r[.noiseDetail] - 50) / 100, green: (r[.noiseDetail] - 50) / 100, blue: (r[.noiseDetail] - 50) / 100)).cropped(to: extent)) }
        }
        if r[.clarity] != 0 {
            image = image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius": max(extent.width, extent.height) * 0.012,
                "inputIntensity": r[.clarity] / 100
            ]).cropped(to: extent)
        }
        if r[.sharpness] > 0 {
            let unsharpened = image
            image = image.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [
                "inputRadius": max(extent.width, extent.height) / 2000 * r[.sharpRadius],
                "inputIntensity": r[.sharpness] / 70
            ]).cropped(to: extent)
            if r[.sharpMasking] > 0 {
                let edge = unsharpened.applyingFilter("CIEdges", parameters: ["inputIntensity": 1 + r[.sharpMasking] / 10]).applyingFilter("CIColorControls", parameters: ["inputSaturation": 0])
                image = AdvancedPipeline.blend(image, over: unsharpened, mask: edge)
            }
        }
        image = AdvancedPipeline.spatial(image, recipe: r, resources: resources)
        image = GamutExpansion.apply(image,strength: r[.gamutExpansion])
        if recipe.enhancements.hdr, let expansion = recipe.enhancements.hdrExpansion, let map = resources[expansion.resourceID] {
            image = GainMapPipeline.apply(image, map: map, expansion: expansion)
        }
        image = geometry(image, recipe: r)
        if r[.vignette] != 0 {
            let bounds = image.extent
            image = image.applyingFilter("CIVignetteEffect", parameters: [
                "inputCenter": CIVector(x: bounds.midX, y: bounds.midY),
                "inputRadius": min(bounds.width, bounds.height) * (0.2 + r[.vignetteMidpoint] * 0.007),
                "inputIntensity": r[.vignette] / 60,
                "inputFalloff": 0.1 + r[.vignetteFeather] * 0.012
            ])
        }
        return image
    }

    static func geometry(_ input: CIImage, recipe: EditRecipe) -> CIImage {
        var image = input
        let originalRect = image.extent
        if recipe[.lensDistortion] != 0 {
            image = image.clampedToExtent().applyingFilter("CIPinchDistortion", parameters: ["inputCenter": CIVector(x: originalRect.midX, y: originalRect.midY), "inputRadius": hypot(originalRect.width, originalRect.height), "inputScale": recipe[.lensDistortion] / 150]).cropped(to: originalRect)
        }
        if recipe[.perspectiveVertical] != 0 || recipe[.perspectiveHorizontal] != 0 {
            let v = recipe[.perspectiveVertical] / 250, h = recipe[.perspectiveHorizontal] / 250
            let w = originalRect.width, height = originalRect.height
            image = image.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": CIVector(x: max(0, v)*w, y: height-max(0,h)*height),
                "inputTopRight": CIVector(x: w-max(0,v)*w, y: height-max(0,-h)*height),
                "inputBottomLeft": CIVector(x: max(0,-v)*w, y: max(0,h)*height),
                "inputBottomRight": CIVector(x: w-max(0,-v)*w, y: max(0,-h)*height)
            ])
            image = normalized(image)
            image = image.transformed(by: CGAffineTransform(scaleX: w/image.extent.width, y: height/image.extent.height)).cropped(to: originalRect)
        }
        if recipe.quarterTurns != 0 {
            image = image.oriented(forExifOrientation: [1, 6, 3, 8][recipe.quarterTurns])
        }
        if recipe.flipHorizontal { image = image.oriented(.upMirrored) }
        image = normalized(image)
        let rect = image.extent
        if recipe[.straighten] != 0 {
            let angle = recipe[.straighten] * .pi / 180
            let c = abs(cos(angle)), s = abs(sin(angle))
            // Scale enough for the inverse-rotated output rectangle to fit inside the input.
            let scale = max((rect.width * c + rect.height * s) / rect.width,
                            (rect.width * s + rect.height * c) / rect.height)
            let transform = CGAffineTransform(translationX: -rect.midX, y: -rect.midY)
                .concatenating(CGAffineTransform(rotationAngle: angle))
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY))
            image = image.transformed(by: transform).cropped(to: rect)
        }
        let crop = cropRect(in: image.extent, recipe: recipe)
        return normalized(image.cropped(to: crop))
    }

    static func cropRect(in rect: CGRect, recipe: EditRecipe) -> CGRect {
        let ratio = recipe.aspect.ratio ?? Double(rect.width / rect.height)
        var width = rect.width, height = rect.height
        if width / height > ratio { width = height * ratio } else { height = width / ratio }
        width = max(1, floor(width * recipe[.cropScale] / 100))
        height = max(1, floor(height * recipe[.cropScale] / 100))
        let x = floor((rect.width - width) * recipe[.cropX] / 100) + rect.minX
        let y = floor((rect.height - height) * (1 - recipe[.cropY] / 100)) + rect.minY
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func normalized(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
