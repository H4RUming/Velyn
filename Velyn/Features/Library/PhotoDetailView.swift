import SwiftUI
import UIKit

struct PhotoDetailView: View {
    let asset: SourceAsset
    let store: ImportStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var editor: EditorStore
    @State private var tool: EditorTool? = .light
    @State private var showInfo = false
    @State private var showTools = false
    @State private var showExport = false
    @State private var showReset = false
    @State private var resetID = 0

    init(asset: SourceAsset, store: ImportStore) {
        self.asset = asset; self.store = store
        _editor = State(initialValue: EditorStore(asset: asset))
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                if editor.showHistogram { EditDiagnosticsView(editor: editor) }
                ZStack {
                    Color.black
                    if let preview = editor.preview {
                        if tool == .retouch {
                            RemovalCanvas(editor: editor,image: preview.image)
                        } else if editor.spatialMode || editor.cropMode || editor.pickingWhiteBalance || editor.pickingDetail || editor.pickingDepth {
                            SpatialEditorView(editor: editor,image: preview.image,tool: tool)
                                .allowsHitTesting(!editor.isRendering && !editor.isAnalyzing)
                        } else {
                            ZoomablePhoto(image: preview.image, resetID: resetID)
                                .accessibilityLabel("사진 미리보기. 두 손가락으로 확대할 수 있습니다.")
                        }
                    } else if editor.loadFailed {
                        Button("편집 기록 다시 불러오기") { Task { await editor.load() } }
                    } else if editor.document != nil && !editor.isRendering {
                        Button("미리보기 다시 시도") { editor.retry() }
                    } else if editor.errorMessage == nil { ProgressView().tint(.white) }
                    if editor.isComparing {
                        VStack { Text("원본").font(.caption.weight(.semibold)).padding(8).background(.black.opacity(0.7)); Spacer() }.padding(.top, 10)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                statusBar
                if let tool {
                    if [.light,.color,.effects,.detail,.optics].contains(tool) {
                        FocusedAdjustmentControls(editor: editor,initial: tool.adjustments.first ?? .exposure)
                            .frame(height: 174).disabled(editor.document == nil || editor.isExporting)
                    } else {
                        HStack {
                            Text(tool.rawValue).font(.system(size: 12,weight: .semibold))
                            Spacer()
                            Button("조절로 돌아가기") { editor.finishGesture(); self.tool = .light }
                                .font(.caption).frame(minHeight: 32)
                        }.padding(.horizontal,20).background(LibraryStyle.bar)
                        EditorControls(editor: editor,tool: tool)
                            .frame(height: min(geometry.size.height*0.29,248))
                            .disabled(editor.document == nil || editor.isExporting)
                    }
                }
                toolBar
            }
        }
        .background(.black).preferredColorScheme(.dark).tint(LibraryStyle.blue)
        .interactiveDismissDisabled()
        .sheet(isPresented: $showTools) { EditorToolSheet(hasRAW: editor.rawControls != nil) { value in editor.finishGesture(); tool = value } }
        .sheet(isPresented: $showInfo) { PhotoInformationView(asset: asset) }
        .sheet(isPresented: $showExport, onDismiss: { editor.retry() }) { EditorExportView(editor: editor) }
        .alert("편집을 완료하지 못했습니다", isPresented: Binding(
            get: { editor.errorMessage != nil && !showExport }, set: { if !$0 { editor.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { editor.errorMessage = nil }
            Button("다시 시도") { Task { if editor.document == nil { await editor.load() } else { editor.retry() } } }
        } message: { Text(editor.errorMessage ?? "") }
        .confirmationDialog("모든 보정을 초기화할까요?", isPresented: $showReset, titleVisibility: .visible) {
            Button("보정 초기화", role: .destructive) { editor.reset() }
        } message: { Text("원본 사진은 유지되며 실행 취소로 보정을 복원할 수 있습니다.") }
        .task {
            await editor.load()
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--editor-smoke-roundtrip") {
                await EditorSmokeFixture.exercise(editor: editor)
            }
            if ProcessInfo.processInfo.arguments.contains("--editor-smoke-removal") { tool = .retouch; await EditorSmokeFixture.exerciseRemoval(editor: editor) }
            if ProcessInfo.processInfo.arguments.contains("--editor-smoke-raw") { tool = .raw; editor.setRAW(.temperature,5500); editor.finishGesture() }
            if ProcessInfo.processInfo.arguments.contains("--editor-smoke-mixer") { tool = .mix }
            if ProcessInfo.processInfo.arguments.contains("--editor-smoke-pro") { await EditorSmokeFixture.exerciseProfessional(editor: editor); tool = .masks }
            if ProcessInfo.processInfo.arguments.contains("--editor-interaction-smoke-test") { await EditorSmokeFixture.exerciseInteraction(editor: editor) }
            if ProcessInfo.processInfo.arguments.contains("--editor-smoke-gamut") { editor.reset(); editor.set(.gamutExpansion,70); editor.finishGesture() }
            if ProcessInfo.processInfo.arguments.contains("--editor-export-smoke-test") { showExport = true }
            if ProcessInfo.processInfo.arguments.contains("--editor-smoke-gain") { await EditorSmokeFixture.exerciseGainMap(editor: editor); tool = .hdr }
            if let value = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--editor-tool=") })?.split(separator: "=").last { tool = EditorTool.allCases.first { $0.rawValue == value } }
            #endif
        }
        .onDisappear { editor.cancelAnalysis() }
        .onChange(of: tool) { _, value in
            editor.cancelAnalysis()
            editor.previewSDR = false
            editor.pickingWhiteBalance = false; editor.pickingDetail = false
            editor.pickingDepth = false
            editor.cropMode = value == .crop
            editor.maskMode = value == .masks
            editor.setSpatialMode(value == .masks || value == .retouch)
        }
        .sheet(isPresented: Binding(get: { editor.detailPreview != nil },set: { if !$0 { editor.detailPreview = nil } })) {
            NavigationStack {
                if let image = editor.detailPreview?.image {
                    ZoomablePhoto(image: image,resetID: 0).background(.black).navigationTitle("원본 픽셀 · \(image.width) × \(image.height)").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { editor.detailPreview = nil } } }
                }
            }.preferredColorScheme(.dark)
        }
        .onChange(of: editor.recipe.geometryOnly) { _, _ in resetID += 1 }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { editor.cancelAnalysis(); editor.cancelExport(); Task { _ = await editor.flush() } }
            else { editor.retry() }
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button { Task { if await editor.flush() { dismiss() } } } label: { LibraryIcon(symbol: "chevron.left") }
                .accessibilityLabel("편집 저장 후 라이브러리로 돌아가기")
            Text(asset.originalFilename).font(.system(size: 12, weight: .medium)).lineLimit(1)
            Spacer(minLength: 4)
            Button { editor.undo() } label: { LibraryIcon(symbol: "arrow.uturn.backward") }
                .disabled(!editor.canUndo).opacity(editor.canUndo ? 1 : 0.3).accessibilityLabel("실행 취소")
            Button { editor.redo() } label: { LibraryIcon(symbol: "arrow.uturn.forward") }
                .disabled(!editor.canRedo).opacity(editor.canRedo ? 1 : 0.3).accessibilityLabel("다시 실행")
            Menu {
                Toggle("SDR 클리핑 경고",isOn: Binding(get: { editor.showClipping },set: { editor.showClipping = $0; editor.retry() }))
                Toggle("보정 지표",isOn: Binding(get: { editor.showHistogram },set: { editor.showHistogram = $0 }))
                Button("자동 톤 보정") { Task { await editor.autoTone() } }
                Button("원본 픽셀 확인") { editor.pickingDetail.toggle() }
                Button("사진 정보", systemImage: "info.circle") { showInfo = true }
                Button("화면 맞춤", systemImage: "arrow.down.right.and.arrow.up.left") { resetID += 1 }
                Button("모든 보정 초기화", systemImage: "arrow.counterclockwise", role: .destructive) { showReset = true }
            } label: { LibraryIcon(symbol: "ellipsis") }.accessibilityLabel("편집 메뉴")
            Button { showExport = true } label: { LibraryIcon(symbol: "square.and.arrow.up") }
                .foregroundStyle(LibraryStyle.blue).disabled(editor.document == nil || editor.isAnalyzing)
                .accessibilityLabel("편집한 사진 내보내기")
        }.foregroundStyle(.white).padding(.horizontal, 4).padding(.vertical, 4).background(LibraryStyle.bar)
    }
    private var statusBar: some View {
        HStack(spacing: 8) {
            if editor.isRendering { ProgressView().controlSize(.mini).tint(.gray) }
            Text(editor.document == nil ? (editor.loadFailed ? "불러오기 실패" : "불러오는 중") : (editor.isSaving ? "저장 중" : (editor.saved ? "저장됨" : "저장 필요")))
                .font(.system(size: 10)).foregroundStyle(LibraryStyle.secondary)
            Spacer()
            Text((editor.document?.raw != nil ? "RAW · " : "") + (editor.displayRecipe.enhancements.hdr ? "HDR · P3" : "SDR · P3")).font(.system(size: 9, design: .monospaced)).foregroundStyle(LibraryStyle.secondary)
            Button { editor.toggleComparison() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "rectangle.on.rectangle")
                    Text(editor.isComparing ? "보정 보기" : "원본 비교")
                }.font(.system(size: 11)).frame(minHeight: 44)
            }.disabled(editor.document == nil)
        }.padding(.horizontal, 16).frame(height: 32).background(.black)
    }
    private var toolBar: some View {
        HStack(spacing: 0) {
            modeButton("조절",symbol: "slider.horizontal.3",selected: tool.map { [.light,.color,.effects,.detail,.optics].contains($0) } ?? false) {
                editor.finishGesture(); tool = tool == .light ? nil : .light
            }
            modeButton("자르기",symbol: "crop.rotate",selected: tool == .crop) { editor.finishGesture(); tool = .crop }
            modeButton("도구",symbol: "square.grid.2x2",selected: tool.map { ![.light,.color,.effects,.detail,.optics,.crop].contains($0) } ?? false) { showTools = true }
        }.padding(.horizontal,30).padding(.top,3).background(.black)
    }
    private func modeButton(_ title: String,symbol: String,selected: Bool,action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20,weight: .regular))
                Text(title).font(.system(size: 10,weight: .medium))
            }.foregroundStyle(selected ? LibraryStyle.blue : LibraryStyle.secondary).frame(maxWidth: .infinity,minHeight: 52)
        }.accessibilityAddTraits(selected ? .isSelected : [])
    }

}

