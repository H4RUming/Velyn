import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keep file selection, PhotoKit resource selection and validation in agreement.
public enum ImageFormats {
    public static let rasterIdentifiers = [
        "public.jpeg", "public.heic", "public.heif", "public.heics", "public.png",
        "org.webmproject.webp", "public.tiff", "com.compuserve.gif", "com.microsoft.bmp",
        "public.avif", "public.avis", "public.jpeg-xl", "public.jpeg-2000"
    ]
    public static var importTypes: [UTType] { [.rawImage] + rasterIdentifiers.compactMap(UTType.init) }
    public static func accepts(_ identifier: String) -> Bool {
        guard let type = UTType(identifier) else { return false }
        return type.conforms(to: .rawImage) || rasterIdentifiers.contains { id in
            id == identifier || UTType(id).map { type.conforms(to: $0) } == true
        }
    }
    /// Deliberately fixed: three common encodings plus an exact original copy.
    public static let exportFormats: [ExportFormat] = [.jpeg, .png, .heic, .original]
    public static var encodableExportFormats: [ExportFormat] {
        let encoders = CGImageDestinationCopyTypeIdentifiers() as! [String]
        return ExportFormat.allCases.filter { $0 == .original || encoders.contains($0.typeIdentifier) }
    }
}
