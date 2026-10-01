#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Opt-in binding/service checks with generated images in an isolated simulator store.
actor LibrarySmokeFixture {
    static let shared = LibrarySmokeFixture()
    func prepare() async throws {
        let importer = try OriginalImportService.applicationStore()
        let existing = try await importer.recentImports()
        if existing.count < 4 {
            let fixture = try await EditorSmokeFixture.shared.create()
            for _ in existing.count..<4 { _ = try await importer.importFile(at: fixture) }
        }
    }
    func finish(_ checks: [String: Bool],assets: [SourceAsset],error: String?) async throws {
        let importer = try OriginalImportService.applicationStore()
        for asset in assets { _ = try await importer.verify(asset) }
        var report: [String: Any] = checks
        report["originalsVerified"] = true
        report["error"] = error ?? ""
        report["environment"] = "iOS Simulator; generated test chart; programmatic view-model actions"
        let data = try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys])
        try data.write(to: OriginalImportService.applicationRoot().appendingPathComponent("library-smoke-report.json"),options: .atomic)
    }
    @MainActor static func exercise(store: ImportStore,organizer: LibraryOrganizer) async {
        do {
            try await shared.prepare()
            await store.loadRecent(); await organizer.load()
            let ids = Set(store.recent.map(\.id))
            guard let first = store.recent.first else { return }
            await organizer.update(ids: ids,rating: 0,flag: PhotoFlag.none,trash: false)
            organizer.resetFilters()
            organizer.selecting = true; organizer.selectedIDs = ids
            organizer.reconcileSelection(visibleIDs: [first.id])
            var checks = ["hiddenPhotosExcluded": organizer.selectedIDs == [first.id]]
            await organizer.update(trash: true)
            checks["selectionEndsAfterDelete"] = !organizer.selecting && organizer.selectedIDs.isEmpty
            checks["onlyChosenPhotoTrashed"] = organizer.catalog[first.id].trashedAt != nil && ids.subtracting([first.id]).allSatisfy { organizer.catalog[$0].trashedAt == nil }
            checks["trashHiddenFromLibrary"] = !organizer.matches(first,query: "")
            organizer.showTrash = true
            checks["trashVisibleInTrash"] = organizer.matches(first,query: "")
            await organizer.undoTrash()
            checks["undoRestoresPhoto"] = organizer.catalog[first.id].trashedAt == nil && organizer.lastTrashedIDs.isEmpty
            organizer.minimumRating = 5; organizer.onlyPicks = true; organizer.album = UUID()
            organizer.resetFilters()
            checks["resetClearsAllOrganizerFilters"] = organizer.minimumRating == 0 && !organizer.onlyPicks && organizer.album == nil && !organizer.showTrash && organizer.matches(first,query: "")
            organizer.selecting = true; organizer.selectedIDs = [first.id]
            await organizer.update(album: UUID())
            checks["failedActionKeepsSelection"] = organizer.error != nil && organizer.selectedIDs == [first.id] && !organizer.isWorking
            organizer.error = nil
            await organizer.createAlbum("Library smoke")
            if let album = organizer.catalog.albums.last {
                await organizer.update(album: album.id)
                checks["addToAlbum"] = organizer.catalog[first.id].albumIDs.contains(album.id)
                await organizer.removeAlbum(album.id)
                checks["removeAlbumKeepsPhoto"] = !organizer.catalog[first.id].albumIDs.contains(album.id) && organizer.matches(first,query: "")
            }
            try await shared.finish(checks,assets: store.recent,error: organizer.error)
            organizer.resetFilters(); organizer.status = nil
            let args = ProcessInfo.processInfo.arguments
            if args.contains("--library-smoke-trash") {
                await organizer.update(ids: [first.id],trash: true)
                organizer.showTrash = true; organizer.status = nil
            }
            if args.contains("--library-smoke-selection") || args.contains("--library-smoke-confirm") || args.contains("--library-smoke-trash") {
                organizer.selecting = true; organizer.selectedIDs = [first.id]
            }
        } catch { store.pickerFailed(error) }
    }
}
#endif
