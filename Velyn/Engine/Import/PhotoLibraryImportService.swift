import Foundation
import Photos
import UniformTypeIdentifiers

actor PhotoLibraryImportService {
    func importPhoto(identifier: String, into importer: any AssetImporting) async throws -> SourceAsset {
        try Task.checkCancellation()
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited else { throw ImportFailure.photoAccessDenied }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            throw ImportFailure.photoNotAccessible
        }
        let resources = PHAssetResource.assetResources(for: asset)
        let index = try Self.originalIndex(resources.map {
            Resource(type: $0.type, identifier: $0.uniformTypeIdentifier)
        })
        let resource = resources[index]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VelynPhotoImport-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name: String
        if #available(iOS 27, macOS 27, *) { name = resource.filename ?? "original" }
        else { name = resource.originalFilename }
        let safeName = (name as NSString).lastPathComponent
        let url = directory.appendingPathComponent(safeName.isEmpty || safeName == "." || safeName == ".." ? "original" : safeName)
        let stream = try ImportByteStream(url: url)
        let request = ResourceRequest()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        do {
            try await withTaskCancellationHandler {
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    stream.append(data)
                } completionHandler: { error in
                    stream.finish(error: error.map(Self.classify))
                }
                request.register(id)
                try await stream.wait()
                try Task.checkCancellation()
            } onCancel: {
                // Closing/synchronizing a file must not block a UI cancellation callback.
                Task.detached {
                    request.cancel()
                    stream.finish(error: CancellationError())
                }
            }
            return try await importer.importFile(at: url)
        } catch {
            request.cancel()
            throw ImportFailure.classify(error)
        }
    }

    struct Resource: Sendable {
        let type: PHAssetResourceType
        let identifier: String
    }

    /// Prefer RAW in RAW+JPEG pairs; exclude Photos edits, previews and Live Photo video.
    static func originalIndex(_ resources: [Resource]) throws -> Int {
        let originals = resources.indices.filter { resources[$0].type == .photo || resources[$0].type == .alternatePhoto }
        if let raw = originals.first(where: { UTType(resources[$0].identifier)?.conforms(to: .rawImage) == true }) { return raw }
        if let primary = originals.first(where: { resources[$0].type == .photo }) {
            guard ImageFormats.accepts(resources[primary].identifier) else {
                throw ImportFailure.unsupportedFormat
            }
            return primary
        }
        throw ImportFailure.unsupportedFormat
    }

    static func classify(_ error: Error) -> Error {
        let ns = error as NSError
        guard ns.domain == PHPhotosErrorDomain else { return ImportFailure.classify(error) }
        switch ns.code {
        case PHPhotosError.networkAccessRequired.rawValue: return ImportFailure.photoNeedsDownload
        case PHPhotosError.userCancelled.rawValue: return CancellationError()
        case PHPhotosError.accessUserDenied.rawValue, PHPhotosError.accessRestricted.rawValue: return ImportFailure.photoAccessDenied
        case PHPhotosError.notEnoughSpace.rawValue: return ImportFailure.insufficientSpace
        default: return ImportFailure.photoUnavailable
        }
    }
}

/// Handles cancellation racing with request ID registration without calling PhotoKit under a lock.
private final class ResourceRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHAssetResourceDataRequestID?
    private var cancelled = false

    func register(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        self.id = id
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = id
        lock.unlock()
        if let current { PHAssetResourceManager.default().cancelDataRequest(current) }
    }
}
