import Foundation
import Observation

@MainActor @Observable
final class ImportStore {
    private(set) var selected: SourceAsset?
    private(set) var recent: [SourceAsset] = []
    private(set) var isWorking = false
    private(set) var status: String?
    var errorMessage: String?
    private let service: (any AssetImporting)?
    private var operation: Task<Void, Never>?
    private var requestID = UUID()

    init() {
        do { service = try OriginalImportService.applicationStore() }
        catch { service = nil; errorMessage = ImportFailure.storageFailure.localizedDescription }
    }

    func loadRecent() async {
        guard let service else { return }
        do { recent = try await service.recentImports() }
        catch { errorMessage = ImportFailure.classify(error).localizedDescription }
    }

    func importFile(_ url: URL) {
        start(message: "원본을 복사하고 검증하는 중입니다") { service in
            try await service.importFile(at: url)
        }
    }

    func importCapture(_ url: URL) {
        start(message: "촬영 원본을 보관하는 중입니다") { service in
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return try await service.importFile(at: url)
        }
    }

    func importPhoto(_ identifier: String) {
        start(message: "사진 보관함에서 원본을 가져오는 중입니다") { service in
            try await PhotoLibraryImportService().importPhoto(identifier: identifier, into: service)
        }
    }

    func importFiles(_ urls: [URL]) { importMany(urls.map { .file($0) }) }
    func importPhotos(_ identifiers: [String]) { importMany(identifiers.map { .photo($0) }) }
    private enum ImportSource: Sendable { case file(URL), photo(String) }
    private func importMany(_ sources: [ImportSource]) {
        guard !isWorking, let service, !sources.isEmpty else { return }
        isWorking = true; errorMessage = nil
        operation = Task {
            defer { isWorking = false; operation = nil }
            var imported: [SourceAsset] = [], failures: [String] = []
            for (index,source) in sources.enumerated() {
                if Task.isCancelled { break }
                status = "\(index+1) / \(sources.count) 원본 가져오는 중"
                do {
                    switch source {
                    case .file(let url): imported.append(try await service.importFile(at: url))
                    case .photo(let id): imported.append(try await PhotoLibraryImportService().importPhoto(identifier: id,into: service))
                    }
                } catch is CancellationError { break }
                catch { failures.append(ImportFailure.classify(error).localizedDescription) }
            }
            await loadRecent()
            if sources.count == 1, let first = imported.first { selected = first }
            status = "\(imported.count)장 가져옴" + (Task.isCancelled ? " · 나머지 취소" : "")
            if !failures.isEmpty { errorMessage = "\(imported.count)장 가져옴 · \(failures.count)장 실패\n" + failures.prefix(3).joined(separator: "\n") }
        }
    }

    func open(_ asset: SourceAsset) {
        start(message: "저장한 원본을 검증하는 중입니다") { service in
            try await service.verify(asset)
        }
    }

    func dismissSelection() { selected = nil }

    func preview(_ asset: SourceAsset, size: Int) async throws -> PhotoPreview {
        guard let service else { throw ImportFailure.storageFailure }
        return try await service.preview(asset, maxPixelSize: size)
    }

    func cancel() {
        operation?.cancel()
        // Keep the operation active until cleanup finishes; a second import cannot race it.
        status = "가져오기를 취소하는 중입니다"
    }

    func pickerFailed(_ error: Error) {
        let failure = ImportFailure.classify(error)
        guard !(failure is CancellationError) else { return }
        errorMessage = failure.localizedDescription
    }

    private func start(message: String, action: @escaping @Sendable (any AssetImporting) async throws -> SourceAsset) {
        guard !isWorking, let service else { return }
        let id = UUID()
        requestID = id
        isWorking = true
        status = message
        errorMessage = nil
        operation = Task {
            defer { if requestID == id { isWorking = false; operation = nil } }
            do {
                let asset = try await action(service)
                guard requestID == id else { return }
                // The service defines the commit point; do not discard an acknowledged commit.
                selected = asset
                status = "원본 검증을 완료했습니다"
                await loadRecent()
            } catch is CancellationError {
                if requestID == id { status = "가져오기를 취소했습니다" }
            } catch {
                if requestID == id {
                    status = nil
                    errorMessage = ImportFailure.classify(error).localizedDescription
                }
            }
        }
    }
}
