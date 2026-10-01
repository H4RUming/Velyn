import Foundation
import CryptoKit

extension EditRecipe {
    /// The exact edit state used for prediction; display gain and geometry are excluded.
    public var gainPredictionBase: EditRecipe {
        var base = self
        base.enhancements.hdr = false
        base.enhancements.hdrExpansion = nil
        base.aspect = .original; base.quarterTurns = 0; base.flipHorizontal = false
        for key in [Adjustment.straighten,.cropScale,.cropX,.cropY,.perspectiveVertical,.perspectiveHorizontal,.lensDistortion,.vignette,.vignetteMidpoint,.vignetteFeather] { base[key] = key.defaultValue }
        return base
    }
    public var gainPredictionFingerprint: String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(gainPredictionBase) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined()
    }
}

/// Keep recipe serialization and hashing off the UI actor. Gain-only changes reuse the result.
public actor GainPredictionContext {
    public static let shared = GainPredictionContext()
    private var previousBase: EditRecipe?
    private var previousFingerprint: String?

    public func matches(_ recipe: EditRecipe) throws -> Bool {
        try Task.checkCancellation()
        guard let expected = recipe.enhancements.hdrExpansion?.predictionFingerprint else { return false }
        let base = recipe.gainPredictionBase
        if base != previousBase {
            previousFingerprint = base.gainPredictionFingerprint
            previousBase = base
        }
        try Task.checkCancellation()
        return expected == previousFingerprint
    }
}
