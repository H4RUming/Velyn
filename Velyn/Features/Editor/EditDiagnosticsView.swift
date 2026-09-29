import SwiftUI
import UIKit

struct EditDiagnosticsView: View {
    let editor: EditorStore
    @State private var explain = false
    var body: some View {
        HStack(spacing: 10) {
            Canvas { context,size in
                guard let stats = editor.diagnostics else { return }
                for (bins,color) in [(stats.red,Color.red),(stats.green,Color.green),(stats.blue,Color.blue)] {
                    let maximum = max(1,bins.max() ?? 1)
                    var path = Path(); path.move(to: CGPoint(x: 0,y: size.height))
                    for index in bins.indices { path.addLine(to: CGPoint(x: Double(index)/127*size.width,y: size.height*(1-log1p(Double(bins[index]))/log1p(Double(maximum))))) }
                    path.addLine(to: CGPoint(x: size.width,y: size.height)); path.closeSubpath()
                    context.fill(path,with: .color(color.opacity(0.33)))
                }
            }.frame(width: 92,height: 34).accessibilityLabel("RGB 히스토그램. 오른쪽 끝은 SDR 흰색입니다.")
            VStack(alignment: .leading,spacing: 3) {
                if let stats = editor.diagnostics {
                    Text("SDR 초과 \(stats.aboveSDRFraction*100,specifier: "%.1f")% · 암부 \(stats.shadowFraction*100,specifier: "%.1f")%")
                    Text("사진 최대 \(stats.peak,specifier: "%.1f")× · 화면 \(editor.displayHeadroom ?? 1,specifier: "%.1f")×")
                } else { Text("보정 지표 계산 중…") }
            }.font(.system(size: 9,design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button { explain = true } label: { Image(systemName: editor.isRendering ? "clock" : "info.circle").font(.system(size: 12)).frame(width: 28,height: 40) }
                .accessibilityLabel("보정 지표 설명")
        }.padding(.horizontal,12).frame(height: 48).background(.black)
            .background { DisplayHeadroomReader { editor.displayHeadroom = $0 }.frame(width: 0,height: 0) }
            .alert("보정 지표",isPresented: $explain) { Button("확인",role: .cancel) {} } message: {
                Text("RGB 그래프의 오른쪽 끝은 SDR 흰색입니다. SDR 초과는 이 범위를 넘는 픽셀 비율이며, HDR에서는 정상일 수 있습니다. 암부는 검정에 가까운 영역입니다.\n\n사진 최대는 SDR 흰색을 1×로 본 밝기 표본이고, 화면은 현재 디스플레이가 허용하는 HDR 여유입니다. 화면 여유가 작으면 HDR이 압축되어 보입니다.\n\n256px 표본을 사용하며 조절을 멈춘 뒤 갱신합니다. 정확한 니트 측정이나 원본 전체 픽셀 검사가 아닙니다.")
            }
    }
}

private struct DisplayHeadroomReader: UIViewRepresentable {
    let update: (Double) -> Void
    func makeUIView(context: Context) -> Reader { let view = Reader(); view.update = update; return view }
    func updateUIView(_ view: Reader,context: Context) { view.update = update }
    static func dismantleUIView(_ view: Reader,coordinator: ()) { view.timer?.invalidate(); view.timer = nil }
    final class Reader: UIView {
        var update: ((Double) -> Void)?
        var timer: Timer?
        private var last: Double?
        override func didMoveToWindow() {
            super.didMoveToWindow(); timer?.invalidate(); timer = nil
            guard window != nil else { return }
            timer = Timer.scheduledTimer(withTimeInterval: 1,repeats: true) { [weak self] _ in self?.read() }
        }
        private func read() {
            guard let screen = window?.screen else { return }
            let value = Double(screen.currentEDRHeadroom)
            guard value.isFinite,value >= 1,last.map({ abs($0-value) > 0.01 }) ?? true else { return }
            last = value; update?(value)
        }
    }
}
