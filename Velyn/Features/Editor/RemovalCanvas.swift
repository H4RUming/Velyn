import SwiftUI
import UIKit

struct RemovalControls: View {
    let editor: EditorStore
    private var mode: Binding<Int> { Binding(get: { editor.removalNavigating ? 2 : (editor.removalErasing ? 1 : 0) },set: {
        editor.removalNavigating = $0 == 2; editor.removalErasing = $0 == 1
    }) }
    var body: some View {
        VStack(spacing: 8) {
            Picker(L10n.tr("선택 도구"),selection: mode) {
                Text(L10n.tr("칠하기")).tag(0); Text(L10n.tr("선택 지우기")).tag(1); Text(L10n.tr("이동")).tag(2)
            }.pickerStyle(.segmented).disabled(editor.isAnalyzing)
            HStack {
                Text(L10n.tr("브러시 크기")).font(.caption)
                Slider(value: Binding(get: { editor.removalBrushRadius },set: { editor.removalBrushRadius = $0 }),in: 0.005...0.1)
                    .accessibilityLabel(L10n.tr("제거 영역 브러시 크기"))
            }.frame(height: 36).disabled(editor.isAnalyzing || editor.removalNavigating)
            HStack(spacing: 16) {
                Button { editor.removalSelection.undo() } label: { Image(systemName: "arrow.uturn.backward") }.accessibilityLabel(L10n.tr("마지막 선택 획 취소"))
                    .disabled(editor.removalSelection.strokes.isEmpty || editor.isAnalyzing)
                Button(L10n.tr("비우기")) { editor.removalSelection.clear() }.disabled(editor.removalSelection.strokes.isEmpty || editor.isAnalyzing)
                Button(L10n.tr("화면 맞춤")) { editor.removalCanvasReset += 1 }
                Spacer(minLength: 0)
                if editor.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Button(L10n.tr("취소")) { editor.cancelAnalysis() }
                } else {
                    Button(L10n.tr("실행")) { Task { await editor.runRemoval() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!editor.removalSelection.hasPaint || editor.isRendering || editor.isComparing)
                }
            }.font(.subheadline).frame(minHeight: 44)
            Text(editor.isAnalyzing ? L10n.tr("기기에서 지운 자리를 채우는 중…") : L10n.tr("두 손가락으로 확대·이동 · 칠한 영역만 실행\n원본 구도에서 선택 · 결과는 상단 실행 취소로 복원"))
                .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity,alignment: .leading)
        }
    }
}

