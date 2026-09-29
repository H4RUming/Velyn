import SwiftUI

struct BatchExportOptionsView: View {
    let count: Int
    let export: (ExportSettings) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var settings: ExportSettings = { var value = ExportSettings(); value.colorSpace = .displayP3; return value }()
    @State private var edge = 0
    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.format("%ld장 내보내기",count)) {
                    Picker(L10n.tr("형식"),selection: $settings.format) { ForEach(ImageFormats.exportFormats,id: \.self) { Text(L10n.tr($0.rawValue)).tag($0) } }.pickerStyle(.segmented)
                    Text(settings.format.summary).font(.caption).foregroundStyle(.secondary)
                    if settings.format != .original {
                        Picker(L10n.tr("크기"),selection: $edge) { Text(L10n.tr("전체 해상도")).tag(0); Text(L10n.tr("긴 변 2048px")).tag(2048); Text(L10n.tr("긴 변 4096px")).tag(4096) }
                        Picker(L10n.tr("색 공간"),selection: $settings.colorSpace) { ForEach(OutputColorSpace.allCases,id: \.self) { Text(L10n.tr($0.rawValue)).tag($0) } }
                        if settings.format.supportsHDR { Toggle(L10n.tr("HDR 저장"),isOn: $settings.hdr) }
                        if settings.format.supportsQuality {
                            LabeledContent(L10n.tr("품질"),value: "\(Int(settings.quality*100))%")
                            Slider(value: $settings.quality,in: 0.5...1)
                        }
                        TextField(L10n.tr("워터마크 (선택)"),text: $settings.watermark)
                    }
                }
                Section {
                    Button(L10n.tr("파일 만들기")) {
                        settings.longEdge = edge == 0 ? nil : edge
                        if settings.format != .jpeg && settings.format != .heic { settings.hdr = false }
                        export(settings); dismiss()
                    }
                } footer: { Text(settings.format == .original ? L10n.tr("보정 전 원본과 기존 위치정보를 유지합니다.") : L10n.tr("사진을 한 장씩 처리한 뒤 시스템 저장 화면을 엽니다. 새 파일의 위치정보는 제거합니다.")) }
            }.navigationTitle(L10n.tr("일괄 내보내기")).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(L10n.tr("취소")) { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
}
