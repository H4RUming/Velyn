import SwiftUI

struct RAWDevelopmentControls: View {
    let editor: EditorStore
    @State private var selected: RAWParameter = .temperature
    var body: some View {
        if let controls = editor.rawControls {
            VStack(spacing: 4) {
                HStack {
                    Picker(L10n.tr("RAW 현상 항목"),selection: $selected) {
                        ForEach(controls.parameters,id: \.self) { Text($0.title).tag($0) }
                    }.pickerStyle(.menu)
                    Spacer()
                    Button(L10n.tr("촬영 시 설정")) { editor.resetRAW() }.font(.caption)
                        .disabled(editor.recipe.rawAdjustments == nil)
                }.frame(minHeight: 36)
                if let initial = controls.defaults[selected] {
                    let value = Binding(get: { editor.recipe.rawAdjustments?[selected] ?? initial },set: { editor.setRAW(selected,$0) })
                    if selected.isToggle {
                        Toggle(selected.title,isOn: Binding(get: { value.wrappedValue == 1 },set: { value.wrappedValue = $0 ? 1 : 0; editor.finishGesture() }))
                            .frame(height: 76)
                    } else {
                        AdjustmentSlider(title: selected.title,value: value,range: selected.range,step: selected.step,
                            defaultValue: initial,suffix: selected == .temperature ? " K" : (selected == .tint ? "" : "%"),commit: editor.finishGesture)
                    }
                }
                Text(explanation).font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity,alignment: .leading)
            }
        }
    }
    private var explanation: String {
        switch selected {
        case .temperature,.tint: L10n.tr("RAW 현상 단계에서 흰색 기준을 조절합니다. 촬영 시 설정으로 되돌릴 수 있습니다.")
        case .toneCurve: L10n.tr("현상 톤의 강도입니다. 낮추면 대비를 줄여 밝은 영역과 어두운 영역을 직접 다듬기 쉽습니다.")
        case .shadowBoost: L10n.tr("현상 단계의 그림자 밝기입니다. 현상 톤 커브가 0이면 적용되지 않습니다.")
        case .highlightRecovery: L10n.tr("디코더의 밝은 영역 복구를 사용합니다. 촬영 때 완전히 소실된 정보는 복원할 수 없습니다.")
        case .lensCorrection: L10n.tr("이 RAW의 디코더가 제공하는 렌즈 보정을 적용합니다.")
        default: L10n.tr("이 사진의 RAW 디코더가 지원하는 항목입니다. 원본 픽셀 확인에서 세부 결과를 비교하세요.")
        }
    }
}
