import Foundation

public enum RAWParameter: String, Codable, Sendable, CaseIterable {
    case temperature, tint, toneCurve, shadowBoost, localToneMap
    case luminanceNoise, colorNoise, sharpness, detail, highlightRecovery, lensCorrection
    public var title: String {
        switch self {
        case .temperature: L10n.tr("화이트밸런스")
        case .tint: L10n.tr("RAW 색조")
        case .toneCurve: L10n.tr("현상 톤 커브")
        case .shadowBoost: L10n.tr("현상 그림자")
        case .localToneMap: L10n.tr("로컬 톤")
        case .luminanceNoise: L10n.tr("RAW 밝기 노이즈")
        case .colorNoise: L10n.tr("RAW 색 노이즈")
        case .sharpness: L10n.tr("현상 선명도")
        case .detail: L10n.tr("현상 디테일")
        case .highlightRecovery: L10n.tr("하이라이트 복구")
        case .lensCorrection: L10n.tr("렌즈 보정")
        }
    }
    public var range: ClosedRange<Double> {
        switch self {
        case .temperature: 2000...50_000
        case .tint: -150...150
        case .shadowBoost: 0...200
        case .detail: 0...300
        case .highlightRecovery,.lensCorrection: 0...1
        default: 0...100
        }
    }
    public var isToggle: Bool { self == .highlightRecovery || self == .lensCorrection }
    public var step: Double { self == .temperature ? 25 : 1 }
}

/// Optional per-photo overrides; absent keys preserve the recorded/default decoder behavior.
public struct RAWAdjustments: Codable, Sendable, Equatable {
    public var values: [String: Double] = [:]
    public init() {}
    public subscript(_ parameter: RAWParameter) -> Double? {
        get { values[parameter.rawValue] }
        set { values[parameter.rawValue] = newValue }
    }
    public var isValid: Bool {
        values.allSatisfy { key,value in
            guard let parameter = RAWParameter(rawValue: key) else { return false }
            return value.isFinite && parameter.range.contains(value) && (!parameter.isToggle || value == 0 || value == 1)
        }
    }
    public var cacheKey: String { values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: ";") }
}

/// Framework-free description of controls actually supported by this source and decoder.
public struct RAWControls: Sendable {
    public let defaults: [RAWParameter: Double]
    public var parameters: [RAWParameter] { RAWParameter.allCases.filter { defaults[$0] != nil } }
}
