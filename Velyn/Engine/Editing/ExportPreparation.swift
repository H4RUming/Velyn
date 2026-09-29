import Foundation
import ImageIO

extension EditingService {
    /// The size shown in the UI is measured from this file, which is reused for saving.
    public func prepareExport(_ document: EditDocument, settings: ExportSettings) throws -> PreparedExport {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VelynExportPreviews")
        let url = try export(document, settings: settings, directory: directory)
        do {
            try Task.checkCancellation()
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
            let count = source.map(CGImageSourceGetCount) ?? 1
            let info = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0,CGImageSourceGetPrimaryImageIndex($0),nil) as? [String: Any] }
            return PreparedExport(url: url, byteCount: Int64(size),
                width: settings.format == .original ? asset.orientedWidth : (info?[kCGImagePropertyPixelWidth as String] as? Int ?? 0),
                height: settings.format == .original ? asset.orientedHeight : (info?[kCGImagePropertyPixelHeight as String] as? Int ?? 0), frameCount: count)
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    public func copyPreparedExport(_ prepared: PreparedExport) throws -> URL {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VelynExports")
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Velyn-\(UUID()).\(prepared.url.pathExtension)")
        do {
            try FileManager.default.copyItem(at: prepared.url,to: url)
            try Task.checkCancellation()
            return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    public func discardExport(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}
