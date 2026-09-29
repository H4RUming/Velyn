import Foundation

/// Uncommitted brush selection; it never becomes a color-adjustment mask or a saved edit.
public struct RemovalSelection: Equatable, Sendable {
    public private(set) var strokes: [MaskStroke] = []
    public init() {}
    public var hasPaint: Bool { strokes.contains { !$0.erasing } }
    public var pointCount: Int { strokes.reduce(0) { $0+$1.points.count } }
    @discardableResult public mutating func append(_ stroke: MaskStroke) -> Bool {
        guard stroke.isValid,!stroke.points.isEmpty,strokes.count < 100,pointCount+stroke.points.count <= 10_000 else { return false }
        strokes.append(stroke); return true
    }
    public mutating func undo() { if !strokes.isEmpty { strokes.removeLast() } }
    public mutating func clear() { strokes = [] }
    public var mask: LocalMask {
        var value = LocalMask(kind: .brush)
        value.points = []; value.strokes = strokes; value.feather = 0
        return value
    }
}
