import SwiftUI

struct LibraryOrganizationView: View {
    let organizer: LibraryOrganizer
    @State private var name = ""
    @State private var showNewAlbum = false
    @State private var deleting: PhotoAlbum?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { organizer.resetFilters(); dismiss() } label: { Label(L10n.tr("모든 사진"),systemImage: "photo.on.rectangle") }
                    Button { organizer.resetFilters(); organizer.showTrash = true; dismiss() } label: { Label(L10n.tr("휴지통"),systemImage: "trash") }
                }
                Section {
                    ForEach(organizer.catalog.albums) { album in
                        HStack {
                            Button { organizer.album = album.id; organizer.showTrash = false; organizer.endSelection(); dismiss() } label: {
                                Label(album.name,systemImage: organizer.album == album.id ? "checkmark.circle.fill" : "rectangle.stack").frame(maxWidth: .infinity,alignment: .leading).frame(minHeight: 44)
                            }
                            Menu { Button(L10n.tr("앨범 삭제 · 사진 유지"),role: .destructive) { deleting = album } } label: {
                                Image(systemName: "ellipsis").frame(width: 44,height: 44)
                            }.accessibilityLabel(L10n.format("%@ 앨범 관리",album.name))
                        }
                    }
                    if organizer.catalog.albums.isEmpty { Text(L10n.tr("앨범을 만들어 사진을 정리해 보세요.")).foregroundStyle(.secondary).font(.subheadline) }
                    Button { name = ""; showNewAlbum = true } label: { Label(L10n.tr("새 앨범"),systemImage: "plus") }
                } header: { Text(L10n.tr("앨범")) } footer: { Text(L10n.tr("앨범을 삭제해도 사진은 모든 사진에 남습니다.")) }
                Section(L10n.tr("별점·선별 필터")) {
                    Picker(L10n.tr("별점"),selection: Binding(get: { organizer.minimumRating },set: { organizer.minimumRating = $0 })) {
                        Text(L10n.tr("모든 별점")).tag(0)
                        ForEach(1...5,id: \.self) { Text(L10n.format("%ld점 이상",$0)).tag($0) }
                    }
                    Toggle(L10n.tr("선택 표시한 사진"),isOn: Binding(get: { organizer.onlyPicks },set: { organizer.onlyPicks = $0 }))
                    Button(L10n.tr("필터 초기화")) { organizer.minimumRating = 0; organizer.onlyPicks = false }
                }
            }.disabled(organizer.isWorking)
                .navigationTitle(L10n.tr("앨범·필터")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("완료")) { dismiss() } } }
                .alert(L10n.tr("새 앨범"),isPresented: $showNewAlbum) {
                    TextField(L10n.tr("새 앨범 이름"),text: $name)
                    Button(L10n.tr("취소"),role: .cancel) {}
                    Button(L10n.tr("만들기")) { Task { await organizer.createAlbum(name) } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
                }
                .confirmationDialog(L10n.tr("앨범을 삭제할까요?"),isPresented: Binding(get: { deleting != nil },set: { if !$0 { deleting = nil } }),titleVisibility: .visible) {
                    if let album = deleting { Button(L10n.format("%@ 삭제",album.name),role: .destructive) { Task { await organizer.removeAlbum(album.id) } } }
                } message: { Text(L10n.tr("앨범을 삭제해도 사진은 모든 사진에 남습니다.")) }
                .alert(L10n.tr("라이브러리 작업"),isPresented: Binding(get: { organizer.error != nil },set: { if !$0 { organizer.error = nil } })) {
                    Button(L10n.tr("확인")) { organizer.error = nil }
                } message: { Text(organizer.error ?? "") }
        }.preferredColorScheme(.dark).tint(LibraryStyle.blue)
    }
}

struct AddToAlbumView: View {
    let organizer: LibraryOrganizer
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(L10n.format("%ld장 선택됨",organizer.selectedIDs.count)).foregroundStyle(.secondary)
                    ForEach(organizer.catalog.albums) { album in
                        Button { Task { await organizer.update(album: album.id); if organizer.error == nil { dismiss() } } } label: {
                            Label(album.name,systemImage: "rectangle.stack").frame(minHeight: 44)
                        }
                    }
                }
                Section(L10n.tr("새 앨범")) {
                    TextField(L10n.tr("새 앨범 이름"),text: $name)
                    Button(L10n.tr("만들고 사진 추가")) {
                        Task {
                            let previous = Set(organizer.catalog.albums.map(\.id))
                            await organizer.createAlbum(name)
                            if let album = organizer.catalog.albums.first(where: { !previous.contains($0.id) }) {
                                await organizer.update(album: album.id)
                                if organizer.error == nil { dismiss() }
                            }
                        }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80)
                }
            }.disabled(organizer.isWorking)
                .navigationTitle(L10n.tr("앨범에 추가")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("취소")) { dismiss() } } }
                .alert(L10n.tr("라이브러리 작업"),isPresented: Binding(get: { organizer.error != nil },set: { if !$0 { organizer.error = nil } })) {
                    Button(L10n.tr("확인")) { organizer.error = nil }
                } message: { Text(organizer.error ?? "") }
        }.preferredColorScheme(.dark).tint(LibraryStyle.blue)
    }
}
