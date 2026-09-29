import SwiftUI
import UniformTypeIdentifiers

struct AdvancedEditorControls: View {
    let editor: EditorStore
    let tool: EditorTool
    @State private var channel: CurveChannel = .rgb
    @State private var tone = 0
    @State private var depthParameter = 0
    @State private var gradeParameter = 0
    @State private var maskParameter = "노출"
    @State private var versionName = ""
    private var mask: LocalMask? { editor.recipe.enhancements.masks.first { $0.id == editor.activeMask } }

    var body: some View {
        VStack(spacing: 14) {
            switch tool {
            case .blur:
                if editor.isAnalyzing { HStack { ProgressView(); Text("기기에서 깊이 분석 중"); Button("취소") { editor.cancelAnalysis() } } }
                else { Button(editor.recipe.enhancements.depth == nil ? "사진 깊이 분석" : "깊이 다시 분석") { Task { await editor.estimateDepth() } }.frame(minHeight: 44) }
                if let depth = editor.recipe.enhancements.depth {
                    Button(editor.pickingDepth ? "초점 지정 취소" : "사진에서 초점 선택") { editor.chooseDepthFocus() }
                    if editor.pickingDepth { Text("선명하게 유지할 피사체를 누르세요. 원본 구도에서 선택합니다.").font(.caption) }
                    Picker("조절 항목",selection: $depthParameter) { Text("흐림 강도").tag(0); Text("초점 거리").tag(1); Text("선명한 범위").tag(2) }.pickerStyle(.segmented)
                    if depthParameter == 0 { depthSlider("흐림 강도",key: \.amount,value: depth.amount,range: 0...100,defaultValue: 30) }
                    else if depthParameter == 1 { depthSlider("초점 거리 · 0 먼 곳 / 1 가까운 곳",key: \.focus,value: depth.focus,range: 0...1,defaultValue: 0.75) }
                    else { depthSlider("선명하게 유지할 범위",key: \.range,value: depth.range,range: 0.01...1,defaultValue: 0.15) }
                    Button("깊이 효과 제거") { editor.mutate { $0.enhancements.depth = nil } }
                }
                Text("앱에 포함된 모델로 사진의 상대적인 깊이를 추정합니다. 머리카락이나 반사면의 경계는 부정확할 수 있습니다.").font(.caption2).foregroundStyle(.secondary)
            case .curve:
                Picker("채널", selection: $channel) { ForEach(CurveChannel.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                PointCurveEditor(editor: editor, channel: channel).frame(height: 130)
                HStack { Text("터치해 점 추가 · 끌어 조절 · 두 번 탭해 삭제").font(.caption2).foregroundStyle(.secondary); Spacer(); Button("초기화") { editor.mutate { $0.enhancements.curves[channel.rawValue] = nil } } }
            case .grade:
                Picker("밝기 영역", selection: $tone) { Text("그림자").tag(0); Text("중간톤").tag(1); Text("밝은 부분").tag(2) }.pickerStyle(.segmented)
                Picker("조절 항목",selection: $gradeParameter) { Text("색상").tag(0); Text("채도").tag(1); Text("휘도").tag(2) }.pickerStyle(.segmented)
                if gradeParameter == 0 { gradeSlider("색상", key: \.hue, range: 0...360) }
                else if gradeParameter == 1 { gradeSlider("채도", key: \.saturation, range: 0...100) }
                else { gradeSlider("휘도", key: \.luminance, range: -100...100) }
            case .masks:
                HStack {
                    Menu { ForEach(MaskKind.allCases, id: \.self) { kind in Button(kind.rawValue) { Task { await editor.addMask(kind) } } } } label: { Label("마스크 추가", systemImage: "plus") }
                    Spacer()
                    if editor.isAnalyzing { ProgressView(); Button("취소") { editor.cancelAnalysis() } }
                    if mask != nil { Button("삭제", role: .destructive) { editor.removeMask() } }
                }.frame(minHeight: 44)
                if editor.pickingObject { Text("하늘이나 물체 등 선택할 부분을 사진에서 누르세요.").font(.caption) }
                if !editor.recipe.enhancements.masks.isEmpty {
                    Picker("마스크", selection: Binding(get: { editor.activeMask ?? editor.recipe.enhancements.masks[0].id }, set: { editor.activeMask = $0 })) {
                        ForEach(editor.recipe.enhancements.masks) { Text($0.name).tag($0.id) }
                    }
                }
                if let mask {
                    maskAdjustment(mask)
                    DisclosureGroup("선택 영역 옵션") {
                    Toggle("선택 영역 표시",isOn: Binding(get: { editor.showMaskOverlay },set: { editor.showMaskOverlay = $0 }))
                    if mask.kind == .object { Toggle("탭한 부분 제외",isOn: Binding(get: { editor.excludeFromMask },set: { editor.excludeFromMask = $0 })); Text("다시 탭해 선택 영역을 보완할 수 있습니다.").font(.caption2) }
                    HStack {
                        Toggle("켜기", isOn: Binding(get: { mask.enabled }, set: { value in editor.editMask { $0.enabled = value } }))
                        Toggle("반전", isOn: Binding(get: { mask.inverted }, set: { value in editor.editMask { $0.inverted = value } }))
                    }.font(.caption)
                    if mask.kind == .brush { Toggle("브러시로 영역 빼기",isOn: Binding(get: { editor.erasingBrush },set: { editor.erasingBrush = $0 })) }
                    Text(mask.kind == .brush ? "여러 번 그어 영역을 더하거나 뺄 수 있습니다. 실행 취소로 마지막 획을 되돌립니다." : "영역은 원본 구도에서 지정합니다. 선형·방사형은 사진 위를 드래그하세요.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                DisclosureGroup("선택 모델") { Text("Apple의 선택 모델만 준비합니다. 사진은 전송하지 않으며 준비 후 기기에서 분석합니다.").font(.caption); Button("선택 모델 준비") { Task { await editor.prepareSelectionAssets() } }.disabled(editor.isAnalyzing) }
            case .retouch: RemovalControls(editor: editor)
            case .versions:
                HStack { TextField("버전 이름", text: $versionName); Button("저장") { Task { await editor.saveVersion(name: versionName); versionName = "" } }.disabled(versionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                ForEach(editor.versions) { version in Button { editor.restoreVersion(version) } label: { HStack { Text(version.name); Spacer(); Text(version.createdAt, style: .date).font(.caption).foregroundStyle(.secondary) }.frame(minHeight: 44) } }
            default: EmptyView()
            }
        }
    }
    @ViewBuilder private func maskAdjustment(_ mask: LocalMask) -> some View {
        let base = ["노출","대비","채도","색온도","텍스처","경계 부드러움","강도"]
        let parameters = base + (mask.kind == .brush ? ["브러시 크기"] : [])
            + ([MaskKind.luminance,.color].contains(mask.kind) ? ["범위 시작","범위 끝"] : [])
            + (mask.kind == .color ? ["대상 색상"] : []) + (mask.kind == .subject ? ["배경 흐림"] : [])
        let selected = parameters.contains(maskParameter) ? maskParameter : "노출"
        Picker("조절 항목",selection: Binding(get: { selected },set: { editor.finishGesture(); maskParameter = $0 })) {
            ForEach(parameters,id: \.self) { Text($0).tag($0) }
        }
        switch selected {
        case "대비": maskSlider("대비",key: \.contrast,range: -100...100)
        case "채도": maskSlider("채도",key: \.saturation,range: -100...100)
        case "색온도": maskSlider("색온도",key: \.warmth,range: -100...100)
        case "텍스처": maskSlider("텍스처",key: \.texture,range: -100...100)
        case "경계 부드러움": maskSlider("경계 부드러움",key: \.feather,range: 0...1,step: 0.01)
        case "강도": maskSlider("강도",key: \.opacity,range: 0...1,step: 0.01)
        case "브러시 크기": maskSlider("브러시 크기",key: \.radius,range: 0.005...0.3,step: 0.005)
        case "범위 시작": maskSlider("범위 시작",key: \.lower,range: 0...mask.upper,step: 0.01)
        case "범위 끝": maskSlider("범위 끝",key: \.upper,range: mask.lower...1,step: 0.01)
        case "대상 색상": maskSlider("대상 색상",key: \.hue,range: 0...360)
        case "배경 흐림": AdjustmentSlider(title: "배경 흐림",value: Binding(get: { editor.recipe[.lensBlur] },set: { editor.set(.lensBlur,$0) }),range: 0...100,step: 1,defaultValue: 0,commit: editor.finishGesture)
        default: maskSlider("노출",key: \.exposure,range: -5...5,step: 0.05)
        }
    }
    private func depthSlider(_ title: String,key: WritableKeyPath<DepthEffect,Double>,value: Double,range: ClosedRange<Double>,defaultValue: Double) -> some View {
        AdjustmentSlider(title: title,value: Binding(get: { value },set: { value in editor.mutate({ $0.enhancements.depth?[keyPath: key] = value },commit: false) }),range: range,step: range.upperBound > 1 ? 1 : 0.01,defaultValue: defaultValue,commit: editor.finishGesture)
    }
    private func gradeSlider(_ title: String, key: WritableKeyPath<GradeTone, Double>, range: ClosedRange<Double>) -> some View {
        AdjustmentSlider(title: title, value: Binding(get: { editor.recipe.enhancements.grading[tone][keyPath: key] }, set: { value in editor.mutate({ $0.enhancements.grading[tone][keyPath: key] = value }, commit: false) }), range: range, step: 1, defaultValue: 0, commit: editor.finishGesture)
    }
    private func maskSlider(_ title: String, key: WritableKeyPath<LocalMask, Double>, range: ClosedRange<Double>, step: Double = 1) -> some View {
        AdjustmentSlider(title: title, value: Binding(get: { mask?[keyPath: key] ?? range.lowerBound }, set: { value in editor.editMask({ $0[keyPath: key] = value }, commit: false) }), range: range, step: step, defaultValue: LocalMask(kind: .radial)[keyPath: key], commit: editor.finishGesture)
    }
}

private struct PointCurveEditor: View {
    let editor: EditorStore
    let channel: CurveChannel
    @State private var moving: Int?
    var curve: PointCurve { editor.recipe.enhancements.curves[channel.rawValue] ?? PointCurve() }
    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                for i in 1...3 {
                    var grid = Path(); let t = CGFloat(i)/4
                    grid.move(to: .init(x: t*size.width,y: 0)); grid.addLine(to: .init(x: t*size.width,y: size.height))
                    grid.move(to: .init(x: 0,y: t*size.height)); grid.addLine(to: .init(x: size.width,y: t*size.height))
                    context.stroke(grid, with: .color(.white.opacity(0.15)),lineWidth: 1)
                }
                let points = curve.points.map { CGPoint(x: $0.x*size.width,y: (1-$0.y)*size.height) }
                var line = Path(); line.addLines(points)
                let color: Color = channel == .red ? .red : (channel == .green ? .green : (channel == .blue ? .blue : .white))
                context.stroke(line,with: .color(color),lineWidth: 2)
                for point in points { context.fill(Path(ellipseIn: CGRect(x: point.x-5,y: point.y-5,width: 10,height: 10)),with: .color(color)) }
            }.background(.black.opacity(0.4)).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    var updated = curve
                    let p = PhotoPoint(min(1,max(0,value.location.x/geo.size.width)),min(1,max(0,1-value.location.y/geo.size.height)))
                    if moving == nil {
                        if let index = updated.points.indices.min(by: { abs(updated.points[$0].x-p.x) < abs(updated.points[$1].x-p.x) }), abs(updated.points[index].x-p.x) < 0.06 { moving = index }
                        else if updated.points.count < 16 { updated.points.append(p); updated.points.sort { $0.x < $1.x }; moving = updated.points.firstIndex(of: p) }
                    }
                    if let index = moving, updated.points.indices.contains(index) {
                        let x = index == 0 ? 0 : (index == updated.points.count-1 ? 1 : min(updated.points[index+1].x-0.005,max(updated.points[index-1].x+0.005,p.x)))
                        updated.points[index] = PhotoPoint(x,p.y)
                        let next = updated
                        editor.mutate({ $0.enhancements.curves[channel.rawValue] = next },commit: false)
                    }
                }.onEnded { _ in moving = nil; editor.finishGesture() })
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { event in
                    var value = curve
                    let x = event.location.x/geo.size.width
                    if let index = value.points.indices.min(by: { abs(value.points[$0].x-x) < abs(value.points[$1].x-x) }), index > 0 && index < value.points.count-1 { value.points.remove(at: index); let next = value; editor.mutate { $0.enhancements.curves[channel.rawValue] = next } }
                })
        }
    }
}

struct PresetExchangeControls: View {
    let editor: EditorStore
    @State private var importing = false
    @State private var sharing: ShareableFiles?
    var body: some View {
        VStack {
            HStack { Button("프리셋 가져오기") { importing = true }; Spacer(); Button("프리셋 내보내기") { Task { if let url = await editor.exportPreset() { sharing = ShareableFiles(urls: [url]) } } } }.frame(minHeight: 44)
            Text("Velyn 프리셋 파일 지원 · Lightroom XMP는 호환되지 않습니다.").font(.caption2).foregroundStyle(.secondary)
            Menu("사용자 프리셋 관리") { ForEach(editor.presets) { preset in Button("\(preset.name) 삭제",role: .destructive) { Task { await editor.deletePreset(preset.id) } } } }
        }.fileImporter(isPresented: $importing,allowedContentTypes: [.data]) { result in if case .success(let url) = result { Task { await editor.importPreset(url) } } }
            .sheet(item: $sharing,onDismiss: { sharing = nil }) { item in ActivityShareView(urls: item.urls) }
    }
}
struct ShareableFiles: Identifiable { let id = UUID(); let urls: [URL] }
struct ActivityShareView: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: urls,applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController,context: Context) {}
}
