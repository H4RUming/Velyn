import Foundation
import Photos
import UIKit
import CoreGraphics

struct BrowserPhoto: Identifiable, Sendable { let id: String }
struct BrowserPage: Sendable { let photos: [BrowserPhoto]; let hasMore: Bool }

/// Fetches and decodes browsing thumbnails away from the UI actor. No cloud downloads.
actor PhotoBrowserService {
    func page(offset: Int, count: Int = 180) throws -> BrowserPage {
        try Task.checkCancellation()
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited else { throw ImportFailure.photoAccessDenied }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate",ascending: false)]
        let assets = PHAsset.fetchAssets(with: .image,options: options)
        let end = min(assets.count,offset+count)
        guard offset < end else { return BrowserPage(photos: [],hasMore: false) }
        let photos = (offset..<end).map { BrowserPhoto(id: assets.object(at: $0).localIdentifier) }
        return BrowserPage(photos: photos,hasMore: end < assets.count)
    }
    func accessibleSelection(_ ids: [String]) -> [String] {
        let result = PHAsset.fetchAssets(withLocalIdentifiers: ids,options: nil)
        var visible = Set<String>()
        result.enumerateObjects { asset, _, _ in visible.insert(asset.localIdentifier) }
        return ids.filter { visible.contains($0) }
    }
    func thumbnail(id: String) async throws -> PhotoPreview {
        try Task.checkCancellation()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id],options: nil).firstObject else { throw ImportFailure.photoNotAccessible }
        let request = BrowserImageRequest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                request.start(continuation)
                let options = PHImageRequestOptions()
                options.deliveryMode = .highQualityFormat
                options.resizeMode = .fast
                options.isNetworkAccessAllowed = false
                options.isSynchronous = false
                let token = PHImageManager.default().requestImage(for: asset,targetSize: CGSize(width: 320,height: 320),contentMode: .aspectFill,options: options) { image, info in
                    if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                    if let image = image?.cgImage { request.finish(.success(PhotoPreview(image: image))) }
                    else { request.finish(.failure(ImportFailure.photoUnavailable)) }
                }
                request.register(token)
            }
        } onCancel: { request.cancel() }
    }
}

private final class BrowserImageRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PhotoPreview,Error>?
    private var requestID: PHImageRequestID?
    private var cancelled = false
    private var finished = false
    func start(_ value: CheckedContinuation<PhotoPreview,Error>) {
        lock.lock()
        if cancelled { lock.unlock(); value.resume(throwing: CancellationError()); return }
        continuation = value; lock.unlock()
    }
    func register(_ id: PHImageRequestID) {
        lock.lock(); requestID = id; let cancel = cancelled; lock.unlock()
        if cancel { PHImageManager.default().cancelImageRequest(id) }
    }
    func finish(_ result: Result<PhotoPreview,Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true; let value = continuation; continuation = nil; lock.unlock()
        value?.resume(with: result)
    }
    func cancel() {
        lock.lock(); cancelled = true; let id = requestID; lock.unlock()
        finish(.failure(CancellationError()))
        if let id { PHImageManager.default().cancelImageRequest(id) }
    }
}
