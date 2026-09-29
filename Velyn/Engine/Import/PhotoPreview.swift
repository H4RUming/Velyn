import Foundation
import ImageIO

/// Immutable decoded image crossing from the import actor to the presentation layer.
public struct PhotoPreview: @unchecked Sendable {
    public let image: CGImage
}
