import AVFoundation
import Foundation

struct CameraCapabilities: Sendable {
    let raw: Bool
    let minISO: Float
    let maxISO: Float
    let manualFocus: Bool
}
/// The session is configured and run only by CameraService. UIKit only attaches a preview layer.
final class CameraSessionHandle: @unchecked Sendable {
    let session = AVCaptureSession()
}
actor CameraService {
    nonisolated let handle = CameraSessionHandle()
    private let output = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var delegates: [Int64: PhotoCaptureDelegate] = [:]
    private var configured = false

    func start() throws -> CameraCapabilities {
        if !configured {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,for: .video,position: .back) else { throw CameraFailure.unavailable }
            let session = handle.session
            session.beginConfiguration()
            session.sessionPreset = .photo
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else { session.commitConfiguration(); throw CameraFailure.unavailable }
            session.addInput(input); session.addOutput(output); session.commitConfiguration()
            if output.isAppleProRAWSupported { output.isAppleProRAWEnabled = true }
            if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.max(by: { $0.width*$0.height < $1.width*$1.height }) { output.maxPhotoDimensions = dimensions }
            self.device = device; configured = true
        }
        handle.session.startRunning()
        guard let device else { throw CameraFailure.unavailable }
        return CameraCapabilities(raw: !output.availableRawPhotoPixelFormatTypes.isEmpty,minISO: device.activeFormat.minISO,maxISO: device.activeFormat.maxISO,manualFocus: device.isLockingFocusWithCustomLensPositionSupported)
    }
    func stop() { handle.session.stopRunning() }
    func configure(manual: Bool,iso: Float,shutter: Double,focus: Float?,bias: Float) throws {
        guard let device else { return }
        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
        if manual && device.isExposureModeSupported(.custom) {
            let seconds = min(device.activeFormat.maxExposureDuration.seconds,max(device.activeFormat.minExposureDuration.seconds,shutter))
            device.setExposureModeCustom(duration: CMTime(seconds: seconds,preferredTimescale: 1_000_000),iso: min(device.activeFormat.maxISO,max(device.activeFormat.minISO,iso)))
        } else if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
            device.setExposureTargetBias(min(device.maxExposureTargetBias,max(device.minExposureTargetBias,bias)))
        }
        if let focus,device.isLockingFocusWithCustomLensPositionSupported { device.setFocusModeLocked(lensPosition: min(1,max(0,focus))) }
        else if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
    }
    func capture(raw: Bool,rotationAngle: CGFloat = 90) async throws -> URL {
        guard configured, handle.session.isRunning else { throw CameraFailure.unavailable }
        if let connection = output.connection(with: .video),connection.isVideoRotationAngleSupported(rotationAngle) { connection.videoRotationAngle = rotationAngle }
        let settings: AVCapturePhotoSettings
        if raw,let format = output.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) ?? output.availableRawPhotoPixelFormatTypes.first {
            settings = AVCapturePhotoSettings(rawPixelFormatType: format)
        } else { settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]) }
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        let id = settings.uniqueID
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = PhotoCaptureDelegate { [weak self] result in
                Task { await self?.finished(id) }
                continuation.resume(with: result)
            }
            delegates[id] = delegate
            output.capturePhoto(with: settings,delegate: delegate)
        }
    }
    private func finished(_ id: Int64) { delegates[id] = nil }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let completion: @Sendable (Result<URL,Error>) -> Void
    private let lock = NSLock()
    private var result: Result<Data,Error>?
    private var isRAW = false
    init(completion: @escaping @Sendable (Result<URL,Error>) -> Void) { self.completion = completion }
    func photoOutput(_ output: AVCapturePhotoOutput,didFinishProcessingPhoto photo: AVCapturePhoto,error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if let error { result = .failure(error) }
        else if let data = photo.fileDataRepresentation() { result = .success(data); isRAW = photo.isRawPhoto }
        else { result = .failure(CameraFailure.captureFailed) }
    }
    func photoOutput(_ output: AVCapturePhotoOutput,didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,error: Error?) {
        lock.lock(); let captured = result; let raw = isRAW; lock.unlock()
        let completion = completion
        Task.detached {
            do {
                if let error { throw error }
                guard let captured else { throw CameraFailure.captureFailed }
                let bytes = try captured.get()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("VelynCamera-\(UUID())")
                try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("Capture.\(raw ? "dng" : "jpg")")
                do { try bytes.write(to: url,options: .atomic) } catch { try? FileManager.default.removeItem(at: directory); throw error }
                completion(.success(url))
            } catch { completion(.failure(error)) }
        }
    }
}
enum CameraFailure: LocalizedError {
    case unavailable,captureFailed
    var errorDescription: String? {
        switch self { case .unavailable: L10n.tr("이 기기에서 카메라를 사용할 수 없습니다."); case .captureFailed: L10n.tr("사진 촬영에 실패했습니다. 다시 시도해 주세요.") }
    }
}
