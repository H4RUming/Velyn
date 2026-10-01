import Foundation

public struct PhotoPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
}
public enum CurveChannel: String, Codable, Sendable, CaseIterable { case rgb = "RGB", red = "R", green = "G", blue = "B" }
public struct PointCurve: Codable, Sendable, Equatable {
    public var points: [PhotoPoint] = [.init(0, 0), .init(1, 1)]
    public init() {}
    public var isValid: Bool {
        (2...16).contains(points.count) && points.allSatisfy(\.isValid) && points.first?.x == 0 && points.last?.x == 1 &&
        zip(points, points.dropFirst()).allSatisfy { $0.x < $1.x }
    }
    /// Piecewise linear interpolation matches the editor graph exactly, with no overshoot.
    public func evaluate(_ x: Double) -> Double {
        guard isValid else { return x }
        for i in 1..<points.count where x <= points[i].x {
            let a = points[i-1], b = points[i]
            return a.y + (b.y - a.y) * max(0, (x - a.x) / (b.x - a.x))
        }
        return points.last!.y
    }
}
public struct GradeTone: Codable, Sendable, Equatable {
    public var hue = 0.0
    public var saturation = 0.0
    public var luminance = 0.0
    public init() {}
    public var isValid: Bool { hue.isFinite && (0...360).contains(hue) && saturation.isFinite && (0...100).contains(saturation) && luminance.isFinite && (-100...100).contains(luminance) }
}
public enum PhotoProfile: String, Codable, Sendable, CaseIterable { case neutral = "기본", portrait = "인물", landscape = "풍경", monochrome = "흑백" }
public enum MaskKind: String, Codable, Sendable, CaseIterable {
    case object = "탭 선택", brush = "브러시", linear = "선형", radial = "방사형", luminance = "밝기 범위", color = "색상 범위", subject = "피사체", background = "배경"
}
public struct LocalMask: Codable, Sendable, Equatable, Identifiable {
    public var strokes: [MaskStroke]?
    public var id = UUID()
    public var name = "마스크"
    public var kind: MaskKind = .radial
    public var enabled = true
    public var inverted = false
    public var points: [PhotoPoint] = [.init(0.3, 0.3), .init(0.7, 0.7)]
    public var radius = 0.05
    public var feather = 0.5
    public var opacity = 1.0
    public var lower = 0.25
    public var upper = 0.75
    public var hue = 0.0
    public var exposure = 0.0
    public var contrast = 0.0
    public var saturation = 0.0
    public var warmth = 0.0
    public var texture = 0.0
    public var resourceID: UUID?
    public var excludedPoints: [PhotoPoint]?
    public init(kind: MaskKind) { self.kind = kind; name = kind.rawValue }
    public var isValid: Bool {
        (strokes?.count ?? 0) <= 200 && (strokes?.reduce(0) { $0 + $1.points.count } ?? 0) + points.count <= 20_000 && (strokes?.allSatisfy(\.isValid) ?? true) && !name.isEmpty && name.count <= 80 && points.allSatisfy(\.isValid) &&
        [radius, feather, opacity, lower, upper, hue, exposure, contrast, saturation, warmth, texture].allSatisfy(\.isFinite) &&
        (0.005...0.5).contains(radius) && (0...1).contains(feather) && (0...1).contains(opacity) &&
        (0...1).contains(lower) && (lower...1).contains(upper) && (0...360).contains(hue) && (-5...5).contains(exposure) &&
        [contrast, saturation, warmth, texture].allSatisfy { (-100...100).contains($0) } &&
        (excludedPoints?.allSatisfy(\.isValid) ?? true) && (kind != .subject && kind != .background && kind != .object || resourceID != nil)
    }
}
public struct MaskStroke: Codable, Sendable, Equatable {
    public var points: [PhotoPoint]
    public var radius: Double
    public var feather: Double
    public var erasing: Bool
    public var isValid: Bool { points.allSatisfy(\.isValid) && radius.isFinite && feather.isFinite && (0.0005...0.5).contains(radius) && (0...1).contains(feather) }
}
public enum RetouchKind: String, Codable, Sendable, CaseIterable { case clone = "복제", heal = "힐링" }
public struct RetouchPatch: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var kind: RetouchKind = .heal
    public var source = PhotoPoint(0.3, 0.5)
    public var target = PhotoPoint(0.5, 0.5)
    public var radius = 0.03
    public var feather = 0.5
    public var opacity = 1.0
    public init() {}
    public var isValid: Bool { source.isValid && target.isValid && radius.isFinite && (0.005...0.25).contains(radius) && feather.isFinite && (0...1).contains(feather) && opacity.isFinite && (0...1).contains(opacity) }
}
public enum SourceDynamicRange: String, Sendable { case sdr, hdr, raw }

