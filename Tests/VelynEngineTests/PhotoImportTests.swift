import Testing
import Foundation
import Photos
import UniformTypeIdentifiers
@testable import VelynEngine

struct PhotoImportTests {
    @Test func selectsRAWRegardlessOfPairOrderAndIgnoresEdits() throws {
        typealias Resource = PhotoLibraryImportService.Resource
        let jpeg = Resource(type: .photo, identifier: UTType.jpeg.identifier)
        let raw = Resource(type: .alternatePhoto, identifier: "com.adobe.raw-image")
        let edited = Resource(type: .fullSizePhoto, identifier: UTType.jpeg.identifier)
        let video = Resource(type: .pairedVideo, identifier: UTType.quickTimeMovie.identifier)
        #expect(try PhotoLibraryImportService.originalIndex([edited, jpeg, video, raw]) == 3)
        #expect(try PhotoLibraryImportService.originalIndex([raw, jpeg]) == 0)
        #expect(try PhotoLibraryImportService.originalIndex([edited, jpeg]) == 1)
        #expect(try PhotoLibraryImportService.originalIndex([Resource(type: .photo, identifier: "com.adobe.raw-image"), jpeg]) == 0)
        #expect(throws: ImportFailure.unsupportedFormat) { try PhotoLibraryImportService.originalIndex([edited, video]) }
        for identifier in [UTType.png.identifier, UTType.webP.identifier, UTType.tiff.identifier, UTType.gif.identifier] {
            #expect(try PhotoLibraryImportService.originalIndex([Resource(type: .photo, identifier: identifier)]) == 0)
        }
    }

    @Test func photoErrorsKeepRecoveryInstructions() {
        let cloud = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.networkAccessRequired.rawValue)
        #expect(PhotoLibraryImportService.classify(cloud) as? ImportFailure == .photoNeedsDownload)
        let denied = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.accessUserDenied.rawValue)
        #expect(PhotoLibraryImportService.classify(denied) as? ImportFailure == .photoAccessDenied)
        let cancelled = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.userCancelled.rawValue)
        #expect(PhotoLibraryImportService.classify(cancelled) is CancellationError)
        let space = NSError(domain: PHPhotosErrorDomain, code: PHPhotosError.notEnoughSpace.rawValue)
        #expect(PhotoLibraryImportService.classify(space) as? ImportFailure == .insufficientSpace)
        #expect(ImportFailure.classify(ImportFailure.photoNotAccessible) as? ImportFailure == .photoNotAccessible)
    }

    @Test func streamedBytesRemainExactAfterLateCallbacks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VelynStream-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        let stream = try ImportByteStream(url: url)
        let bytes = Data((0..<1_048_576).map { UInt8($0 % 251) })
        for offset in stride(from: 0, to: bytes.count, by: 32768) {
            stream.append(bytes.subdata(in: offset..<min(offset + 32768, bytes.count)))
        }
        stream.finish()
        stream.append(Data([99]))
        stream.finish(error: ImportFailure.photoUnavailable)
        try await stream.wait() // Completion before waiter registration is valid.
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func cancelledStreamClosesBeforeCleanupAndIgnoresLateData() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VelynStream-\(UUID())")
        defer { try? FileManager.default.removeItem(at: url) }
        let stream = try ImportByteStream(url: url)
        stream.append(Data([1, 2, 3]))
        let waiter = Task { try await stream.wait() }
        stream.finish(error: CancellationError())
        await #expect(throws: CancellationError.self) { try await waiter.value }
        try FileManager.default.removeItem(at: url)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask { stream.append(Data([4, 5])); stream.finish() }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
