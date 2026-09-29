import Foundation

public enum Adjustment: String, Codable, Sendable, CaseIterable {
    case exposure, contrast, highlights, shadows, whites, blacks
    case warmth, tint, vibrance, saturation, gamutExpansion
    case clarity, vignette, sharpness, noiseReduction
    case texture, dehaze, grain, grainSize, sharpRadius, sharpMasking, colorNoiseReduction, noiseDetail
    case vignetteFeather, vignetteMidpoint, perspectiveVertical, perspectiveHorizontal, lensDistortion, defringe, lensBlur
    case curveShadows, curveMidtones, curveHighlights
    case straighten, cropScale, cropX, cropY

    public var title: String {
        switch self {
        case .gamutExpansion: "색역 확장"
        case .texture: "텍스처"
        case .dehaze: "안개 제거"
        case .grain: "입자"
        case .grainSize: "입자 크기"
        case .sharpRadius: "선명도 반경"
        case .sharpMasking: "윤곽 마스킹"
        case .colorNoiseReduction: "색 노이즈 감소"
        case .noiseDetail: "디테일 보존"
        case .vignetteFeather: "비네팅 경계"
        case .vignetteMidpoint: "비네팅 중심 범위"
        case .perspectiveVertical: "수직 원근"
        case .perspectiveHorizontal: "수평 원근"
        case .lensDistortion: "렌즈 왜곡"
        case .defringe: "색 테두리 감소"
        case .lensBlur: "배경 흐림"
        case .exposure: "노출"
        case .contrast: "대비"
        case .highlights: "하이라이트"
        case .shadows: "그림자"
        case .whites: "흰색 계열"
        case .blacks: "검정 계열"
        case .warmth: "색온도"
        case .tint: "색조"
        case .vibrance: "생동감"
        case .saturation: "채도"
        case .clarity: "명료도"
        case .vignette: "비네팅"
        case .sharpness: "선명하게"
        case .noiseReduction: "노이즈 감소"
        case .curveShadows: "어두운 영역"
        case .curveMidtones: "중간 영역"
        case .curveHighlights: "밝은 영역"
        case .straighten: "수평"
        case .cropScale: "자르기 크기"
        case .cropX: "가로 위치"
        case .cropY: "세로 위치"
        }
    }
    public var range: ClosedRange<Double> {
        switch self {
        case .exposure: -5...5
        case .straighten: -20...20
        case .gamutExpansion, .sharpness, .noiseReduction, .grain, .grainSize, .sharpMasking, .colorNoiseReduction, .noiseDetail, .vignetteFeather, .vignetteMidpoint, .defringe, .lensBlur: 0...100
        case .sharpRadius: 0.5...3
        case .perspectiveVertical, .perspectiveHorizontal, .lensDistortion: -50...50
        case .cropScale: 25...100
        case .cropX, .cropY: 0...100
        default: -100...100
        }
    }
    public var defaultValue: Double {
        switch self {
        case .sharpRadius: 1
        case .noiseDetail, .vignetteFeather, .vignetteMidpoint: 50
        case .grainSize: 25
        case .cropScale: 100
        case .cropX, .cropY: 50
        default: 0
        }
    }
    public var step: Double { self == .exposure ? 0.05 : ([Adjustment.straighten, .sharpRadius].contains(self) ? 0.1 : 1) }
}

public enum CropAspect: String, Codable, CaseIterable, Sendable {
    case original = "원본", square = "1:1", portrait = "4:5", threeTwo = "3:2", landscape = "16:9"
    public var ratio: Double? {
        switch self {
        case .original: nil
        case .square: 1
        case .portrait: 0.8
        case .threeTwo: 1.5
        case .landscape: 16.0 / 9
        }
    }
}

public struct ColorBand: Codable, Sendable, Equatable {
    public var hue: Double = 0
    public var saturation: Double = 0
    public var luminance: Double = 0
    public init() {}
}

public struct EditRecipe: Codable, Sendable, Equatable {
    public var rawAdjustments: RAWAdjustments?
    public var values: [String: Double] = [:]
    public var colors: [ColorBand] = Array(repeating: ColorBand(), count: 8)
    public var aspect: CropAspect = .original
    public var quarterTurns = 0
    public var flipHorizontal = false
    public var advanced: AdvancedEdits?
    public var enhancements: AdvancedEdits {
        get { advanced ?? AdvancedEdits() }
        set { advanced = newValue == AdvancedEdits() ? nil : newValue }
    }
    public init() {}

