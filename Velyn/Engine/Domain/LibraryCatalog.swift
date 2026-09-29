import Foundation

public enum PhotoFlag: String, Codable, Sendable, CaseIterable { case none = "없음", pick = "선택", reject = "제외" }
public struct LibraryEntry: Codable, Sendable, Equatable {
    public var rating = 0
    public var flag: PhotoFlag = .none
    public var albumIDs: [UUID] = []
    public var keywords: [String] = []
    public var trashedAt: Date?
    public init() {}
}
public struct PhotoAlbum: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var name: String
    public init(name: String) { self.name = name }
}
public struct LibraryCatalog: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var entries: [String: LibraryEntry] = [:]
    public var albums: [PhotoAlbum] = []
    public init() {}
    public subscript(_ id: UUID) -> LibraryEntry {
        get { entries[id.uuidString] ?? LibraryEntry() }
        set { entries[id.uuidString] = newValue }
    }
    public var isValid: Bool {
        schemaVersion == 1 && Set(albums.map(\.id)).count == albums.count && albums.allSatisfy { !$0.name.isEmpty && $0.name.count <= 80 } &&
        entries.allSatisfy { UUID(uuidString: $0.key) != nil && (0...5).contains($0.value.rating) && $0.value.keywords.count <= 100 && $0.value.keywords.allSatisfy { $0.count <= 80 } }
    }
}
