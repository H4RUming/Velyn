import SwiftUI
import UniformTypeIdentifiers

enum LibraryStyle {
    static let background = Color(white: 0.075)
    static let bar = Color(white: 0.105)
    static let raised = Color(white: 0.15)
    static let separator = Color(white: 0.23)
    static let secondary = Color(white: 0.61)
    static let blue = Color(red: 0.28, green: 0.57, blue: 1)
}

extension SourceAsset {
    var formatLabel: String {
        if isRAW { return "RAW" }
        return UTType(typeIdentifier)?.preferredFilenameExtension?.uppercased() ?? "PHOTO"
    }
}

struct PhotoThumbnail: View {
    let asset: SourceAsset
    let store: ImportStore
    var revision = 0
    var size = 480
    var fill = true
    @State private var preview: PhotoPreview?
    @State private var failed = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.12)
                if let preview {
                    Image(decorative: preview.image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: fill ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if failed {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark").font(.title3)
                        if !fill { Text(L10n.tr("미리보기를 표시할 수 없습니다")).font(.caption) }
                    }.foregroundStyle(LibraryStyle.secondary)
                } else {
                    ProgressView().controlSize(.small).tint(.gray)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .onDisappear { preview = nil }
        .task(id: "\(asset.id)-\(size)-\(revision)") {
            preview = nil
            failed = false
            do {
                let result = try await store.preview(asset, size: size)
                try Task.checkCancellation()
                preview = result
            } catch is CancellationError { }
            catch { failed = true }
        }
    }
}

struct LibraryIcon: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 18, weight: .regular))
            .frame(width: 44, height: 44).contentShape(Rectangle())
    }
}
