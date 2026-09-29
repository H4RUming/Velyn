import Foundation

/// Persistent values only. The original is never decoded and re-encoded during import.
public struct SourceAsset: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let schemaVersion: Int
    public let importedAt: Date
    public let originalFilename: String
    public let relativePath: String
    public let sha256: String
    public let sourceSHA256: String
    public let byteCount: Int64
    public let typeIdentifier: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let orientation: Int
    public let colorProfile: String?
    public let isRAW: Bool
    public let supportedRAWDecoders: [String]
    public var frameCount: Int? = nil
    public var hasAlpha: Bool? = nil

    public var orientedWidth: Int { (5...8).contains(orientation) ? pixelHeight : pixelWidth }
    public var orientedHeight: Int { (5...8).contains(orientation) ? pixelWidth : pixelHeight }
    public var integrityVerified: Bool { sourceSHA256 == sha256 }
}

public enum ImportFailure: Error, LocalizedError, Sendable, Equatable {
    case unsupportedFormat
    case invalidImage
    case sourceUnavailable
    case permissionDenied
    case insufficientSpace
    case integrityMismatch
    case invalidProject
    case storageFailure
    case photoAccessDenied
    case photoNotAccessible
    case photoNeedsDownload
    case photoUnavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "JPEG, HEIC, PNG, WebP, TIFF, GIF, BMP, AVIF, JPEG XL, JPEG 2000 또는 지원되는 RAW 파일을 선택해 주세요."
        case .invalidImage: "사진의 형식이나 크기를 읽을 수 없습니다. 원본 파일을 확인해 주세요."
        case .sourceUnavailable: "파일을 읽을 수 없습니다. 파일 앱에서 기기에 다운로드한 뒤 다시 선택해 주세요."
        case .permissionDenied: "파일에 접근할 권한이 없습니다. 파일을 다시 선택해 접근을 허용해 주세요."
        case .insufficientSpace: "원본을 보관할 공간이 부족합니다. 기기 저장 공간을 확보한 뒤 다시 시도해 주세요."
        case .integrityMismatch: "복사한 파일이 원본과 일치하지 않습니다. 저장하지 않았습니다. 다시 시도해 주세요."
        case .invalidProject: "저장한 작업의 무결성을 확인할 수 없습니다. 원본 파일을 다시 가져와 주세요."
        case .storageFailure: "원본을 저장하지 못했습니다. 저장 공간과 파일 상태를 확인해 주세요."
        case .photoAccessDenied: "사진 보관함 접근이 허용되지 않았습니다. 설정 > 앱 > Velyn > 사진에서 접근을 허용하거나 파일에서 가져오기를 이용해 주세요."
        case .photoNotAccessible: "선택한 사진에 접근할 수 없습니다. 제한된 접근을 사용 중이라면 설정 > 앱 > Velyn > 사진에서 이 사진을 허용한 뒤 다시 선택해 주세요."
        case .photoNeedsDownload: "원본이 iCloud에만 있습니다. 사진 앱에서 원본을 기기에 다운로드한 뒤 다시 가져와 주세요."
        case .photoUnavailable: "사진 보관함에서 원본을 읽지 못했습니다. 사진 앱에서 원본 상태를 확인한 뒤 다시 시도해 주세요."
        }
    }

    public static func classify(_ error: Error) -> Error {
        if error is CancellationError || error is ImportFailure { return error }
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain {
            if value.code == NSUserCancelledError { return CancellationError() }
            if [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code) { return permissionDenied }
            if value.code == NSFileWriteOutOfSpaceError { return insufficientSpace }
            if value.code == NSFileReadNoSuchFileError { return sourceUnavailable }
        }
        if value.domain == NSPOSIXErrorDomain {
            if [1, 13].contains(value.code) { return permissionDenied }
            if value.code == 28 { return insufficientSpace }
        }
        return storageFailure
    }
}
