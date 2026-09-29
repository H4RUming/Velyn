import Testing
import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
@testable import VelynEngine

struct OriginalImportTests {
    private func workspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("VelynTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func image(at url: URL, type: UTType = .jpeg, orientation: Int = 1) throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 24, height: 16, bitsPerComponent: 8,
                                bytesPerRow: 96, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test(arguments: Array(1...8))
    func preservesBytesAndAllOrientations(orientation: Int) async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        // Deliberately misleading extension: trust the container, not the filename.
        let source = base.appendingPathComponent("misleading.dng")
        try image(at: source, orientation: orientation)
        let before = try Data(contentsOf: source)
        let service = OriginalImportService(root: base.appendingPathComponent("projects"))
        let asset = try await service.importFile(at: source)
        let stored = base.appendingPathComponent("projects/\(asset.id)/\(asset.relativePath)")
        #expect(try Data(contentsOf: stored) == before)
        #expect(try Data(contentsOf: source) == before)
        #expect(asset.sha256 == SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined())
        #expect(asset.integrityVerified)
        #expect(asset.typeIdentifier == UTType.jpeg.identifier)
        #expect(!asset.isRAW)
        #expect(asset.orientation == orientation)
        #expect(asset.pixelWidth == 24 && asset.pixelHeight == 16)
        #expect(asset.orientedWidth == ((5...8).contains(orientation) ? 16 : 24))
        #expect(asset.orientedHeight == ((5...8).contains(orientation) ? 24 : 16))
        #expect(try await service.verify(asset) == asset)
        let restarted = OriginalImportService(root: base.appendingPathComponent("projects"))
        #expect(try await restarted.recentImports() == [asset])
    }

    @Test func heicPreservesOriginalContainer() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.heic")
        try image(at: source, type: .heic, orientation: 6)
        let service = OriginalImportService(root: base.appendingPathComponent("projects"))
        let asset = try await service.importFile(at: source)
        #expect(asset.typeIdentifier == UTType.heic.identifier)
        #expect(asset.orientation == 6)
        #expect(asset.integrityVerified)
        #expect(try await service.verify(asset) == asset)
    }

    @Test func corruptInputNeverCommits() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("broken.heic")
        try Data("not an image".utf8).write(to: source)
        let root = base.appendingPathComponent("projects")
        let service = OriginalImportService(root: root)
        await #expect(throws: ImportFailure.invalidImage) { try await service.importFile(at: source) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func unsupportedImageNeverCommits() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.tga")
        try image(at: source, type: UTType("com.truevision.tga-image")!)
        let service = OriginalImportService(root: base.appendingPathComponent("projects"))
        await #expect(throws: ImportFailure.unsupportedFormat) { try await service.importFile(at: source) }
        #expect(try await service.recentImports().isEmpty)
    }

    @Test func detectsTamperedStoredOriginal() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.jpg")
        try image(at: source)
        let root = base.appendingPathComponent("projects")
        let service = OriginalImportService(root: root)
        let asset = try await service.importFile(at: source)
        let stored = root.appendingPathComponent("\(asset.id)/\(asset.relativePath)")
        var bytes = try Data(contentsOf: stored)
        bytes[bytes.count - 1] ^= 0xff
        try bytes.write(to: stored)
        await #expect(throws: ImportFailure.integrityMismatch) { try await service.verify(asset) }
    }

    @Test func cancellationCleansStagingAndKeepsPreviousImport() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.jpg")
        try image(at: source)
        let root = base.appendingPathComponent("projects")
        let service = OriginalImportService(root: root)
        let previous = try await service.importFile(at: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        // Add harmless trailing data to keep the copy busy without a large pixel allocation.
        let block = Data(repeating: 0, count: 1_048_576)
        for _ in 0..<128 { try handle.write(contentsOf: block) }
        try handle.close()
        let gate = ImportCancellationGate()
        let cancellable = OriginalImportService(root: root,copyProgress: { copied in
            if copied >= 1_048_576 { gate.cancel() }
        })
        let task = Task { try await cancellable.importFile(at: source) }
        gate.register(task)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await service.recentImports() == [previous])
        #expect(try await service.verify(previous) == previous)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [previous.id.uuidString])
    }

    @Test func staleTransactionRecoveryAndBackupExclusion() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source.jpg")
        try image(at: source)
        let root = base.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".import-interrupted"), withIntermediateDirectories: true)
        let service = OriginalImportService(root: root)
        let asset = try await service.importFile(at: source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == [asset.id.uuidString])
        #expect(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func unreadableFileReturnsPermissionError() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("private.jpg")
        try image(at: source)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path) }
        let service = OriginalImportService(root: base.appendingPathComponent("projects"))
        await #expect(throws: ImportFailure.permissionDenied) { try await service.importFile(at: source) }
        #expect(try await service.recentImports().isEmpty)
    }


    @Test func syntheticDNGPreservesRawBytes() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = Bundle.module.url(forResource: "synthetic", withExtension: "dng", subdirectory: "Fixtures")!
        let service = OriginalImportService(root: base.appendingPathComponent("projects"))
        let asset = try await service.importFile(at: source)
        #expect(asset.isRAW)
        #expect(asset.pixelWidth == 640 && asset.pixelHeight == 480)
        #expect(asset.orientation == 6)
        #expect(!asset.supportedRAWDecoders.isEmpty)
        #expect(asset.integrityVerified)
        #expect(try await service.verify(asset) == asset)
    }

    @Test func browsingPreviewRespectsOrientationAndKeepsOriginal() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("portrait.jpg")
        try image(at: source, orientation: 6)
        let service = OriginalImportService(root: base.appendingPathComponent("projects"))
        let asset = try await service.importFile(at: source)
        let preview = try await service.preview(asset, maxPixelSize: 128)
        #expect(preview.image.width == 16 && preview.image.height == 24)
        #expect(try await service.verify(asset) == asset)
    }

    @Test func rawBrowsingPreviewIsBounded() async throws {
        let base = try workspace()
        defer { try? FileManager.default.removeItem(at: base) }
        let source = Bundle.module.url(forResource: "synthetic", withExtension: "dng", subdirectory: "Fixtures")!
        let service = OriginalImportService(root: base.appendingPathComponent("projects"))
        let asset = try await service.importFile(at: source)
        let preview = try await service.preview(asset, maxPixelSize: 128)
        #expect(max(preview.image.width, preview.image.height) <= 128)
        #expect(preview.image.height > preview.image.width)
        #expect(try await service.verify(asset) == asset)
    }

    @Test func classifiesProviderErrors() {
        #expect(ImportFailure.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)) as? ImportFailure == .permissionDenied)
        #expect(ImportFailure.classify(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)) as? ImportFailure == .insufficientSpace)
        #expect(ImportFailure.classify(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)) is CancellationError)
    }
}


private final class ImportCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var task: Task<SourceAsset,Error>?
    func register(_ task: Task<SourceAsset,Error>) {
        lock.lock(); self.task = task; let cancelled = requested; lock.unlock()
        if cancelled { task.cancel() }
    }
    func cancel() { lock.lock(); requested = true; let task = task; lock.unlock(); task?.cancel() }
}