/// Photo and brush overlay share one zoomed view. Touch locations are converted into that
/// view before normalization, so zoom/scroll/letterboxing never enter the saved coordinates.
struct RemovalCanvas: UIViewRepresentable {
    let editor: EditorStore
    let image: CGImage
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> RemovalScrollView {
        let view = RemovalScrollView()
        view.delegate = context.coordinator
        context.coordinator.view = view
        let draw = UIPanGestureRecognizer(target: context.coordinator,action: #selector(Coordinator.draw(_:)))
        draw.minimumNumberOfTouches = 1; draw.maximumNumberOfTouches = 1; draw.delegate = context.coordinator
        view.surface.addGestureRecognizer(draw); context.coordinator.drawGesture = draw
        let tap = UITapGestureRecognizer(target: context.coordinator,action: #selector(Coordinator.dot(_:)))
        tap.numberOfTouchesRequired = 1; tap.require(toFail: draw)
        view.surface.addGestureRecognizer(tap); context.coordinator.tapGesture = tap
        return view
    }
    func updateUIView(_ view: RemovalScrollView,context: Context) {
        let c = context.coordinator; c.parent = self
        if c.lastImage !== image { view.photo.image = UIImage(cgImage: image); c.lastImage = image; view.setNeedsLayout() }
        view.overlay.strokes = editor.isComparing ? [] : editor.removalSelection.strokes
        view.overlay.isHidden = editor.isComparing
        let enabled = !editor.isAnalyzing && !editor.isComparing && !editor.isRendering && !editor.removalNavigating
        c.drawGesture?.isEnabled = enabled; c.tapGesture?.isEnabled = enabled
        view.panGestureRecognizer.minimumNumberOfTouches = editor.removalNavigating ? 1 : 2
        if c.resetID != editor.removalCanvasReset {
            c.resetID = editor.removalCanvasReset; view.setZoomScale(1,animated: false); view.centerContent()
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: RemovalCanvas
        weak var view: RemovalScrollView?
        var drawGesture: UIPanGestureRecognizer?, tapGesture: UITapGestureRecognizer?
        var lastImage: CGImage?
        var resetID = 0
        private var points: [PhotoPoint] = []
        private var radius = 0.025
        private var erasing = false
        init(_ parent: RemovalCanvas) { self.parent = parent }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view?.surface }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { view?.centerContent() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
        private func point(_ gesture: UIGestureRecognizer) -> PhotoPoint? {
            guard let surface = view?.surface,surface.bounds.width > 0,surface.bounds.height > 0 else { return nil }
            let p = gesture.location(in: surface)
            guard surface.bounds.contains(p) else { return nil }
            return PhotoPoint(p.x/surface.bounds.width,p.y/surface.bounds.height)
        }
        @objc func draw(_ gesture: UIPanGestureRecognizer) {
            guard let view else { return }
            if gesture.state == .began {
                points = []; radius = max(0.0005,parent.editor.removalBrushRadius/Double(view.zoomScale)); erasing = parent.editor.removalErasing
            }
            if gesture.state == .began || gesture.state == .changed || gesture.state == .ended {
                if let p = point(gesture), points.count < 2000 {
                    if let last = points.last {
                        if hypot(p.x-last.x,p.y-last.y) > 0.0005 { points.append(p) }
                    } else { points.append(p) }
                }
                view.overlay.pending = points.isEmpty ? nil : MaskStroke(points: points,radius: radius,feather: 0,erasing: erasing)
            }
            if gesture.state == .ended {
                if let stroke = view.overlay.pending { parent.editor.appendRemovalStroke(stroke) }
                points = []; view.overlay.pending = nil
            } else if gesture.state == .cancelled || gesture.state == .failed {
                points = []; view.overlay.pending = nil
            }
        }
        @objc func dot(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended,let p = point(gesture),let view else { return }
            parent.editor.appendRemovalStroke(MaskStroke(points: [p],radius: max(0.0005,parent.editor.removalBrushRadius/Double(view.zoomScale)),feather: 0,erasing: parent.editor.removalErasing))
        }
    }
}

final class RemovalScrollView: UIScrollView {
    let surface = UIView(), photo = UIImageView(), overlay = RemovalOverlay()
    private var layoutSize = CGSize.zero
    private var imageRatio = 0.0
    #if DEBUG && targetEnvironment(simulator)
    private var smokeZoomApplied = false
    #endif
    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1; maximumZoomScale = 8; bouncesZoom = true
        showsHorizontalScrollIndicator = false; showsVerticalScrollIndicator = false
        backgroundColor = .black
        photo.contentMode = .scaleToFill; photo.preferredImageDynamicRange = .high
        surface.addSubview(photo); surface.addSubview(overlay); addSubview(surface)
        overlay.isUserInteractionEnabled = false; overlay.alpha = 0.4
        surface.clipsToBounds = true
        accessibilityLabel = L10n.tr("제거 영역 선택. 한 손가락으로 칠하고 두 손가락으로 확대하거나 이동하세요.")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image = photo.image,bounds.width > 0,bounds.height > 0 else { return }
        let ratio = image.size.width/image.size.height
        if layoutSize != bounds.size || abs(imageRatio-ratio) > 0.001 {
            layoutSize = bounds.size; imageRatio = ratio
            setZoomScale(1,animated: false)
            let scale = min(bounds.width/image.size.width,bounds.height/image.size.height)
            let size = CGSize(width: image.size.width*scale,height: image.size.height*scale)
            surface.frame = CGRect(origin: .zero,size: size)
            photo.frame = surface.bounds; overlay.frame = surface.bounds
            contentSize = size; contentOffset = .zero
        }
        centerContent()
        #if DEBUG && targetEnvironment(simulator)
        if !smokeZoomApplied,ProcessInfo.processInfo.arguments.contains("--editor-smoke-test"),
           ProcessInfo.processInfo.arguments.contains("--editor-smoke-removal-zoom") {
            smokeZoomApplied = true
            setZoomScale(3,animated: false)
            contentOffset = CGPoint(x: max(0,surface.bounds.width*3*0.36-bounds.width/2),y: max(0,surface.bounds.height*3*0.32-bounds.height/2))
        }
        #endif
    }
    func centerContent() {
        surface.center = CGPoint(x: max(bounds.width,contentSize.width)/2,y: max(bounds.height,contentSize.height)/2)
    }
}

final class RemovalOverlay: UIView {
    var strokes: [MaskStroke] = [] { didSet { setNeedsDisplay() } }
    var pending: MaskStroke? { didSet { setNeedsDisplay() } }
    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; backgroundColor = .clear; contentMode = .redraw }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.clear(bounds)
        for stroke in strokes + (pending.map { [$0] } ?? []) {
            guard let first = stroke.points.first else { continue }
            context.setBlendMode(stroke.erasing ? .clear : .normal)
            context.setFillColor(UIColor.systemRed.cgColor); context.setStrokeColor(UIColor.systemRed.cgColor)
            let radius = stroke.radius*max(bounds.width,bounds.height)
            let start = CGPoint(x: first.x*bounds.width,y: first.y*bounds.height)
            context.setLineWidth(radius*2); context.setLineCap(.round); context.setLineJoin(.round)
            context.move(to: start)
            for point in stroke.points.dropFirst() { context.addLine(to: CGPoint(x: point.x*bounds.width,y: point.y*bounds.height)) }
            context.strokePath()
            context.fillEllipse(in: CGRect(x: start.x-radius,y: start.y-radius,width: radius*2,height: radius*2))
        }
    }
}
