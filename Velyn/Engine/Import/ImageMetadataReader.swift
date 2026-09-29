import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage

struct ImageMetadata {
    let typeIdentifier: String
    let width: Int
    let height: Int
    let orientation: Int
    let colorProfile: String?
    let isRAW: Bool
    let decoders: [String]
    let frameCount: Int
    let hasAlpha: Bool
}

struct ImageMetadataReader {
    func read(_ url: URL) throws -> ImageMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let typeName = CGImageSourceGetType(source) as String?,
              let type = UTType(typeName) else { throw ImportFailure.invalidImage }
        let raw = type.conforms(to: .rawImage)
        guard ImageFormats.accepts(typeName) else {
            throw ImportFailure.unsupportedFormat
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard CGImageSourceGetCount(source) > index,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0 else { throw ImportFailure.invalidImage }
        let orientation = properties[kCGImagePropertyOrientation as String] as? Int ?? 1
        guard (1...8).contains(orientation) else { throw ImportFailure.invalidImage }
        // A RAW container can expose a preview as its primary ImageIO image.
        // Query native RAW dimensions when the installed decoder supports the file.
        let filter = raw ? CIRAWFilter(imageURL: url) : nil
        if raw && filter == nil { throw ImportFailure.invalidImage }
        let nativeSize = filter?.nativeSize
        if let nativeSize {
            guard nativeSize.width.isFinite, nativeSize.height.isFinite,
                  nativeSize.width > 0, nativeSize.height > 0 else { throw ImportFailure.invalidImage }
        }
        return ImageMetadata(
            typeIdentifier: typeName,
            width: nativeSize.map { Int($0.width) } ?? width,
            height: nativeSize.map { Int($0.height) } ?? height,
            orientation: orientation,
            colorProfile: properties[kCGImagePropertyProfileName as String] as? String,
            isRAW: raw,
            decoders: filter?.supportedDecoderVersions.map(\.rawValue) ?? [],
            frameCount: raw ? 1 : CGImageSourceGetCount(source),
            hasAlpha: properties[kCGImagePropertyHasAlpha as String] as? Bool ?? false
        )
    }
}
