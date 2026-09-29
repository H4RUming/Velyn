import SwiftUI
import UIKit
import Photos

struct EditorExportView: View {
    let editor: EditorStore
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ExportSettings()
    @State private var initialized = false
    @State private var edge = 0
    @State private var customEdge = "3000"
    @State private var file: ExportFile?
    @State private var exportCopyURL: URL?
    @State private var prepared: PreparedExport?
    @State private var preparedSettings: ExportSettings?
    @State private var calculating = false
    @State private var saving = false
    @State private var message: String?
    @State private var localError: String?
    @State private var estimateError: String?
    @State private var generation = UUID()

    private var effectiveSettings: ExportSettings? {
        var value = settings
        if value.format == .original { return ExportSettings.originalSettings }
        if edge == -1 {
            guard let number = Int(customEdge), (64...20_000).contains(number) else { return nil }
            value.longEdge = number
        } else { value.longEdge = edge == 0 ? nil : edge }
        if !value.format.supportsHDR { value.hdr = false }
        return value
    }
    private var ready: Bool { prepared != nil && preparedSettings == effectiveSettings && !calculating && !saving }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading,spacing: 22) {
                    exportSummary
                    VStack(alignment: .leading,spacing: 12) {
                        Text(L10n.tr("파일 형식")).font(.subheadline.weight(.semibold))
                        Picker(L10n.tr("파일 형식"),selection: $settings.format) {
                            ForEach(ImageFormats.exportFormats,id: \.self) { format in
                                Text(format == .original ? L10n.tr("원본") : format.rawValue).tag(format)
                            }
                        }.pickerStyle(.segmented)
                        Text(settings.format.summary).font(.caption).foregroundStyle(.secondary)
                    }
                    if settings.format != .original {
                        VStack(spacing: 16) {
                            Picker(L10n.tr("크기"),selection: $edge) {
                                Text(L10n.tr("전체 해상도")).tag(0)
                                Text(L10n.tr("긴 변 2048px")).tag(2048)
                                Text(L10n.tr("긴 변 4096px")).tag(4096)
                                Text(L10n.tr("직접 입력")).tag(-1)
                            }.tint(.white)
                            if edge == -1 {
                                TextField(L10n.tr("긴 변 · 64~20,000px"),text: $customEdge)
                                    .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                            }
                            if settings.format == .png {
                                VStack(alignment: .leading,spacing: 6) {
                                    Toggle(L10n.tr("16비트 PNG"),isOn: $settings.png16Bit)
                                    Text(L10n.tr("보정한 색과 밝기의 단계를 더 세밀하게 저장합니다. 파일 용량은 커집니다.")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            if settings.format.supportsQuality {
                                VStack(alignment: .leading,spacing: 6) {
                                    LabeledContent(L10n.tr("품질"),value: "\(Int(settings.quality*100))%")
                                    Slider(value: $settings.quality,in: 0.1...1,step: 0.01).accessibilityLabel(L10n.tr("출력 품질"))
                                    Text(L10n.tr("품질을 낮추면 용량도 줄어듭니다.")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.font(.subheadline).frame(maxWidth: .infinity).padding(16)
                            .background(Color.white.opacity(0.05),in: RoundedRectangle(cornerRadius: 16))
                        DisclosureGroup(L10n.tr("추가 옵션")) {
                            VStack(alignment: .leading,spacing: 16) {
                                Picker(L10n.tr("색 공간"),selection: $settings.colorSpace) {
                                    ForEach(OutputColorSpace.allCases,id: \.self) { Text(L10n.tr($0.rawValue)).tag($0) }
                                }
                                Text(settings.colorSpace == .sRGB ? L10n.tr("sRGB는 웹과 대부분의 화면에 적합합니다.") : L10n.tr("Display P3는 더 넓은 색 범위를 보존합니다."))
                                    .font(.caption).foregroundStyle(.secondary)
                                if settings.format.supportsHDR { Toggle(L10n.tr("HDR 저장"),isOn: $settings.hdr) }
                                TextField(L10n.tr("워터마크 (선택)"),text: $settings.watermark).textFieldStyle(.roundedBorder)
                                Text(settings.format.preservesAlpha ? L10n.tr("투명 영역을 유지합니다. 위치·촬영 정보는 제거됩니다.") : L10n.tr("투명 영역은 흰색으로 채웁니다. 위치·촬영 정보는 제거됩니다."))
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.top,14)
                        }.font(.subheadline)
                    }
                    if settings.format != .original, editor.recipe[.gamutExpansion] > 0 {
                        Text(settings.colorSpace == .displayP3 ? L10n.tr("확장한 색을 Display P3로 저장합니다.") : L10n.tr("sRGB 저장에서는 확장한 색 일부가 좁은 색역으로 변환됩니다. 추가 옵션에서 Display P3를 선택할 수 있습니다."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let estimateError { Text(estimateError).font(.caption).foregroundStyle(.orange) }
                    if let message { Label(message,systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.green) }
                }.padding(22)
            }
            .background(LibraryStyle.background)
            .safeAreaInset(edge: .bottom) { saveActions }
            .disabled(saving)
            .navigationTitle(L10n.tr("사진 저장")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.tr("완료")) { dismiss() }.disabled(saving) } }
        }
        .preferredColorScheme(.dark).tint(LibraryStyle.blue)
        .interactiveDismissDisabled(saving)
        .onAppear {
            editor.finishGesture()
            if editor.isComparing { editor.toggleComparison() }
            #if DEBUG && targetEnvironment(simulator)
            if ProcessInfo.processInfo.arguments.contains("--editor-smoke-test"),
               let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--editor-export-format=") }),
               let format = ExportFormat(rawValue: String(argument.dropFirst("--editor-export-format=".count))), ImageFormats.exportFormats.contains(format) { settings.format = format }
            #endif
            if !initialized {
                settings.png16Bit = editor.document?.raw != nil
                settings.hdr = editor.recipe.enhancements.hdr
                if editor.document?.raw != nil || editor.recipe[.gamutExpansion] > 0 { settings.colorSpace = .displayP3 }
                initialized = true
            }
        }
        .task(id: effectiveSettings) { await updateEstimate() }
        .onDisappear {
            generation = UUID()
            if let prepared { self.prepared = nil; Task { await editor.discardExport(prepared.url) } }
        }
        .sheet(item: $file,onDismiss: {
            if let exportCopyURL { Task { await editor.discardExport(exportCopyURL) } }
            exportCopyURL = nil; file = nil
        }) { item in
            FileExportPicker(url: item.url) { saved in
                if saved { message = L10n.tr("파일을 저장했습니다") }
                file = nil
            }
        }
        .alert(L10n.tr("저장하지 못했습니다"),isPresented: Binding(get: { localError != nil },set: { if !$0 { localError = nil } })) {
            Button(L10n.tr("확인"),role: .cancel) { localError = nil }
        } message: { Text(localError ?? "") }
    }
    private var exportSummary: some View {
        HStack(spacing: 18) {
            if settings.format == .original {
                Image(systemName: "doc.zipper").font(.system(size: 34,weight: .light))
                    .frame(width: 92,height: 108).background(Color.white.opacity(0.05),in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            } else if let image = editor.preview?.image {
                Image(decorative: image,scale: 1).resizable().scaledToFit()
                    .frame(width: 92,height: 108).background(Color.black,in: RoundedRectangle(cornerRadius: 12))
                    .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityHidden(true)
            }
            VStack(alignment: .leading,spacing: 7) {
                Text(L10n.tr("저장 용량")).font(.caption).foregroundStyle(.secondary)
                if let prepared, preparedSettings == effectiveSettings, !calculating {
                    Text(ByteCountFormatter.string(fromByteCount: prepared.byteCount,countStyle: .file))
                        .font(.system(size: 29,weight: .semibold,design: .rounded)).monospacedDigit()
                    Text("\(prepared.width) × \(prepared.height) · .\(prepared.url.pathExtension)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack { if calculating { ProgressView().controlSize(.small) }; Text(calculating ? L10n.tr("용량 계산 중") : "—") }.font(.subheadline)
                }
                Text(settings.format == .original ? L10n.tr("편집 없이 원본 그대로") : (settings.format == .png && settings.png16Bit ? L10n.tr("16비트 · SDR") : (settings.hdr && settings.format.supportsHDR ? L10n.tr("HDR · SDR 호환") : L10n.tr("편집한 사진 · SDR"))))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity,alignment: .leading)
    }
    private var saveActions: some View {
        VStack(spacing: 8) {
            Button { Task { await savePhotos() } } label: {
                HStack { if saving { ProgressView().tint(.white) }; Label(L10n.tr("사진에 저장"),systemImage: "photo.badge.arrow.down") }
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 52)
                    .background(ready ? LibraryStyle.blue : Color.white.opacity(0.1),in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain).disabled(!ready)
            Button { Task { await saveFile() } } label: {
                Label(L10n.tr("파일에 저장"),systemImage: "folder").font(.subheadline).frame(maxWidth: .infinity).frame(height: 42)
            }.disabled(!ready)
            Text(L10n.tr("기기에서 계산한 실제 파일 용량입니다.")).font(.caption2).foregroundStyle(.secondary)
        }.padding(.horizontal,22).padding(.top,14).padding(.bottom,10).background(LibraryStyle.background)
    }
    private func updateEstimate() async {
        let id = UUID(); generation = id
        if let prepared { self.prepared = nil; await editor.discardExport(prepared.url) }
        guard !Task.isCancelled, generation == id else { return }
        preparedSettings = nil; estimateError = nil; calculating = false
        guard let request = effectiveSettings else { estimateError = L10n.tr("긴 변은 64~20,000 픽셀로 입력해 주세요."); return }
        calculating = true
        do {
            try await Task.sleep(for: .milliseconds(550))
            let result = try await editor.prepareExport(settings: request)
            guard !Task.isCancelled, generation == id, effectiveSettings == request else { await editor.discardExport(result.url); return }
            prepared = result; preparedSettings = request; calculating = false
        } catch is CancellationError { }
        catch { if generation == id { calculating = false; estimateError = error.localizedDescription } }
    }
    private func saveFile() async {
        guard ready, let prepared else { return }
        saving = true; defer { saving = false }
        do { let url = try await editor.copyPreparedExport(prepared); exportCopyURL = url; file = ExportFile(url: url) }
        catch { localError = error.localizedDescription }
    }
    private func savePhotos() async {
        guard ready, let prepared else { return }
        saving = true; defer { saving = false }
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else { localError = L10n.tr("사진 추가 권한을 허용하거나 파일에 저장해 주세요."); return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo,fileURL: prepared.url,options: nil)
            }
            message = L10n.tr("사진 앱에 저장했습니다")
        } catch { localError = L10n.tr("사진 앱에 저장하지 못했습니다. 파일에 저장을 이용해 주세요.") }
    }
}

private extension ExportSettings {
    static var originalSettings: ExportSettings { var value = ExportSettings(); value.format = .original; return value }
}

private struct ExportFile: Identifiable { let id = UUID(); let url: URL }
private struct FileExportPicker: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Bool) -> Void
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(false) }
    }
}