    public subscript(_ adjustment: Adjustment) -> Double {
        get { values[adjustment.rawValue] ?? adjustment.defaultValue }
        set {
            let value = newValue.isFinite ? min(max(newValue, adjustment.range.lowerBound), adjustment.range.upperBound) : adjustment.defaultValue
            if value == adjustment.defaultValue { values.removeValue(forKey: adjustment.rawValue) }
            else { values[adjustment.rawValue] = value }
        }
    }
    public var isValid: Bool {
        (rawAdjustments?.isValid ?? true) && (advanced?.isValid ?? true) && values.allSatisfy { key, value in
            guard let adjustment = Adjustment(rawValue: key) else { return false }
            return value.isFinite && adjustment.range.contains(value)
        } && colors.count == 8 && colors.allSatisfy {
            [$0.hue, $0.saturation, $0.luminance].allSatisfy { $0.isFinite && (-100...100).contains($0) }
        } && (0...3).contains(quarterTurns)
    }
    public var geometryOnly: EditRecipe {
        var result = EditRecipe()
        result.aspect = aspect
        result.quarterTurns = quarterTurns
        result.flipHorizontal = flipHorizontal
        result.enhancements.hdr = enhancements.hdr
        for key in [Adjustment.straighten, .cropScale, .cropX, .cropY, .perspectiveVertical, .perspectiveHorizontal, .lensDistortion] { result[key] = self[key] }
        return result
    }
    public var colorOnly: EditRecipe {
        var result = self
        result.rawAdjustments = nil
        result.aspect = .original
        result.quarterTurns = 0
        result.flipHorizontal = false
        result.enhancements.masks = []; result.enhancements.retouches = []; result[.lensBlur] = 0
        result.enhancements.depth = nil
        result.enhancements.removals = nil
        result.enhancements.hdrExpansion = nil
        for key in [Adjustment.straighten, .cropScale, .cropX, .cropY, .perspectiveVertical, .perspectiveHorizontal, .lensDistortion] { result[key] = key.defaultValue }
        return result
    }
}

public struct EditHistory: Codable, Sendable, Equatable {
    public private(set) var current = EditRecipe()
    public private(set) var undoStack: [EditRecipe] = []
    public private(set) var redoStack: [EditRecipe] = []
    public init() {}
    public mutating func commit(_ recipe: EditRecipe) {
        guard recipe != current, recipe.isValid else { return }
        undoStack.append(current)
        if undoStack.count > 50 { undoStack.removeFirst() }
        current = recipe
        redoStack.removeAll()
    }
    public mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current); current = previous
    }
    public mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current); current = next
    }
    public var isValid: Bool {
        current.isValid && undoStack.count <= 50 && redoStack.count <= 50 &&
        undoStack.allSatisfy(\.isValid) && redoStack.allSatisfy(\.isValid)
    }
}

public struct RAWDevelopment: Codable, Sendable, Equatable {
    public let decoder: String
    public let baselineExposure: Float
    public let boost: Float
    public let boostShadows: Float
    public let shadowBias: Float
    public let temperature: Float
    public let tint: Float
}

public struct EditDocument: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var rendererVersion = 1
    public let sourceSHA256: String
    public var revision = 0
    public var history = EditHistory()
    public var raw: RAWDevelopment?
    public var workingSpace = "extended-linear-sRGB"
    public var tonePolicy = "SDR-base-v1"
}

public struct UserPreset: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public let recipe: EditRecipe
    public init(name: String, recipe: EditRecipe) {
        id = UUID(); self.name = name; self.recipe = recipe.colorOnly
    }
}

