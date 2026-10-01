import SwiftUI

struct HDRExpansionControls: View {
    let editor: EditorStore
    @State private var parameter = 0
    @State private var stalePrediction = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if editor.recipe.enhancements.hdr && editor.sourceDynamicRange != .sdr {
                compareButton
            }
            if editor.sourceDynamicRange == .sdr {
                HStack {
                    Button(editor.recipe.enhancements.hdrExpansion == nil ? L10n.tr("HDR 밝기 지도 만들기") : L10n.tr("밝기 지도 다시 예측")) {
                        Task { await editor.estimateHDRExpansion() }
                    }.disabled(editor.isAnalyzing || editor.isExporting)
                    Spacer()
                    if editor.recipe.enhancements.hdr && !editor.isAnalyzing { compareButton }
                    if editor.isAnalyzing {
                        ProgressView().controlSize(.small)
                        Button(L10n.tr("취소")) { editor.cancelAnalysis() }
                    }
                }.font(.caption).frame(minHeight: 36)
                if editor.previewSDR { Text(L10n.tr("SDR 비교 중 · 저장 설정은 유지됩니다")).font(.caption2).foregroundStyle(.secondary) }
                if let expansion = editor.recipe.enhancements.hdrExpansion {
                    if expansion.predictionFingerprint == nil || stalePrediction {
                        Label(L10n.tr("현재 보정과 밝기 지도가 다를 수 있습니다. 다시 예측해 주세요."),systemImage: "arrow.clockwise").font(.caption).foregroundStyle(.orange)
                    }
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
                    if expansion.protectMidtones == true { Text(L10n.tr("어두운 부분과 중간 밝기는 유지하고 밝은 영역을 중심으로 확장합니다.")).font(.caption2).foregroundStyle(.secondary) }
                    HStack {
                        Button(L10n.tr("톤 유지")) { editor.mutate { $0.enhancements.hdrExpansion?.strength = 0.75; $0.enhancements.hdrExpansion?.maximumBoostEV = 2; $0.enhancements.hdrExpansion?.protectMidtones = true } }
                        Button(L10n.tr("모델 예측 그대로")) { editor.mutate { $0.enhancements.hdrExpansion?.strength = 1; $0.enhancements.hdrExpansion?.maximumBoostEV = log2(5); $0.enhancements.hdrExpansion?.protectMidtones = false } }
                    }.font(.caption).buttonStyle(.bordered)

                    Button(L10n.tr("밝기 지도 제거")) { editor.mutate { $0.enhancements.hdrExpansion = nil; $0.enhancements.hdr = false } }
                        .frame(minHeight: 44)
                }
                Label(L10n.tr("SDR에서 추정한 HDR"),systemImage: "sparkles").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(L10n.tr("SDR만으로 원래 HDR을 정확히 복원할 수는 없습니다. 모델은 밝기 배율을 추정합니다. 원본 HDR 파일이 있다면 그 파일을 가져와 주세요."))
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let range = editor.sourceDynamicRange {
                Text(range == .raw ? L10n.tr("RAW 현상의 HDR 범위를 사용합니다.") : L10n.tr("사진에 포함된 HDR 정보를 사용합니다."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .task(id: editor.recipe) {
            let snapshot = editor.recipe
            guard snapshot.enhancements.hdrExpansion != nil else { stalePrediction = false; return }
            do {
                let matches = try await GainPredictionContext.shared.matches(snapshot)
                try Task.checkCancellation()
                stalePrediction = !matches
            } catch is CancellationError {} catch { stalePrediction = true }
        }
    }
    private var compareButton: some View {
        Button(editor.previewSDR ? L10n.tr("HDR 보기") : L10n.tr("SDR로 비교")) { editor.previewSDR.toggle() }
            .font(.caption).frame(minHeight: 36)
    }

}
