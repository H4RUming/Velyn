import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @AppStorage(L10n.preferenceKey) private var appLanguage = AppLanguage.system.rawValue
    @State private var store = ImportStore()
    @State private var organizer = LibraryOrganizer()
    @State private var showOrganizer = false
    @State private var showBatchExport = false
    @State private var albumName = ""
    @State private var showAlbumName = false
    @State private var showTrashConfirm = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var cameraSelection: Result<URL,Error>?
    @State private var showImportSources = false
    @State private var showPhotos = false
    @State private var pendingImportAction: PhotoImportAction?
    @State private var photoSelection: Result<[String], Error>?
    @State private var showSettings = false
    @State private var showSearch = false
    @State private var query = ""
    @State private var libraryRevision = 0
    @State private var filter: PhotoFilter = .all
    @AppStorage("libraryNewestFirst") private var newestFirst = true
    @AppStorage("libraryColumns") private var columnCount = 3
    @FocusState private var searchFocused: Bool

    private enum PhotoFilter: String, CaseIterable {
        case all = "모든 사진", raw = "RAW", raster = "일반 이미지"
    }

    private var photos: [SourceAsset] {
        store.recent.filter { asset in
            (filter == .all || (filter == .raw ? asset.isRAW : !asset.isRAW)) &&
            organizer.matches(asset,query: query)
        }.sorted { newestFirst ? $0.importedAt > $1.importedAt : $0.importedAt < $1.importedAt }
    }

    var body: some View {
        let _ = appLanguage
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                libraryToolbar
                if showSearch { searchField }
                if store.recent.isEmpty {
                    emptyLibrary.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if photos.isEmpty {
                    noResults.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    photoGrid(width: geometry.size.width)
                }
                if store.isWorking { progress }
                if organizer.isWorking { HStack { ProgressView(); Text(organizer.status ?? L10n.tr("처리 중")).font(.caption); Spacer(); Button(L10n.tr("취소")) { organizer.cancel() } }.padding() }
                else if let status = organizer.status ?? store.status { Text(status).font(.caption2).foregroundStyle(.secondary).padding(5) }
                if organizer.selecting { selectionBar }
                bottomBar
            }
            .background(LibraryStyle.background)
        }
        .tint(LibraryStyle.blue)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showImportSources,onDismiss: performImportAction) {
            PhotoImportSheet { action in pendingImportAction = action; showImportSources = false }
        }
        .fullScreenCover(isPresented: $showCamera,onDismiss: {
            if let cameraSelection {
                switch cameraSelection { case .success(let url): store.importCapture(url); case .failure(let error): store.pickerFailed(error) }
                self.cameraSelection = nil
            }
        }) { CameraCaptureView { result in cameraSelection = result; showCamera = false } }
        .sheet(isPresented: $showPhotos, onDismiss: importSelectedPhoto) {
            PhotoLibraryPicker { result in
                photoSelection = result
                showPhotos = false
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: ImageFormats.importTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): store.importFiles(urls)
            case .failure(let error): store.pickerFailed(error)
            }
        }
        .alert(L10n.tr("사진을 열 수 없습니다"), isPresented: Binding(
            get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
        )) { Button(L10n.tr("확인"), role: .cancel) { store.errorMessage = nil } }
        message: { Text(store.errorMessage ?? "") }
        .sheet(item: Binding(get: { organizer.sharing },set: { organizer.sharing = $0 })) { item in ActivityShareView(urls: item.urls) }
        .sheet(isPresented: $showOrganizer) { LibraryOrganizationView(organizer: organizer) }
        .sheet(isPresented: $showBatchExport) { BatchExportOptionsView(count: organizer.selectedIDs.count) { settings in organizer.run(.export,assets: photos,settings: settings) } }
        .alert(L10n.tr("라이브러리 작업"),isPresented: Binding(get: { organizer.error != nil },set: { if !$0 { organizer.error = nil } })) { Button(L10n.tr("확인")) { organizer.error = nil } } message: { Text(organizer.error ?? "") }
        .confirmationDialog(L10n.tr("선택한 사진을 휴지통으로 옮길까요?"),isPresented: $showTrashConfirm,titleVisibility: .visible) { Button(L10n.tr("휴지통으로 이동"),role: .destructive) { Task { await organizer.update(trash: true) } } } message: { Text(L10n.tr("사진 앱의 원본은 유지됩니다. 앱 휴지통에서 복원할 수 있습니다.")) }
        .onChange(of: organizer.revision) { _, _ in libraryRevision += 1 }
        .sheet(isPresented: $showSettings) { LibrarySettingsView(count: store.recent.count) }
        .fullScreenCover(item: Binding(get: { store.selected }, set: { if $0 == nil { store.dismissSelection() } })) { asset in
            PhotoDetailView(asset: asset, store: store)
        }
        .task {
            await store.loadRecent()
            await organizer.load()
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--settings-smoke-test") { showSettings = true }
            if ProcessInfo.processInfo.arguments.contains("--import-source-smoke-test") { showImportSources = true }
            if ProcessInfo.processInfo.arguments.contains("--photo-library-smoke-test") { showPhotos = true }
            if ProcessInfo.processInfo.arguments.contains("--editor-smoke-test") {
                let useRAW = ProcessInfo.processInfo.arguments.contains("--editor-smoke-raw")
                if let asset = store.recent.first(where: { $0.isRAW == useRAW }) { store.open(asset) }
                else {
                    do { store.importFile(try await EditorSmokeFixture.shared.create()) }
                    catch { store.pickerFailed(error) }
                }
            }
            #endif
        }
        .onChange(of: store.selected?.id) { _, value in
            if value == nil { libraryRevision += 1 }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Velyn").font(.system(size: 22, weight: .bold)).tracking(-0.7)
            Spacer()
            Button {
                showSearch.toggle()
                if showSearch { searchFocused = true } else { query = "" }
            } label: { LibraryIcon(symbol: showSearch ? "xmark" : "magnifyingglass") }
                .accessibilityLabel(showSearch ? L10n.tr("검색 닫기") : L10n.tr("파일명 검색"))
            Menu {
                Button(L10n.tr("앨범·필터")) { showOrganizer = true }
                Button(organizer.selecting ? L10n.tr("선택 완료") : L10n.tr("사진 선택")) { organizer.selecting.toggle(); if !organizer.selecting { organizer.selectedIDs = [] } }
                Button(L10n.tr("설정")) { showSettings = true }
            } label: { LibraryIcon(symbol: "ellipsis") }
                .accessibilityLabel(L10n.tr("라이브러리 설정"))
        }
        .foregroundStyle(.white)
        .padding(.leading, 20).padding(.trailing, 6).padding(.vertical, 5)
        .background(LibraryStyle.bar)
    }

    private var libraryToolbar: some View {
        HStack(spacing: 6) {
            Menu {
                Picker(L10n.tr("사진 형식"), selection: $filter) {
                    ForEach(PhotoFilter.allCases, id: \.self) { Text(L10n.tr($0.rawValue)).tag($0) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(organizer.showTrash ? L10n.tr("휴지통") : (organizer.catalog.albums.first(where: { $0.id == organizer.album })?.name ?? L10n.tr(filter.rawValue))).font(.system(size: 16, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                }.frame(minHeight: 44)
            }.foregroundStyle(.white)
            Text("\(photos.count)").font(.system(size: 13)).foregroundStyle(LibraryStyle.secondary).padding(.leading, 4)
            Spacer()
            Menu {
                Picker(L10n.tr("정렬"), selection: $newestFirst) {
                    Text(L10n.tr("최근 추가한 순")).tag(true)
                    Text(L10n.tr("먼저 추가한 순")).tag(false)
                }
                Picker(L10n.tr("사진 크기"), selection: $columnCount) {
                    Text(L10n.tr("크게 보기")).tag(2)
                    Text(L10n.tr("작게 보기")).tag(3)
                }
            } label: { LibraryIcon(symbol: "arrow.up.arrow.down") }
                .foregroundStyle(LibraryStyle.secondary).accessibilityLabel(L10n.tr("정렬 및 사진 크기"))
        }.padding(.leading, 20).padding(.trailing, 6).padding(.vertical, 4)
            .background(LibraryStyle.bar)
            .overlay(alignment: .bottom) { Rectangle().fill(LibraryStyle.separator).frame(height: 0.5) }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(LibraryStyle.secondary)
            TextField(L10n.tr("파일명 검색"), text: $query).font(.subheadline).focused($searchFocused)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: { LibraryIcon(symbol: "xmark.circle.fill") }
                    .foregroundStyle(LibraryStyle.secondary).accessibilityLabel(L10n.tr("검색어 지우기"))
            }
        }.padding(.horizontal, 16).frame(minHeight: 48).background(LibraryStyle.raised)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "photo.on.rectangle").font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(Color(white: 0.52)).padding(.bottom, 22)
            Text(L10n.tr("라이브러리에 사진 추가")).font(.system(size: 18, weight: .semibold)).padding(.bottom, 10)
            Text(L10n.tr("사진 보관함이나 파일에서 가져와\n여기에서 모아 보세요."))
                .font(.system(size: 14)).foregroundStyle(LibraryStyle.secondary)
                .multilineTextAlignment(.center).lineSpacing(5)
            Button(L10n.tr("사진 추가")) { showImportSources = true }
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 26).frame(minHeight: 44)
                .background(LibraryStyle.blue, in: RoundedRectangle(cornerRadius: 6))
                .padding(.top, 24).disabled(store.isWorking)
                .accessibilityIdentifier("add-photo-empty")
            Spacer()
            Text(L10n.tr("RAW · JPEG · HEIC · PNG · WebP · TIFF 외")).font(.system(size: 10, weight: .medium))
                .tracking(1).foregroundStyle(Color(white: 0.42)).padding(.bottom, 24)
        }.padding(.horizontal, 24)
    }

    private var noResults: some View {
        VStack(spacing: 12) {
            Text(L10n.tr("일치하는 사진이 없습니다")).font(.headline)
            Button(L10n.tr("필터 초기화")) { filter = .all; query = "" }.frame(minHeight: 44)
        }
    }

    private func photoGrid(width: CGFloat) -> some View {
        let columns = min(max(columnCount, 2), 3)
        let side = (width - CGFloat(columns - 1) * 2) / CGFloat(columns)
        return ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
                ForEach(photos) { asset in
                    Button { searchFocused = false; if organizer.selecting { organizer.toggle(asset.id) } else { store.open(asset) } } label: {
                        PhotoThumbnail(asset: asset, store: store, revision: libraryRevision)
                            .overlay(alignment: .topTrailing) {
                                if organizer.selecting { Image(systemName: organizer.selectedIDs.contains(asset.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(organizer.selectedIDs.contains(asset.id) ? LibraryStyle.blue : .white).font(.title3).padding(8).shadow(radius: 2) }
                            }
                            .overlay(alignment: .bottomTrailing) {
                                let entry = organizer.catalog[asset.id]
                                if entry.rating > 0 || entry.flag != .none { Text(entry.flag == .pick ? "⚑ \(entry.rating)★" : "\(entry.rating)★").font(.caption2).foregroundStyle(.white).padding(5).background(.black.opacity(0.5)) }
                            }
                            .frame(height: side)
                            .overlay(alignment: .bottomLeading) {
                                if asset.isRAW {
                                    Text("RAW").font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 4).padding(.vertical, 3)
                                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 2))
                                        .foregroundStyle(.white).padding(7)
                                }
                            }
                    }.buttonStyle(.plain).disabled(store.isWorking || organizer.isWorking)
                        .accessibilityLabel("\(asset.originalFilename), \(asset.formatLabel)")
                }
            }.padding(.top, 2)
            HStack {
                Text(L10n.format("%ld장의 사진",photos.count))
                Circle().frame(width: 2, height: 2)
                Text(L10n.tr("이 기기에 보관됨"))
            }.font(.caption2).foregroundStyle(LibraryStyle.secondary).padding(.vertical, 24)
        }.scrollDismissesKeyboard(.interactively)
    }

    private var bottomBar: some View {
        HStack {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2.fill").font(.system(size: 18))
                Text(L10n.tr("라이브러리")).font(.system(size: 12, weight: .semibold))
            }.foregroundStyle(.white).accessibilityAddTraits(.isSelected)
            Spacer()
            Button { searchFocused = false; showImportSources = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 17, weight: .medium))
                    Text(L10n.tr("사진 추가")).font(.system(size: 13, weight: .semibold))
                }.foregroundStyle(.white).padding(.horizontal, 16).frame(height: 44)
                    .background(LibraryStyle.blue, in: RoundedRectangle(cornerRadius: 6))
            }.disabled(store.isWorking).accessibilityIdentifier("add-photo")
        }.padding(.horizontal, 20).padding(.vertical, 12)
            .background(LibraryStyle.bar)
            .overlay(alignment: .top) { Rectangle().fill(LibraryStyle.separator).frame(height: 0.5) }
    }

    private var progress: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text(store.status ?? L10n.tr("사진을 여는 중")).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.tr("취소"), role: .cancel) { store.cancel() }.font(.caption).frame(minWidth: 44, minHeight: 44)
        }.padding(.horizontal, 16).background(LibraryStyle.raised)
    }

    private var selectionBar: some View {
        HStack {
            Button(L10n.tr("전체")) { organizer.selectedIDs = Set(photos.map(\.id)) }
            Text(L10n.format("%ld장",organizer.selectedIDs.count)).font(.caption)
            Spacer()
            Menu(L10n.tr("작업")) {
                if organizer.showTrash { Button(L10n.tr("복원")) { Task { await organizer.update(trash: false) } } }
                else {
                    Menu(L10n.tr("별점")) { ForEach(0...5,id: \.self) { value in Button(L10n.format("%ld점",value)) { Task { await organizer.update(rating: value) } } } }
                    Menu(L10n.tr("선별")) { ForEach(PhotoFlag.allCases,id: \.self) { flag in Button(L10n.tr(flag.rawValue)) { Task { await organizer.update(flag: flag) } } } }
                    Menu(L10n.tr("앨범에 추가")) { ForEach(organizer.catalog.albums) { album in Button(album.name) { Task { await organizer.update(album: album.id) } } } }
                    if organizer.selectedIDs.count == 1, let asset = photos.first(where: { organizer.selectedIDs.contains($0.id) }) { Button(L10n.tr("색·톤 보정 복사")) { Task { await organizer.copy(asset) } } }
                    Button(L10n.tr("색·톤 보정 붙여넣기")) { organizer.run(.paste,assets: photos) }.disabled(organizer.copiedEdits == nil)
                    Button(L10n.tr("일괄 내보내기")) { showBatchExport = true }
                    Button(L10n.tr("사진 내용 분석 · 기기 내")) { organizer.run(.classify,assets: photos) }
                    Button(L10n.tr("휴지통으로 이동"),role: .destructive) { showTrashConfirm = true }
                }
            }.disabled(organizer.selectedIDs.isEmpty || organizer.isWorking)
            Button(L10n.tr("완료")) { organizer.selecting = false; organizer.selectedIDs = [] }
        }.font(.subheadline).padding().background(LibraryStyle.raised)
    }

    private func performImportAction() {
        defer { pendingImportAction = nil }
        switch pendingImportAction {
        case .files: showFiles = true
        case .camera: showCamera = true
        case .selection(let ids): store.importPhotos(ids)
        case .failure(let error): store.pickerFailed(error)
        case nil: break
        }
    }

    private func importSelectedPhoto() {
        defer { photoSelection = nil }
        guard let photoSelection else { return }
        switch photoSelection {
        case .success(let identifiers): store.importPhotos(identifiers)
        case .failure(let error): store.pickerFailed(error)
        }
    }
}

#Preview { ContentView() }
