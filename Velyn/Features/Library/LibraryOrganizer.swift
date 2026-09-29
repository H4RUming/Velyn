import Foundation
import Observation

@MainActor @Observable
final class LibraryOrganizer {
    var catalog = LibraryCatalog()
    var selectedIDs = Set<UUID>()
    var selecting = false
    var minimumRating = 0
    var onlyPicks = false
    var album: UUID?
    var showTrash = false
    var copiedEdits: EditRecipe?
    var sharing: ShareableFiles?
    var isWorking = false
    var status: String?
    var error: String?
    var revision = 0
    private let service: LibraryService?
    private var task: Task<Void,Never>?
    init() { service = (try? OriginalImportService.applicationRoot()).map { LibraryService(root: $0) } }
    func load() async {
        do { if let service { catalog = try await service.load() } }
        catch { self.error = L10n.tr("라이브러리 분류 정보를 읽지 못했습니다. 기존 파일은 보존됩니다.") }
    }
    func matches(_ asset: SourceAsset,query: String) -> Bool {
        let entry = catalog[asset.id]
        return (entry.trashedAt != nil) == showTrash && entry.rating >= minimumRating && (!onlyPicks || entry.flag == .pick) &&
            (album == nil || entry.albumIDs.contains(album!)) && (query.isEmpty || asset.originalFilename.localizedCaseInsensitiveContains(query) || entry.keywords.contains { $0.localizedCaseInsensitiveContains(query) })
    }
    func toggle(_ id: UUID) { if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) } }
    func update(rating: Int? = nil,flag: PhotoFlag? = nil,album: UUID? = nil,trash: Bool? = nil) async {
        guard let service, !isWorking else { return }
        do { catalog = try await service.update(ids: Array(selectedIDs),rating: rating,flag: flag,album: album,trash: trash); if trash != nil { selectedIDs = []; selecting = false } }
        catch { self.error = error.localizedDescription }
    }
    func createAlbum(_ name: String) async {
        guard let service else { return }
        do { catalog = try await service.createAlbum(name) } catch { self.error = error.localizedDescription }
    }
    func removeAlbum(_ id: UUID) async {
        guard let service else { return }
        do { catalog = try await service.removeAlbum(id); if album == id { album = nil } } catch { self.error = error.localizedDescription }
    }
    func copy(_ asset: SourceAsset) async {
        guard let service else { return }
        do { copiedEdits = try await service.copyEdits(from: asset); status = L10n.tr("색·톤 보정을 복사했습니다") } catch { self.error = error.localizedDescription }
    }
    enum BatchAction { case paste, export, classify }
    func run(_ action: BatchAction,assets: [SourceAsset],settings: ExportSettings = ExportSettings()) {
        guard let service, !isWorking else { return }
        let chosen = assets.filter { selectedIDs.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let copied = copiedEdits
        if action == .paste && copied == nil { return }
        isWorking = true
        task = Task {
            defer { isWorking = false; task = nil; revision += 1 }
            var done = 0, failures: [String] = [], urls: [URL] = []
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VelynBatch-\(UUID())")
            for asset in chosen {
                if Task.isCancelled { break }
                status = L10n.format("%ld / %ld 처리 중",done + failures.count + 1,chosen.count)
                do {
                    switch action {
                    case .paste: try await service.pasteEdits(copied!,to: asset)
                    case .export: urls.append(try await service.export(asset,settings: settings,directory: directory))
                    case .classify: catalog = try await service.classify(asset)
                    }
                    done += 1
                } catch is CancellationError { break }
                catch { failures.append("\(asset.originalFilename): \(error.localizedDescription)") }
            }
            status = L10n.format("%ld장 완료",done) + (Task.isCancelled ? L10n.tr(" · 나머지 작업 취소") : "")
            if !failures.isEmpty { error = L10n.format("%ld장 완료, %ld장 실패\n",done,failures.count) + failures.prefix(5).joined(separator: "\n") }
            if !urls.isEmpty { sharing = ShareableFiles(urls: urls) }
        }
    }
    func cancel() { task?.cancel() }
}
