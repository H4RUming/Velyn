import SwiftUI

struct HDRExpansionControls: View {
    let editor: EditorStore
    @State private var parameter = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editor.recipe.enhancements.hdr {
                Button(editor.previewSDR ? L10n.tr("HDR 보기") : L10n.tr("SDR로 비교")) { editor.previewSDR.toggle() }
                    .font(.caption).frame(minHeight: 36)
                if editor.previewSDR { Text(L10n.tr("SDR 비교 중 · 저장 설정은 유지됩니다")).font(.caption2).foregroundStyle(.secondary) }
            }
            if editor.sourceDynamicRange == .sdr {
                HStack {
                    Button(editor.recipe.enhancements.hdrExpansion == nil ? L10n.tr("HDR 밝기 지도 만들기") : L10n.tr("밝기 지도 다시 예측")) {
                        Task { await editor.estimateHDRExpansion() }
                    }.disabled(editor.isAnalyzing || editor.isExporting)
                    Spacer()
                    if editor.isAnalyzing {
                        ProgressView().controlSize(.small)
                        Button(L10n.tr("취소")) { editor.cancelAnalysis() }
                    }
                }.frame(minHeight: 44)
                if editor.recipe.enhancements.hdrExpansion != nil {
                    Picker(L10n.tr("조절 항목"),selection: $parameter) { Text(L10n.tr("확장 강도")).tag(0); Text(L10n.tr("최대 밝기")).tag(1) }.pickerStyle(.segmented)
                    if parameter == 0 { AdjustmentSlider(title: L10n.tr("HDR 확장 강도"), value: Binding(
                        get: { (editor.recipe.enhancements.hdrExpansion?.strength ?? 0.75)*100 },
                        set: { value in editor.mutate({ $0.enhancements.hdrExpansion?.strength = value/100 }, commit: false) }),
                        range: 0...100, step: 1, defaultValue: 75, suffix: "%", commit: editor.finishGesture) }
                    else { AdjustmentSlider(title: L10n.tr("최대 밝기 배율"), value: Binding(
                        get: { exp2(editor.recipe.enhancements.hdrExpansion?.maximumBoostEV ?? 2) },
                        set: { value in editor.mutate({ $0.enhancements.hdrExpansion?.maximumBoostEV = log2(value) }, commit: false) }),
                        range: 1...5, step: 0.1, defaultValue: 4, suffix: "×", commit: editor.finishGesture) }
                    Toggle(L10n.tr("중간톤 보호"),isOn: Binding(get: { editor.recipe.enhancements.hdrExpansion?.protectMidtones == true },set: { value in editor.mutate { $0.enhancements.hdrExpansion?.protectMidtones = value } })).font(.caption)
                    Text(L10n.tr("어두운 부분과 중간 밝기는 유지하고 밝은 영역을 중심으로 확장합니다.")).font(.caption2).foregroundStyle(.secondary)
                    Button(L10n.tr("밝기 지도 제거")) { editor.mutate { $0.enhancements.hdrExpansion = nil; $0.enhancements.hdr = false } }
                        .frame(minHeight: 44)
                }
                Text(L10n.tr("기기에서 밝기 배율을 추정합니다. 편집 후에는 다시 예측할 수 있습니다. 날아간 하이라이트의 디테일은 복원되지 않습니다."))
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let range = editor.sourceDynamicRange {
                Text(range == .raw ? L10n.tr("RAW 현상의 HDR 범위를 사용합니다.") : L10n.tr("사진에 포함된 HDR 정보를 사용합니다."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
