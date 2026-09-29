import Foundation

/// Measurements of a bounded preview sample, relative to SDR reference white = 1.
public struct EditDiagnostics: Sendable {
    public let red: [Int]
    public let green: [Int]
    public let blue: [Int]
    public let shadowFraction: Double
    public let aboveSDRFraction: Double
    public let peak: Double
    public let averageLuminance: Double
    public let sampleCount: Int
}
