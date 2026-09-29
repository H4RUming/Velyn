import SwiftUI
import UIKit

enum EditorTool: String, CaseIterable {
    case light = "밝기", color = "색상", curve = "커브", mix = "색상 믹서", effects = "효과", detail = "디테일", crop = "자르기", presets = "프리셋", grade = "그레이딩", masks = "마스크", retouch = "요소 지우기", optics = "광학·원근", versions = "버전"
    case raw = "RAW 현상"
    case blur = "렌즈 흐림", hdr = "HDR", profile = "프로파일·WB"
    var icon: String {
        switch self {
        case .raw: "camera.aperture"
        case .hdr: "sun.max.fill"
        case .profile: "paintpalette"
        case .blur: "camera.aperture"
        case .grade: "circle.hexagongrid"
        case .masks: "circle.dashed"
        case .retouch: "eraser.fill"
        case .optics: "viewfinder"
        case .versions: "clock.arrow.circlepath"
        case .light: "sun.max"
        case .color: "thermometer.medium"
        case .curve: "point.topleft.down.to.point.bottomright.curvepath"
        case .mix: "circle.lefthalf.filled"
        case .effects: "camera.filters"
        case .detail: "triangle"
        case .crop: "crop.rotate"
        case .presets: "square.stack.3d.up"
        }
    }
    var adjustments: [Adjustment] {
        switch self {
        case .light: [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]
        case .color: [.warmth, .tint, .vibrance, .saturation, .gamutExpansion]
        case .curve: []
        case .effects: [.texture, .clarity, .dehaze, .grain, .grainSize, .vignette, .vignetteFeather, .vignetteMidpoint]
        case .detail: [.sharpness, .sharpRadius, .sharpMasking, .noiseReduction, .noiseDetail, .colorNoiseReduction]
        case .crop: [.straighten, .cropScale, .cropX, .cropY]
        case .optics: [.perspectiveVertical, .perspectiveHorizontal, .lensDistortion, .defringe]
        default: []
        }
    }
}

struct EditorControls: View {
    let editor: EditorStore
    let tool: EditorTool
    @State private var band = 0
    @State private var selectedAdjustment: Adjustment = .straighten
    @State private var mixerParameter = 0
    @State private var presetName = ""
    @State private var showPresetName = false
    private let colors: [Color] = [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink]
    private let names = [L10n.tr("빨강"), L10n.tr("주황"), L10n.tr("노랑"), L10n.tr("초록"), L10n.tr("청록"), L10n.tr("파랑"), L10n.tr("보라"), L10n.tr("자홍")]