/// Stored samples encode log2 gain / log2(5). UUID resources belong to this photo only.
public struct HDRExpansion: Codable, Sendable, Equatable {
    public var predictionFingerprint: String?
    /// Nil retains the pre-1.1 tone curve and bilinear map sampling.
    public var protectionBlend: Double?
    public var edgeAwareUpsampling: Bool?
    public var protectMidtones: Bool?
    public var resourceID: UUID
    public var strength = 0.75
    public var maximumBoostEV = 2.0
    public init(resourceID: UUID) { self.resourceID = resourceID; self.protectMidtones = true }
    public var isValid: Bool {
        strength.isFinite && (0...1).contains(strength) && maximumBoostEV.isFinite && (0...log2(5)).contains(maximumBoostEV) &&
        (protectionBlend.map { $0.isFinite && (0...1).contains($0) } ?? true)
    }
}

public struct AdvancedEdits: Codable, Sendable, Equatable {
    public var hdrExpansion: HDRExpansion?
    public var depth: DepthEffect?
    public var removals: [RemovalPatch]?
    public var curves: [String: PointCurve] = [:]
    public var grading = [GradeTone(), GradeTone(), GradeTone()]
    public var profile: PhotoProfile = .neutral
    public var masks: [LocalMask] = []
    public var retouches: [RetouchPatch] = []
    public var hdr = false
    public init() {}
    public var isValid: Bool {
        (hdrExpansion?.isValid ?? true) && (depth?.isValid ?? true) && (removals?.count ?? 0) <= 30 && (removals?.allSatisfy(\.isValid) ?? true) && curves.allSatisfy { CurveChannel(rawValue: $0.key) != nil && $0.value.isValid } &&
        grading.count == 3 && grading.allSatisfy(\.isValid) && masks.count <= 32 && masks.allSatisfy(\.isValid) &&
        Set(masks.map(\.id)).count == masks.count && retouches.count <= 200 && retouches.allSatisfy(\.isValid)
    }
}
public struct RemovalPatch: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var imageID: UUID
    public var maskID: UUID
    public var topLeft: PhotoPoint
    public var bottomRight: PhotoPoint
    public var isValid: Bool { topLeft.isValid && bottomRight.isValid && topLeft.x < bottomRight.x && topLeft.y < bottomRight.y }
}
public struct DepthEffect: Codable, Sendable, Equatable {
    public var resourceID: UUID
    public var focus = 0.75
    public var range = 0.15
    public var amount = 30.0
    public init(resourceID: UUID) { self.resourceID = resourceID }
    public var isValid: Bool { focus.isFinite && range.isFinite && amount.isFinite && (0...1).contains(focus) && (0.01...1).contains(range) && (0...100).contains(amount) }
}
public struct EditVersion: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public var createdAt = Date()
    public var recipe: EditRecipe
    public init(name: String, recipe: EditRecipe) { self.name = name; self.recipe = recipe }
}
public struct ImageAnalysis: Sendable {
    public var histogram: [Int]
    public var shadows: Double
    public var highlights: Double
    public var suggestedExposure: Double
    public var suggestedWarmth: Double
    public var suggestedTint: Double
}
