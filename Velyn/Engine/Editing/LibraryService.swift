import Foundation
import Vision

public actor LibraryService {
    private let root: URL
    public init(root: URL) { self.root = root }
    public func load() throws -> LibraryCatalog {
        let path = root.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return LibraryCatalog() }
        let catalog = try JSONDecoder().decode(LibraryCatalog.self,from: Data(contentsOf: path))
        guard catalog.isValid else { throw EditorFailure.invalidDocument }
        return catalog
    }
    private func save(_ catalog: LibraryCatalog) throws {
        guard catalog.isValid else { throw EditorFailure.invalidDocument }
        try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
        var excludedRoot = root; var values = URLResourceValues(); values.isExcludedFromBackup = true; try excludedRoot.setResourceValues(values)
        try JSONEncoder().encode(catalog).write(to: root.appendingPathComponent("catalog.json"),options: .atomic)
    }
    public func update(ids: [UUID],rating: Int? = nil,flag: PhotoFlag? = nil,album: UUID? = nil,trash: Bool? = nil) throws -> LibraryCatalog {
        var catalog = try load()
        if let rating, !(0...5).contains(rating) { throw EditorFailure.invalidDocument }
        if let album, !catalog.albums.contains(where: { $0.id == album }) { throw EditorFailure.invalidDocument }
        for id in ids {
            var entry = catalog[id]
            if let rating { entry.rating = rating }; if let flag { entry.flag = flag }
            if let album, !entry.albumIDs.contains(album) { entry.albumIDs.append(album) }
            if let trash { entry.trashedAt = trash ? Date() : nil }
            catalog[id] = entry
        }
        try save(catalog); return catalog
    }
    public func createAlbum(_ name: String) throws -> LibraryCatalog {
        var catalog = try load()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw EditorFailure.invalidDocument }
        catalog.albums.append(PhotoAlbum(name: name)); try save(catalog); return catalog
    }
    public func removeAlbum(_ id: UUID) throws -> LibraryCatalog {
        var catalog = try load(); catalog.albums.removeAll { $0.id == id }
        for key in catalog.entries.keys { catalog.entries[key]?.albumIDs.removeAll { $0 == id } }
        try save(catalog); return catalog
    }
    public func copyEdits(from asset: SourceAsset) async throws -> EditRecipe {
        try await EditingService(root: root,asset: asset).load().history.current.colorOnly
    }
    public func pasteEdits(_ recipe: EditRecipe,to asset: SourceAsset) async throws {
        try Task.checkCancellation()
        let service = EditingService(root: root,asset: asset)
        var document = try await service.load()
        var next = recipe.colorOnly
        next.rawAdjustments = document.history.current.rawAdjustments
        let previous = document.history.current
        next.aspect = previous.aspect; next.quarterTurns = previous.quarterTurns; next.flipHorizontal = previous.flipHorizontal
        for key in [Adjustment.straighten,.cropScale,.cropX,.cropY,.perspectiveHorizontal,.perspectiveVertical,.lensDistortion] { next[key] = previous[key] }
        next.enhancements.masks = previous.enhancements.masks; next.enhancements.retouches = previous.enhancements.retouches
        next.enhancements.depth = previous.enhancements.depth; next[.lensBlur] = previous[.lensBlur]
        next.enhancements.removals = previous.enhancements.removals
        next.enhancements.hdrExpansion = previous.enhancements.hdrExpansion
        document.history.commit(next); document.revision += 1
        try Task.checkCancellation(); try await service.save(document)
    }
    public func export(_ asset: SourceAsset,settings: ExportSettings,directory: URL) async throws -> URL {
        let service = EditingService(root: root,asset: asset)
        let document = try await service.load()
        return try await service.export(document,settings: settings,directory: directory)
    }
    public func classify(_ asset: SourceAsset) async throws -> LibraryCatalog {
        _ = try await OriginalImportService(root: root).verify(asset)
        let preview = try await OriginalImportService(root: root).preview(asset,maxPixelSize: 512)
        let request = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: preview.image).perform([request])
        try Task.checkCancellation()
        let tags = (request.results ?? []).filter { $0.confidence >= 0.25 }.prefix(15).map(\.identifier)
        var catalog = try load(); catalog[asset.id].keywords = tags
        try save(catalog); return catalog
    }
}
