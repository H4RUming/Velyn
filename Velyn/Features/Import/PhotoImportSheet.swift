import SwiftUI
import Photos

enum PhotoImportAction {
    case files, camera, selection([String]), failure(Error)
}

struct PhotoImportSheet: View {
    let completion: (PhotoImportAction?) -> Void
    @State private var photos: [BrowserPhoto] = []
    @State private var selected: [String] = []
    @State private var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var loading = false
    @State private var hasMore = false
    @State private var error: String?
    @State private var showAll = false
    @State private var showLimited = false
    @State private var pickerResult: Result<[String],Error>?
    @State private var service = PhotoBrowserService()
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    private var accessible: Bool { authorization == .authorized || authorization == .limited }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading,spacing: 4) {
                    Text(L10n.tr("사진 추가")).font(.title3.weight(.semibold))
                    Text(L10n.tr("원본을 그대로 가져옵니다")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { completion(nil) } label: { Image(systemName: "xmark").font(.system(size: 13,weight: .semibold)).frame(width: 32,height: 32).background(.white.opacity(0.08),in: Circle()) }
                    .accessibilityLabel(L10n.tr("사진 선택 닫기"))
            }.padding(.horizontal,20).padding(.top,22).padding(.bottom,18)
            HStack(spacing: 10) {
                sourceButton(L10n.tr("파일"),icon: "folder",subtitle: L10n.tr("PNG · WebP · RAW 등")) { completion(.files) }
                sourceButton(L10n.tr("카메라"),icon: "camera",subtitle: L10n.tr("새 사진 촬영")) { completion(.camera) }
            }.padding(.horizontal,16).padding(.bottom,18)
            if accessible {
                HStack {
                    Text(L10n.tr("최근 사진")).font(.subheadline.weight(.semibold))
                    Spacer()
                    Button(L10n.tr("앨범 · 전체 보기")) { showAll = true }.font(.subheadline)
                }.padding(.horizontal,20).frame(height: 40)
                if authorization == .limited {
                    HStack { Text(L10n.tr("허용한 사진만 표시 중")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(L10n.tr("선택 범위 변경")) { showLimited = true }.font(.caption) }
                        .padding(.horizontal,20).frame(minHeight: 36)
                }
                GeometryReader { geometry in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(),spacing: 2),count: 3),spacing: 2) {
                            ForEach(Array(photos.enumerated()),id: \.element.id) { index, photo in
                                PhotoSelectionCell(id: photo.id, number: index+1, selectedIndex: selected.firstIndex(of: photo.id),
                                    side: (geometry.size.width-4)/3, service: service) { toggle(photo.id) }
                            }
                        }
                        if hasMore { ProgressView().padding().task { await loadMore() } }
                        if photos.isEmpty && !loading { Text(L10n.tr("표시할 사진이 없습니다")).foregroundStyle(.secondary).padding(32) }
                    }
                    .overlay { if loading && photos.isEmpty { ProgressView() } }
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 34,weight: .light)).foregroundStyle(.secondary)
                    Text(L10n.tr("사진을 한눈에 골라보세요")).font(.headline)
                    Text(L10n.tr("선택한 사진만 허용해도 됩니다.\n파일 가져오기는 사진 접근 권한 없이 사용할 수 있습니다."))
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(authorization == .notDetermined ? L10n.tr("사진 선택 허용") : L10n.tr("사진 접근 설정")) {
                        if authorization == .notDetermined {
                            Task { authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite); await reload() }
                        } else if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }.padding(24).frame(maxWidth: .infinity,maxHeight: .infinity)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).padding(.horizontal) }
        }
        .safeAreaInset(edge: .bottom,spacing: 0) {
            if accessible {
                HStack(spacing: 14) {
                    VStack(alignment: .leading,spacing: 3) {
                        Text(selected.isEmpty ? L10n.tr("사진을 선택하세요") : L10n.format("%ld장 선택됨",selected.count)).font(.subheadline.weight(.medium))
                        Text(L10n.tr("움직이는 이미지는 첫 장면을 편집합니다")).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button(L10n.tr("추가")) { completion(.selection(selected)) }
                        .font(.subheadline.weight(.semibold)).padding(.horizontal,22).frame(height: 44)
                        .background(selected.isEmpty ? Color.white.opacity(0.08) : LibraryStyle.blue,in: Capsule())
                        .foregroundStyle(selected.isEmpty ? LibraryStyle.secondary : Color.white).disabled(selected.isEmpty)
                }.padding(.horizontal,20).padding(.vertical,12).background(LibraryStyle.bar)
            }
        }
        .background(LibraryStyle.bar).preferredColorScheme(.dark).tint(LibraryStyle.blue)
        .presentationDetents([.fraction(0.67),.large]).presentationDragIndicator(.visible).presentationCornerRadius(28)
        .task { await reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite); Task { await reload() } }
        }
        .sheet(isPresented: $showAll,onDismiss: {
            if let pickerResult {
                switch pickerResult { case .success(let ids): completion(.selection(ids)); case .failure(let error): completion(.failure(error)) }
                self.pickerResult = nil
            }
        }) { PhotoLibraryPicker { result in pickerResult = result; showAll = false } }
        .sheet(isPresented: $showLimited,onDismiss: { Task { await reload() } }) {
            LimitedPhotoAccessPicker { showLimited = false }
        }
    }
    private func sourceButton(_ title: String,icon: String,subtitle: String,action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 20,weight: .regular)).frame(width: 25)
                VStack(alignment: .leading,spacing: 4) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.foregroundStyle(.white).padding(13).frame(maxWidth: .infinity,minHeight: 66)
                .background(.white.opacity(0.05),in: RoundedRectangle(cornerRadius: 14))
        }.buttonStyle(.plain)
    }
    private func toggle(_ id: String) {
        if selected.contains(id) { selected.removeAll { $0 == id } }
        else if selected.count < 100 { selected.append(id) }
        else { error = L10n.tr("한 번에 최대 100장까지 선택할 수 있습니다.") }
    }
    private func reload() async {
        guard accessible, !loading else { return }
        photos = []; hasMore = false
        await loadMore()
        selected = await service.accessibleSelection(selected)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--import-source-smoke-select") { selected = Array(photos.prefix(3).map(\.id)) }
        #endif
    }
    private func loadMore() async {
        guard !loading else { return }
        loading = true; defer { loading = false }
        do {
            let page = try await service.page(offset: photos.count)
            try Task.checkCancellation()
            photos.append(contentsOf: page.photos); hasMore = page.hasMore
        } catch is CancellationError { } catch { self.error = error.localizedDescription }
    }
}