private struct ZoomablePhoto: UIViewRepresentable {
    let image: CGImage
    let resetID: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PhotoScrollView {
        let view = PhotoScrollView()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1
        view.maximumZoomScale = 5
        view.showsHorizontalScrollIndicator = false
        view.showsVerticalScrollIndicator = false
        view.bouncesZoom = true
        view.imageView.image = UIImage(cgImage: image)
        view.imageView.preferredImageDynamicRange = .high
        view.imageView.contentMode = .scaleAspectFit
        view.addSubview(view.imageView)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PhotoScrollView, context: Context) {
        view.imageView.image = UIImage(cgImage: image)
        if context.coordinator.resetID != resetID {
            view.setZoomScale(1, animated: false)
            view.setContentOffset(.zero, animated: false)
            context.coordinator.resetID = resetID
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var resetID = 0
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? PhotoScrollView)?.imageView }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? PhotoScrollView else { return }
            if view.zoomScale > 1 { view.setZoomScale(1, animated: !UIAccessibility.isReduceMotionEnabled) }
            else {
                let point = gesture.location(in: view.imageView)
                let size = CGSize(width: view.bounds.width / 2.5, height: view.bounds.height / 2.5)
                view.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                     width: size.width, height: size.height), animated: !UIAccessibility.isReduceMotionEnabled)
            }
        }
    }

    final class PhotoScrollView: UIScrollView {
        let imageView = UIImageView()
        private var previousSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != previousSize {
                zoomScale = 1
                imageView.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
                previousSize = bounds.size
            }
        }
    }
}
