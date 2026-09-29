import SwiftUI

struct PhotoInformationView: View {
    let asset: SourceAsset
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(asset.originalFilename).font(.headline).textSelection(.enabled)
                    row("형식", asset.formatLabel)
                    row("크기", "\(asset.orientedWidth) × \(asset.orientedHeight)")
                    row("용량", ByteCountFormatter.string(fromByteCount: asset.byteCount, countStyle: .file))
                    if let hasAlpha = asset.hasAlpha { row("투명 채널", hasAlpha ? "있음" : "없음") }
                    if let count = asset.frameCount, count > 1 { row("프레임·페이지", "\(count)장 · 편집은 대표 장면 한 장") }
                    row("색 프로파일", asset.colorProfile ?? "정보 없음")
                    row("추가한 날짜", asset.importedAt.formatted(date: .abbreviated, time: .shortened))
                }
                Section {
                    Label("원본이 안전하게 보관되어 있습니다", systemImage: "checkmark.circle")
                        .font(.subheadline)
                    DisclosureGroup("원본 검증 정보") {
                        row("원본 픽셀", "\(asset.pixelWidth) × \(asset.pixelHeight)")
                        row("EXIF 방향", String(asset.orientation))
                        row("파일 형식", asset.typeIdentifier)
                        if asset.isRAW { row("지원 디코더", asset.supportedRAWDecoders.joined(separator: ", ")) }
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SHA-256").font(.caption).foregroundStyle(.secondary)
                            Text(asset.sha256).font(.caption.monospaced()).textSelection(.enabled)
                        }.padding(.vertical, 4)
                    }
                } footer: {
                    Text("화면은 축소 미리보기입니다. 내보내기는 원본에서 선택한 해상도로 다시 처리합니다.")
                }
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
                .background(LibraryStyle.background)
                .navigationTitle("사진 정보").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }.tint(LibraryStyle.blue).preferredColorScheme(.dark)
            .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).foregroundStyle(.secondary).textSelection(.enabled) }
            .font(.subheadline)
    }
}

struct LibrarySettingsView: View {
    let count: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("라이브러리") {
                    LabeledContent("사진", value: "\(count)장")
                    LabeledContent("저장 위치", value: "이 기기")
                    LabeledContent("지원 형식", value: "DNG, HEIC, JPEG")
                }
                Section("원본 보관") {
                    Text("가져온 사진은 원본 그대로 앱에 보관됩니다. 위치정보를 포함한 기존 메타데이터도 유지됩니다.")
                    Text("앱 내부 사진은 시스템 백업에 포함되지 않습니다. 앱 삭제나 기기 분실에 대비해 기존 원본을 별도로 보관해 주세요.")
                }
                Section("개인정보") {
                    Text("사진을 앱 서버로 전송하지 않습니다. 사진 보관함의 iCloud 원본은 사진 앱에서 먼저 다운로드해 주세요. 파일 공급자의 다운로드는 시스템 설정을 따릅니다.")
                    Text("깊이 추정과 자동 제거 모델은 앱에 포함되어 있습니다. 탭 선택 모델은 마스크 화면에서 사용자가 준비 버튼을 눌렀을 때만 시스템에서 내려받습니다.")
                    NavigationLink("오픈소스 모델·라이선스") { ModelNoticesView() }
                }
                Section {
                    LabeledContent("Velyn", value: "1.0")
                } footer: { Text("비파괴 편집·마스크·리터칭·앨범·일괄 작업·HDR JPEG/HEIC·TIFF 저장을 지원합니다.") }
            }.font(.subheadline).scrollContentBackground(.hidden).background(LibraryStyle.background)
                .navigationTitle("설정").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }.tint(LibraryStyle.blue).preferredColorScheme(.dark)
    }
}
private struct ModelNoticesView: View {
    @State private var content = "불러오는 중"
    var body: some View {
        ScrollView { Text(content).font(.caption).textSelection(.enabled).padding() }.navigationTitle("모델·라이선스")
            .task {
                content = await Task.detached {
                    ["Models-NOTICE","DepthAnything-LICENSE","AOT-GAN-LICENSE","GMNet-LICENSE"].compactMap { name in
                        Bundle.main.url(forResource: name,withExtension: "txt").flatMap { try? String(contentsOf: $0,encoding: .utf8) }
                    }.joined(separator: "\n\n")
                }.value
            }
    }
}
