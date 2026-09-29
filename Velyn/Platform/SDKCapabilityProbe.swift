import CoreImage
import Vision
import CoreML

/// Compile-time spike for M0-01. It is deliberately not run during file import.
/// Model downloads require a later, explicit user action in the selection feature.
@available(iOS 27.0, macOS 27.0, *)
enum SDKCapabilityProbe {
    static func segmentationStatus() async -> DownloadableAssetsRequestStatus {
        let request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: 0.5, y: 0.5))
        request.qualityLevel = .balanced
        return await request.assetStatus
    }

    static func prepareSegmentationAssets() async throws {
        let request = GenerateIterativeSegmentationRequest(seedPoint: NormalizedPoint(x: 0.5, y: 0.5))
        try await request.downloadAssets()
    }

    static func inspectRAW(_ url: URL) -> [CIRAWDecoderVersion] {
        guard let filter = CIRAWFilter(imageURL: url) else { return [] }
        let candidates: [CIRAWDecoderVersion] = [.version9, .version9DNG]
        return candidates.filter { filter.supportedDecoderVersions.contains($0) }
    }

    static func contextOptions() -> [CIContextOption: Any] {
        [.memoryTarget: 256, .cacheIntermediates: false]
    }
}