public enum ExportFormat: String, Codable, Sendable, CaseIterable {
    case jpeg = "JPEG", heic = "HEIC", png = "PNG", avif = "AVIF", tiff = "TIFF", original = "원본"
    public var typeIdentifier: String {
        switch self {
        case .jpeg: "public.jpeg"
        case .heic: "public.heic"
        case .png: "public.png"
        case .avif: "public.avif"
        case .tiff: "public.tiff"
        case .original: "public.data"
        }
    }
    public var fileExtension: String {
        switch self { case .jpeg: "jpg"; case .heic: "heic"; case .png: "png"; case .avif: "avif"; case .tiff: "tiff"; case .original: "" }
    }
    public var supportsQuality: Bool { self == .jpeg || self == .heic || self == .avif }
    public var supportsHDR: Bool { self == .jpeg || self == .heic }
    public var preservesAlpha: Bool { self == .png || self == .tiff || self == .avif || self == .original }
    public var summary: String {
        switch self {
        case .jpeg: "공유와 호환성에 적합 · 손실 압축 · 투명 영역은 흰색"
        case .heic: "작은 용량의 사진 · 손실 압축 · 일부 서비스에서 호환 확인 필요 · 투명 영역은 흰색"
        case .png: "투명 배경과 그래픽에 적합 · 무손실 압축 · 사진은 용량이 커질 수 있음"
        case .avif: "웹용 고효율 이미지 · 손실 압축 · 투명 배경 지원 · 일부 앱에서 호환 확인 필요"
        case .tiff: "추가 편집용 · 8/16비트 · 투명 배경 지원 · 큰 용량"
        case .original: "보정을 적용하지 않은 원본 · 기존 형식·메타데이터·애니메이션 보존"
        }
    }
}
public enum OutputColorSpace: String, Codable, Sendable, CaseIterable { case sRGB, displayP3 = "Display P3" }
public struct ExportSettings: Sendable, Equatable, Hashable {
    public var format: ExportFormat = .jpeg
    public var colorSpace: OutputColorSpace = .sRGB
    public var quality: Double = 0.92
    public var longEdge: Int? = nil
    public var hdr = false
    public var watermark = ""
    public var png16Bit = false
    public var tiff16Bit = true
    public init() {}
}

public enum EditorFailure: Error, LocalizedError, Sendable {
    case gainModelValidation, hdrExpansionRequiresSDR, invalidDocument, unsupportedRAW, renderFailed, exportFailed, saveFailed, noSubject, versionLimit, selectionAssetsUnavailable, modelUnavailable, removalSelection
    public var errorDescription: String? {
        switch self {
        case .hdrExpansionRequiresSDR: "이 사진은 원본 HDR 또는 RAW 현상을 사용합니다. 밝기 지도 예측은 SDR 사진에서 사용할 수 있습니다."
        case .gainModelValidation: "이 기기에서 HDR 예측 모델의 검증에 실패했습니다. 잘못된 밝기 지도는 저장하지 않았습니다."
        case .removalSelection: "마스크에서 지울 영역을 지정해 주세요. 사진의 60%보다 작은 영역을 선택할 수 있습니다."
        case .modelUnavailable: "앱에 포함된 분석 모델을 불러오지 못했습니다. 앱 설치 상태를 확인해 주세요."
        case .selectionAssetsUnavailable: "탭 선택 모델이 준비되지 않았습니다. 마스크 패널에서 ‘선택 모델 준비’를 누르세요. 사진 분석은 기기 안에서만 실행됩니다."
        case .noSubject: "피사체를 찾지 못했습니다. 브러시 또는 방사형 마스크를 사용해 주세요."
        case .versionLimit: "저장한 버전은 사진당 최대 100개입니다."
        case .invalidDocument: "편집 기록을 읽을 수 없거나 이 버전에서 지원하지 않습니다. 기존 기록은 보존됩니다."
        case .unsupportedRAW: "이 RAW의 디코더를 사용할 수 없습니다. RAW 지원과 기기용 자산을 확인해 주세요."
        case .renderFailed: "사진을 처리하지 못했습니다. 다시 시도해 주세요."
        case .exportFailed: "결과 파일을 만들거나 검증하지 못했습니다. 저장 공간을 확인해 주세요."
        case .saveFailed: "편집 내용을 저장하지 못했습니다. 저장 공간을 확인하고 다시 시도해 주세요."
        }
    }
}


public struct PreparedExport: Sendable {
    public let url: URL
    public let byteCount: Int64
    public let width: Int
    public let height: Int
    public let frameCount: Int
}
