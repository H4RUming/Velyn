import SwiftUI
import AVFoundation

struct CameraCaptureView: View {
    let completion: (Result<URL,Error>?) -> Void
    @State private var service = CameraService()
    @State private var capabilities: CameraCapabilities?
    @State private var authorized = false
    @State private var busy = false
    @State private var message: String?
    @State private var raw = false
    @State private var manual = false
    @State private var iso = 200.0
    @State private var shutter = 125.0
    @State private var manualFocus = false
    @State private var focus = 0.5
    @State private var bias = 0.0
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if authorized,capabilities != nil { CameraPreview(handle: service.handle).overlay(alignment: .top) { Text(raw ? "RAW" : "JPEG").font(.caption).padding(8).background(.black.opacity(0.6)) } }
                else { VStack(spacing: 16) { Text(message ?? "카메라 준비 중").multilineTextAlignment(.center); if !authorized { Button("설정 열기") { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } } } }.frame(maxWidth: .infinity,maxHeight: .infinity).padding() }
                if let capabilities {
                    VStack(spacing: 8) {
                        HStack { Toggle("수동 노출",isOn: $manual); if capabilities.raw { Toggle("RAW",isOn: $raw) } }
                        if manual {
                            HStack { Text("ISO \(Int(iso))").font(.caption).frame(width: 85,alignment: .leading); Slider(value: $iso,in: Double(capabilities.minISO)...Double(capabilities.maxISO),onEditingChanged: { if !$0 { configure() } }) }
                            HStack { Text("1/\(Int(shutter))초").font(.caption).frame(width: 85,alignment: .leading); Slider(value: $shutter,in: 1...1000,onEditingChanged: { if !$0 { configure() } }) }
                        } else { HStack { Text("EV \(bias,specifier: "%.1f")").font(.caption).frame(width: 85,alignment: .leading); Slider(value: $bias,in: -3...3,onEditingChanged: { if !$0 { configure() } }) } }
                        if capabilities.manualFocus { HStack { Toggle("수동 초점",isOn: $manualFocus); if manualFocus { Slider(value: $focus,onEditingChanged: { if !$0 { configure() } }) } } }
                        Button { capture() } label: { ZStack { Circle().stroke(.white,lineWidth: 3).frame(width: 68,height: 68); if busy { ProgressView() } else { Circle().fill(.white).frame(width: 56,height: 56) } }.padding(8) }.disabled(busy).accessibilityLabel("사진 촬영")
                    }.padding().background(LibraryStyle.bar).disabled(busy)
                }
            }.background(.black).navigationTitle("카메라").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { completion(nil) }.disabled(busy) } }
        }.preferredColorScheme(.dark).interactiveDismissDisabled(busy)
            .task { await start() }
            .onDisappear { Task { await service.stop() } }
            .onChange(of: phase) { _, value in if value != .active { Task { await service.stop() } } else { Task { await start() } } }
            .onChange(of: manual) { _,_ in configure() }.onChange(of: manualFocus) { _,_ in configure() }
            .alert("카메라",isPresented: Binding(get: { message != nil && capabilities != nil },set: { if !$0 { message = nil } })) { Button("확인") { message = nil } } message: { Text(message ?? "") }
    }
    private func start() async {
        authorized = await AVCaptureDevice.requestAccess(for: .video)
        guard authorized else { message = "촬영하려면 설정에서 카메라 접근을 허용해 주세요."; return }
        do { capabilities = try await service.start() } catch { message = error.localizedDescription }
    }
    private func configure() { Task { do { try await service.configure(manual: manual,iso: Float(iso),shutter: 1/shutter,focus: manualFocus ? Float(focus) : nil,bias: Float(bias)) } catch { message = error.localizedDescription } } }
    private func capture() {
        busy = true
        let orientation = (UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene)?.effectiveGeometry.interfaceOrientation ?? .portrait
        Task { do { let url = try await service.capture(raw: raw,rotationAngle: orientation.photoRotation); await service.stop(); completion(.success(url)) } catch { message = error.localizedDescription }; busy = false }
    }
}
private struct CameraPreview: UIViewRepresentable {
    let handle: CameraSessionHandle
    func makeUIView(context: Context) -> Preview { let view = Preview(); view.layerView.session = handle.session; view.layerView.videoGravity = .resizeAspect; return view }
    func updateUIView(_ view: Preview,context: Context) {}
    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var layerView: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            let angle = (window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait).photoRotation
            if let connection = layerView.connection,connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }
}
private extension UIInterfaceOrientation {
    var photoRotation: CGFloat {
        switch self { case .portraitUpsideDown: 270; case .landscapeLeft: 0; case .landscapeRight: 180; default: 90 }
    }
}