    var body: some View {
        ScrollView {
            VStack(spacing: tool == .crop ? 6 : 16) {
                if [.curve, .grade, .masks, .retouch, .versions, .blur].contains(tool) { AdvancedEditorControls(editor: editor, tool: tool) }
                if tool == .raw { RAWDevelopmentControls(editor: editor) }
                if tool == .hdr {
                    HDRExpansionControls(editor: editor)
                    Toggle(L10n.tr("HDR 편집"), isOn: Binding(get: { editor.recipe.enhancements.hdr }, set: { value in editor.mutate { $0.enhancements.hdr = value } }))
                }
                if tool == .profile {
                    HStack { Button(L10n.tr("자동 화이트밸런스")) { Task { await editor.autoWhiteBalance() } }; Spacer(); Button(L10n.tr("스포이트")) { editor.pickingWhiteBalance.toggle() } }.frame(minHeight: 44)
                    Picker(L10n.tr("프로파일"), selection: Binding(get: { editor.recipe.enhancements.profile }, set: { value in editor.mutate { $0.enhancements.profile = value } })) { ForEach(PhotoProfile.allCases, id: \.self) { Text(L10n.tr($0.rawValue)).tag($0) } }
                }
                if tool == .mix { colorMixer }
                if tool == .crop { cropOptions }
                if tool == .presets { presetList; PresetExchangeControls(editor: editor) }
                if let first = tool.adjustments.first {
                    let adjustment = tool.adjustments.contains(selectedAdjustment) ? selectedAdjustment : first
                    Picker(L10n.tr("조절 항목"),selection: $selectedAdjustment) {
                        ForEach(tool.adjustments,id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    AdjustmentSlider(title: adjustment.title,
                        value: Binding(get: { editor.recipe[adjustment] },set: { editor.set(adjustment,$0) }),
                        range: adjustment.range,step: adjustment.step,defaultValue: adjustment.defaultValue,
                        suffix: adjustment == .exposure ? " EV" : (adjustment == .straighten ? "°" : ""),commit: editor.finishGesture)
                }
                if tool == .profile {
                    Text(L10n.tr("색온도와 색조는 기본 현상을 기준으로 조절합니다."))
                        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                if tool == .detail {
                    Button(L10n.tr("원본 픽셀 확인")) { editor.pickingDetail.toggle() }
                    Text(L10n.tr("확인할 위치를 사진에서 선택하면 원본 해상도로 불러옵니다."))
                        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(.horizontal, 20).padding(.vertical, tool == .crop ? 8 : 16)
        }.background(LibraryStyle.bar)
    }

    private var colorMixer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { index in
                    Button { band = index } label: {
                        Circle().fill(colors[index]).frame(width: 22, height: 22)
                            .overlay { if index == band { Circle().stroke(.white, lineWidth: 2).padding(-4) } }
                            .frame(maxWidth: .infinity).frame(height: 44)
                    }.accessibilityLabel(names[index]).accessibilityAddTraits(index == band ? .isSelected : [])
                }
            }
            Picker(L10n.tr("조절 항목"),selection: $mixerParameter) { Text(L10n.tr("색조")).tag(0); Text(L10n.tr("채도")).tag(1); Text(L10n.tr("휘도")).tag(2) }.pickerStyle(.segmented)
            if mixerParameter == 0 { bandSlider(L10n.tr("색조"),key: \.hue) }
            else if mixerParameter == 1 { bandSlider(L10n.tr("채도"),key: \.saturation) }
            else { bandSlider(L10n.tr("휘도"),key: \.luminance) }
        }
    }
    private func bandSlider(_ title: String, key: WritableKeyPath<ColorBand, Double>) -> some View {
        AdjustmentSlider(title: "\(names[band]) · \(title)",
            value: Binding(get: { editor.recipe.colors[band][keyPath: key] }, set: { editor.setColor(band, key: key, value: $0) }),
            range: -100...100, step: 1, defaultValue: 0, commit: editor.finishGesture)
    }
    private var cropOptions: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CropAspect.allCases, id: \.self) { aspect in
                        Button { editor.changeGeometry { $0.aspect = aspect } } label: {
                            Text(L10n.tr(aspect.rawValue)).font(.caption.weight(.medium)).padding(.horizontal, 14).frame(height: 44)
                                .background(editor.recipe.aspect == aspect ? LibraryStyle.blue : LibraryStyle.raised,
                                            in: RoundedRectangle(cornerRadius: 5)).foregroundStyle(.white)
                        }
                    }
                }
            }
            HStack {
                Button { editor.changeGeometry { $0.quarterTurns = ($0.quarterTurns + 1) % 4 } } label: {
                    Label(L10n.tr("90° 회전"), systemImage: "rotate.right")
                }.frame(maxWidth: .infinity, minHeight: 44)
                Button { editor.changeGeometry { $0.flipHorizontal.toggle() } } label: {
                    Label(L10n.tr("좌우 반전"), systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }.frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(editor.recipe.flipHorizontal ? LibraryStyle.blue : .white)
            }.font(.caption)
        }
    }
    private var presetList: some View {
        VStack(spacing: 8) {
            ForEach(BuiltInPreset.allCases, id: \.self) { preset in
                Button { editor.applyPreset(preset.recipe) } label: {
                    HStack { Text(L10n.tr(preset.rawValue)); Spacer(); Image(systemName: "chevron.right").font(.caption2) }
                        .padding(.horizontal, 14).frame(minHeight: 46).background(LibraryStyle.raised)
                }.foregroundStyle(.white)
            }
            ForEach(editor.presets) { preset in
                Button { editor.applyPreset(preset.recipe) } label: {
                    HStack { Image(systemName: "bookmark"); Text(preset.name); Spacer() }.frame(minHeight: 44)
                }
            }
            Button { showPresetName = true } label: { Label(L10n.tr("현재 설정을 프리셋으로 저장"), systemImage: "plus").frame(minHeight: 44) }
        }.font(.subheadline)
            .alert(L10n.tr("프리셋 저장"), isPresented: $showPresetName) {
                TextField(L10n.tr("이름"), text: $presetName)
                Button(L10n.tr("취소"), role: .cancel) { }
                Button(L10n.tr("저장")) { Task { await editor.savePreset(name: presetName); presetName = "" } }
                    .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: { Text(L10n.tr("색과 톤 설정을 저장합니다. 자르기는 포함하지 않습니다.")) }
    }
}

struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    var suffix = ""
    let commit: () -> Void
    @State private var showValue = false
    @State private var text = ""
    private var display: String { String(format: step < 1 ? "%.2f" : "%.0f", value) + suffix }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Button { text = String(value); showValue = true } label: {
                    Text(display).font(.system(size: 12, design: .monospaced)).foregroundStyle(value == defaultValue ? LibraryStyle.secondary : .white)
                        .frame(minWidth: 50, minHeight: 44, alignment: .trailing)
                }.accessibilityLabel(L10n.format("%@ 수치 입력",title))
            }
            PrecisionSlider(value: $value, range: range, step: step, title: title, display: display, commit: commit)
                .frame(height: 32)
        }
        .alert(title, isPresented: $showValue) {
            TextField(L10n.tr("값"), text: $text).keyboardType(.numbersAndPunctuation)
            Button(L10n.tr("취소"), role: .cancel) { }
            Button(L10n.tr("적용")) {
                if let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite {
                    value = min(max(number, range.lowerBound), range.upperBound); commit()
                }
            }
            Button(L10n.tr("초기화")) { value = defaultValue; commit() }
        } message: { Text("\(range.lowerBound.formatted()) ~ \(range.upperBound.formatted())\(suffix)") }
    }
}

private enum BuiltInPreset: String, CaseIterable {
    case natural = "자연스럽게", warm = "따뜻한 톤", cool = "차가운 톤", mono = "흑백", matte = "매트"
    var recipe: EditRecipe {
        var recipe = EditRecipe()
        switch self {
        case .natural: recipe[.vibrance] = 15; recipe[.contrast] = 8; recipe[.shadows] = 12
        case .warm: recipe[.warmth] = 20; recipe[.vibrance] = 10; recipe[.highlights] = -15
        case .cool: recipe[.warmth] = -20; recipe[.contrast] = 12; recipe[.saturation] = -10
        case .mono: recipe[.saturation] = -100; recipe[.contrast] = 25; recipe[.blacks] = -15
        case .matte: recipe[.blacks] = 25; recipe[.highlights] = -25; recipe[.saturation] = -18; recipe[.warmth] = 8
        }
        return recipe
    }
}

private struct PrecisionSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let title: String
    let display: String
    let commit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIView(context: Context) -> ThinSlider {
        let slider = ThinSlider()
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = UIColor(white: 0.28, alpha: 1)
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            UIColor.white.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 5, y: 5, width: 14, height: 14))
        }
        slider.setThumbImage(thumb, for: .normal)
        slider.setThumbImage(thumb, for: .highlighted)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.finished), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }
    func updateUIView(_ slider: ThinSlider, context: Context) {
        context.coordinator.parent = self
        slider.isEnabled = context.environment.isEnabled
        slider.alpha = context.environment.isEnabled ? 1 : 0.35
        slider.minimumValue = Float(range.lowerBound); slider.maximumValue = Float(range.upperBound)
        if !slider.isTracking { slider.value = Float(value) }
        slider.accessibilityLabel = title
        slider.accessibilityValue = display
    }
    final class ThinSlider: UISlider {
        override func trackRect(forBounds bounds: CGRect) -> CGRect {
            let rect = super.trackRect(forBounds: bounds)
            return CGRect(x: rect.minX, y: bounds.midY - 1, width: rect.width, height: 2)
        }
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.insetBy(dx: 0, dy: -6).contains(point)
        }
    }
    final class Coordinator: NSObject {
        var parent: PrecisionSlider
        init(parent: PrecisionSlider) { self.parent = parent }
        @objc func changed(_ sender: UISlider) {
            parent.value = min(max((Double(sender.value) / parent.step).rounded() * parent.step, parent.range.lowerBound), parent.range.upperBound)
            if !sender.isTracking { parent.commit() }
        }
        @objc func finished() { parent.commit() }
    }
}
