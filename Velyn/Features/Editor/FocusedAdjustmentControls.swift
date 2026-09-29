import SwiftUI

/// A single active parameter keeps the photo visible while adjusting it.
struct FocusedAdjustmentControls: View {
    let editor: EditorStore
    @State private var selected: Adjustment
    static let adjustments: [Adjustment] = [.exposure,.highlights,.shadows,.contrast,.whites,.blacks,
        .saturation,.vibrance,.gamutExpansion,.warmth,.tint,.sharpness,.clarity,.texture,.dehaze,.noiseReduction,
        .colorNoiseReduction,.noiseDetail,.sharpRadius,.sharpMasking,.vignette,.vignetteFeather,
        .vignetteMidpoint,.grain,.grainSize,.perspectiveVertical,.perspectiveHorizontal,.lensDistortion,.defringe]
    init(editor: EditorStore, initial: Adjustment = .exposure) {
        self.editor = editor
        var value = initial
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--editor-smoke-test"), ProcessInfo.processInfo.arguments.contains("--editor-smoke-gamut") { value = .gamutExpansion }
        #endif
        _selected = State(initialValue: value)
    }
    var body: some View {
        VStack(spacing: 2) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal,showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button { editor.finishGesture(); Task { await editor.autoTone() } } label: {
                            parameterIcon(L10n.tr("자동"),symbol: "wand.and.stars",active: false,modified: false)
                        }.buttonStyle(.plain).accessibilityLabel(L10n.tr("자동 톤 보정"))
                        ForEach(Self.adjustments,id: \.self) { item in
                            Button {
                                editor.finishGesture(); selected = item
                                withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(item,anchor: .center) }
                            } label: {
                                parameterIcon(item.title,symbol: item.symbol,active: selected == item,modified: editor.recipe[item] != item.defaultValue)
                            }.buttonStyle(.plain).id(item).accessibilityAddTraits(selected == item ? .isSelected : [])
                        }
                    }.padding(.horizontal,16)
                }.onAppear { proxy.scrollTo(selected,anchor: .center) }
            }.frame(height: 84)
            AdjustmentSlider(title: selected == .gamutExpansion ? L10n.tr("색역 확장 · P3") : selected.title,value: Binding(get: { editor.recipe[selected] },set: { editor.set(selected,$0) }),
                range: selected.range,step: selected.step,defaultValue: selected.defaultValue,
                suffix: selected == .exposure ? " EV" : (selected == .gamutExpansion ? "%" : ""),commit: editor.finishGesture)
                .padding(.horizontal,24).id(selected)
        }.padding(.top,5).padding(.bottom,10).background(Color.black)
    }
    private func parameterIcon(_ title: String,symbol: String,active: Bool,modified: Bool) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20,weight: .regular))
                .frame(width: 44,height: 44)
                .background(active ? LibraryStyle.blue : Color.white.opacity(0.08),in: Circle())
                .overlay { if modified && !active { Circle().strokeBorder(LibraryStyle.blue,lineWidth: 1.5) } }
            Text(title).font(.system(size: 10,weight: active ? .semibold : .regular)).lineLimit(1)
        }.foregroundStyle(active ? Color.white : LibraryStyle.secondary).frame(width: 62,height: 78)
    }
}

private extension Adjustment {
    var symbol: String {
        switch self {
        case .gamutExpansion: "paintpalette.fill"
        case .exposure: "plusminus.circle"
        case .highlights: "sun.max"
        case .shadows: "sun.min"
        case .contrast: "circle.lefthalf.filled"
        case .whites: "circle"
        case .blacks: "circle.fill"
        case .saturation: "drop.fill"
        case .vibrance: "drop.halffull"
        case .warmth: "thermometer.medium"
        case .tint: "paintpalette"
        case .sharpness: "triangle"
        case .clarity: "hexagon"
        case .texture: "square.3.layers.3d"
        case .dehaze: "cloud.fog"
        case .noiseReduction: "circle.dotted"
        case .colorNoiseReduction: "circle.hexagongrid"
        case .noiseDetail: "sparkle.magnifyingglass"
        case .sharpRadius: "smallcircle.filled.circle"
        case .sharpMasking: "viewfinder.circle"
        case .vignette: "circle.dashed.inset.filled"
        case .vignetteFeather: "circle.dashed"
        case .vignetteMidpoint: "scope"
        case .grain: "square.dotted"
        case .grainSize: "circle.grid.3x3"
        case .perspectiveVertical: "trapezoid.and.line.vertical"
        case .perspectiveHorizontal: "trapezoid.and.line.horizontal"
        case .lensDistortion: "camera.aperture"
        case .defringe: "circle.lefthalf.striped.horizontal"
        default: "slider.horizontal.3"
        }
    }
}

struct EditorToolSheet: View {
    var hasRAW = false
    let select: (EditorTool) -> Void
    @Environment(\.dismiss) private var dismiss
    private let tools: [EditorTool] = [.raw,.hdr,.profile,.mix,.curve,.grade,.masks,.retouch,.blur,.presets,.versions]
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible())],spacing: 12) {
                    ForEach(tools.filter { $0 != .raw || hasRAW },id: \.self) { tool in
                        Button { select(tool); dismiss() } label: {
                            HStack(spacing: 12) {
                                Image(systemName: tool.icon).font(.title3).frame(width: 28)
                                Text(L10n.tr(tool.rawValue)).font(.subheadline.weight(.medium))
                                Spacer(minLength: 0)
                            }.foregroundStyle(.white).padding(16).frame(height: 70)
                                .background(.white.opacity(0.06),in: RoundedRectangle(cornerRadius: 14))
                        }.buttonStyle(.plain)
                    }
                }.padding(16)
            }.background(LibraryStyle.background)
                .navigationTitle(L10n.tr("편집 도구")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("완료")) { dismiss() } } }
        }.preferredColorScheme(.dark).tint(LibraryStyle.blue)
            .presentationDetents([.medium,.large]).presentationDragIndicator(.visible)
    }
}