private struct BrowserThumbnail: View {
    let id: String
    let service: PhotoBrowserService
    @State private var preview: PhotoPreview?
    @State private var failed = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.15)
                if let preview {
                    Image(decorative: preview.image,scale: 1).resizable().scaledToFill()
                        .frame(width: geometry.size.width,height: geometry.size.height).clipped()
                } else if failed { Image(systemName: "icloud").foregroundStyle(.secondary) }
            }
        }.task(id: id) {
            do { let value = try await service.thumbnail(id: id); try Task.checkCancellation(); preview = value }
            catch is CancellationError { } catch { failed = true }
        }.onDisappear { preview = nil }
    }
}


private struct PhotoSelectionCell: View {
    let id: String
    let number: Int
    let selectedIndex: Int?
    let side: CGFloat
    let service: PhotoBrowserService
    let select: () -> Void
    var body: some View {
        Button(action: select) {
            BrowserThumbnail(id: id,service: service)
                .frame(height: side).clipped()
                .overlay { if selectedIndex != nil { Color.black.opacity(0.2) } }
                .overlay(alignment: .topTrailing) {
                    ZStack {
                        Circle().fill(selectedIndex != nil ? LibraryStyle.blue : Color.black.opacity(0.2))
                        Circle().strokeBorder(Color.white.opacity(0.85),lineWidth: 1.5)
                        if let selectedIndex { Text(String(selectedIndex+1)).font(.system(size: 12,weight: .bold)).foregroundStyle(Color.white) }
                    }.frame(width: 25,height: 25).padding(8)
                }
        }.buttonStyle(.plain).accessibilityLabel(L10n.format("사진 %ld",number))
            .accessibilityAddTraits(selectedIndex != nil ? .isSelected : [])
    }
}
