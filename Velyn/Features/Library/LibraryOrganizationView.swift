import SwiftUI

struct LibraryOrganizationView: View {
    let organizer: LibraryOrganizer
    @State private var name = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("필터") {
                    Picker("별점",selection: Binding(get: { organizer.minimumRating },set: { organizer.minimumRating = $0 })) { Text("모든 별점").tag(0); ForEach(1...5,id: \.self) { Text("\($0)점 이상").tag($0) } }
                    Toggle("선택 표시한 사진",isOn: Binding(get: { organizer.onlyPicks },set: { organizer.onlyPicks = $0 }))
                    Toggle("휴지통 보기",isOn: Binding(get: { organizer.showTrash },set: { organizer.showTrash = $0 }))
                    Button("필터 초기화") { organizer.minimumRating = 0; organizer.onlyPicks = false; organizer.album = nil; organizer.showTrash = false }
                }
                Section("앨범") {
                    Button { organizer.album = nil; dismiss() } label: { Label("모든 사진",systemImage: organizer.album == nil ? "checkmark" : "photo.on.rectangle") }
                    ForEach(organizer.catalog.albums) { album in
                        HStack {
                            Button { organizer.album = album.id; dismiss() } label: { Label(album.name,systemImage: organizer.album == album.id ? "checkmark" : "rectangle.stack") }
                            Spacer()
                            Menu { Button("앨범 삭제 · 사진 유지",role: .destructive) { Task { await organizer.removeAlbum(album.id) } } } label: { Image(systemName: "ellipsis").frame(width: 44,height: 44) }
                        }
                    }
                    HStack { TextField("새 앨범 이름",text: $name); Button("추가") { Task { await organizer.createAlbum(name); name = "" } }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }
                Section { Text("휴지통의 사진은 자동 삭제되지 않습니다. 사진 앱의 원본은 변경하지 않습니다.").font(.caption).foregroundStyle(.secondary) }
            }.navigationTitle("앨범·필터").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}
