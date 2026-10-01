import Foundation
import CryptoKit
import ImageIO

public protocol AssetImporting: Sendable {
    func importFile(at url: URL) async throws -> SourceAsset
    func recentImports() async throws -> [SourceAsset]
    func verify(_ asset: SourceAsset) async throws -> SourceAsset
    func preview(_ asset: SourceAsset, maxPixelSize: Int) async throws -> PhotoPreview
}

/// Serial disk work runs on this actor, never on the UI actor.
public actor OriginalImportService: AssetImporting {
    private let root: URL
    private let files = FileManager.default
    private let chunkSize = 1_048_576
    private let copyProgress: @Sendable (Int64) -> Void
    private let previews = NSCache<NSString, CGImage>()

    public init(root: URL, copyProgress: @escaping @Sendable (Int64) -> Void = { _ in }) {
        self.root = root
        self.copyProgress = copyProgress
        previews.totalCostLimit = 32 * 1_024 * 1_024
        previews.countLimit = 60
    }

    /// Browsing proxy only, never used for export or as a replacement original.
    public func preview(_ asset: SourceAsset, maxPixelSize: Int) async throws -> PhotoPreview {
        try Task.checkCancellation()
        guard asset.relativePath == "original/source", asset.schemaVersion == 1 else {
            throw ImportFailure.invalidProject
        }
        let size = min(max(maxPixelSize, 64), 2048)
        let editURL = root.appendingPathComponent(asset.id.uuidString).appendingPathComponent("edits.json")
        let edits: EditDocument? = files.fileExists(atPath: editURL.path)
            ? try JSONDecoder().decode(EditDocument.self, from: Data(contentsOf: editURL)) : nil
        let key = "\(asset.id)-\(asset.sha256)-\(size)-\(edits?.revision ?? -1)" as NSString
        if let image = previews.object(forKey: key) { return PhotoPreview(image: image) }
        if let edits {
            let result = try await EditingService(root: root, asset: asset).render(edits, recipe: edits.history.current, maxPixelSize: size)
            try Task.checkCancellation()
            previews.setObject(result.image, forKey: key, cost: result.image.bytesPerRow * result.image.height)
            return result
        }
        let url = root.appendingPathComponent(asset.id.uuidString).appendingPathComponent(asset.relativePath)
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: size,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw ImportFailure.invalidImage }
        try Task.checkCancellation()
        previews.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return PhotoPreview(image: image)
    }

    public static func applicationRoot() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--library-smoke-test") {
            return support.appendingPathComponent("Velyn/LibrarySmoke",isDirectory: true)
        }
        if ProcessInfo.processInfo.arguments.contains("--editor-smoke-test") {
            return support.appendingPathComponent("Velyn/EditorSmoke", isDirectory: true)
        }
        #endif
        return support.appendingPathComponent("Velyn/Projects", isDirectory: true)
    }

    public static func applicationStore() throws -> OriginalImportService {
        OriginalImportService(root: try applicationRoot())
    }

    public func importFile(at url: URL) async throws -> SourceAsset {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            try Task.checkCancellation()
            try prepareRoot()
            let id = UUID()
            let staging = root.appendingPathComponent(".import-\(id.uuidString)", isDirectory: true)
            let destination = root.appendingPathComponent(id.uuidString, isDirectory: true)
            try files.createDirectory(at: staging.appendingPathComponent("original"), withIntermediateDirectories: true)
            defer { try? files.removeItem(at: staging) }
            // Fixed internal filename: neither user names nor provider paths become package paths.
            let relativePath = "original/source"
            let copied = staging.appendingPathComponent(relativePath)
            var coordinationError: NSError?
            var result: Result<(String, Int64), Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
                result = Result { try self.copyAndHash(from: readableURL, to: copied) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw ImportFailure.sourceUnavailable }
            let (sourceHash, count) = try result.get()
            try Task.checkCancellation()
            let destinationHash = try hash(copied)
            guard destinationHash == sourceHash else { throw ImportFailure.integrityMismatch }
            let metadata = try ImageMetadataReader().read(copied)
            let asset = SourceAsset(
                id: id, schemaVersion: 1, importedAt: Date(), originalFilename: url.lastPathComponent,
                relativePath: relativePath, sha256: destinationHash, sourceSHA256: sourceHash,
                byteCount: count, typeIdentifier: metadata.typeIdentifier,
                pixelWidth: metadata.width, pixelHeight: metadata.height, orientation: metadata.orientation,
                colorProfile: metadata.colorProfile, isRAW: metadata.isRAW, supportedRAWDecoders: metadata.decoders,
                frameCount: metadata.frameCount, hasAlpha: metadata.hasAlpha
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(asset).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            try Task.checkCancellation()
            // Commit point: an atomic directory rename publishes original + manifest together.
            try files.moveItem(at: staging, to: destination)
            // If cancellation raced the rename, remove only this unacknowledged new package.
            if Task.isCancelled {
                try? files.removeItem(at: destination)
                throw CancellationError()
            }
            return asset
        } catch { throw ImportFailure.classify(error) }
    }

    public func recentImports() throws -> [SourceAsset] {
        guard files.fileExists(atPath: root.path) else { return [] }
        let urls = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        return urls.compactMap { url in
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
                  let asset = try? JSONDecoder().decode(SourceAsset.self, from: data),
                  asset.schemaVersion == 1, asset.id.uuidString == url.lastPathComponent,
                  asset.relativePath == "original/source" else { return nil }
            return asset
        }.sorted { $0.importedAt > $1.importedAt }
    }

    public func verify(_ asset: SourceAsset) throws -> SourceAsset {
        guard asset.schemaVersion == 1, asset.relativePath == "original/source", asset.integrityVerified else {
            throw ImportFailure.invalidProject
        }
        let original = root.appendingPathComponent(asset.id.uuidString).appendingPathComponent(asset.relativePath)
        let values = try original.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey])
        guard values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == asset.byteCount,
              try hash(original) == asset.sha256 else { throw ImportFailure.integrityMismatch }
        return asset
    }

    private func prepareRoot() throws {
        try files.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        // A single service owns this store. Hidden staging directories are never committed work.
        for entry in try files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        where entry.lastPathComponent.hasPrefix(".import-") {
            try files.removeItem(at: entry)
        }
    }

    private func copyAndHash(from source: URL, to destination: URL) throws -> (String, Int64) {
        var freshSource = source
        freshSource.removeAllCachedResourceValues()
        let values = try freshSource.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw ImportFailure.sourceUnavailable }
        guard files.createFile(atPath: destination.path, contents: nil) else { throw ImportFailure.storageFailure }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var digest = SHA256()
        var count: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else { break }
            try output.write(contentsOf: data)
            digest.update(data: data)
            count += Int64(data.count)
            copyProgress(count)
        }
        guard count > 0, count == Int64(values.fileSize ?? -1) else { throw ImportFailure.integrityMismatch }
        try output.synchronize()
        return (hex(digest.finalize()), count)
    }

    private func hash(_ url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var digest = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: chunkSize), !data.isEmpty else { break }
            digest.update(data: data)
        }
        return hex(digest.finalize())
    }

    private func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
