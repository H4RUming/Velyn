import Foundation
import CoreImage

/// All callers live on EditingService; no mutable filter crosses its actor boundary.
enum RAWDeveloper {
    static func filter(at url: URL,development: RAWDevelopment,adjustments: RAWAdjustments? = nil) throws -> CIRAWFilter {
        guard let filter = CIRAWFilter(imageURL: url) else { throw EditorFailure.unsupportedRAW }
        let version = CIRAWDecoderVersion(rawValue: development.decoder)
        guard filter.supportedDecoderVersions.contains(version),adjustments?.isValid ?? true else { throw EditorFailure.invalidDocument }
        filter.decoderVersion = version
        filter.baselineExposure = development.baselineExposure
        filter.boostAmount = development.boost
        filter.boostShadowAmount = development.boostShadows
        filter.shadowBias = development.shadowBias
        filter.neutralTemperature = development.temperature
        filter.neutralTint = development.tint
        let supported = controls(filter).defaults
        for parameter in RAWParameter.allCases {
            guard let value = adjustments?[parameter],supported[parameter] != nil else { continue }
            switch parameter {
            case .temperature: filter.neutralTemperature = Float(value)
            case .tint: filter.neutralTint = Float(value)
            case .toneCurve: filter.boostAmount = Float(value/100)
            case .shadowBoost: filter.boostShadowAmount = Float(value/100)
            case .localToneMap: filter.localToneMapAmount = Float(value/100)
            case .luminanceNoise: filter.luminanceNoiseReductionAmount = Float(value/100)
            case .colorNoise: filter.colorNoiseReductionAmount = Float(value/100)
            case .sharpness: filter.sharpnessAmount = Float(value/100)
            case .detail: filter.detailAmount = Float(value/100)
            case .highlightRecovery:
                if #available(macOS 26,iOS 26,*) { filter.isHighlightRecoveryEnabled = value == 1 }
            case .lensCorrection: filter.isLensCorrectionEnabled = value == 1
            }
        }
        return filter
    }
    static func controls(_ filter: CIRAWFilter) -> RAWControls {
        var values: [RAWParameter: Double] = [.temperature: Double(filter.neutralTemperature),.tint: Double(filter.neutralTint),
            .toneCurve: Double(filter.boostAmount)*100,.shadowBoost: Double(filter.boostShadowAmount)*100]
        if filter.isLocalToneMapSupported { values[.localToneMap] = Double(filter.localToneMapAmount)*100 }
        if filter.isLuminanceNoiseReductionSupported { values[.luminanceNoise] = Double(filter.luminanceNoiseReductionAmount)*100 }
        if filter.isColorNoiseReductionSupported { values[.colorNoise] = Double(filter.colorNoiseReductionAmount)*100 }
        if filter.isSharpnessSupported { values[.sharpness] = Double(filter.sharpnessAmount)*100 }
        if filter.isDetailSupported { values[.detail] = Double(filter.detailAmount)*100 }
        if filter.isLensCorrectionSupported { values[.lensCorrection] = filter.isLensCorrectionEnabled ? 1 : 0 }
        if #available(macOS 26,iOS 26,*),filter.isHighlightRecoverySupported { values[.highlightRecovery] = filter.isHighlightRecoveryEnabled ? 1 : 0 }
        return RAWControls(defaults: values)
    }
}
extension EditingService {
    public func rawControls(_ document: EditDocument) throws -> RAWControls? {
        try validate(document)
        guard let raw = document.raw else { return nil }
        return RAWDeveloper.controls(try RAWDeveloper.filter(at: original,development: raw))
    }
}
