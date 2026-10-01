#if DEBUG && targetEnvironment(simulator)
import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Explicit opt-in simulator fixture. Uses a separate store and is absent from device/release builds.
actor EditorSmokeFixture {
    @MainActor static func exercise(editor: EditorStore) async {
        guard ProcessInfo.processInfo.arguments.contains("--editor-smoke-test"), editor.document != nil else { return }
        editor.set(.exposure, 0.65)
        editor.set(.contrast, 18)
        editor.set(.highlights, -25)
        editor.set(.shadows, 20)
        editor.finishGesture()
        let edited = editor.recipe
        editor.undo()
        let undoWorked = editor.recipe != edited
        editor.redo()
        let redoWorked = editor.recipe == edited
        let saved = await editor.flush()
        let output = await editor.export(settings: ExportSettings())
        let report: [String: Any] = ["undo": undoWorked, "redo": redoWorked,
            "saved": saved, "exported": output != nil, "revision": editor.document?.revision ?? -1,
            "exportFilename": output?.lastPathComponent ?? "", "error": editor.errorMessage ?? ""]
        if let root = try? OriginalImportService.applicationRoot(),
           let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("editor-smoke-report.json"), options: .atomic)
        }
        editor.retry()
    }

    @MainActor static func exerciseGainMap(editor: EditorStore) async {
        guard ProcessInfo.processInfo.arguments.contains("--editor-smoke-test") else { return }
        editor.reset()
        await editor.estimateHDRExpansion()
        let generated = editor.recipe.enhancements.hdrExpansion != nil
        let predicted = editor.recipe
        editor.undo()
        let undone = editor.recipe.enhancements.hdrExpansion == nil
        editor.redo()
        let redone = editor.recipe == predicted
        editor.mutate { $0.enhancements.hdrExpansion?.strength = 0.42; $0.enhancements.hdrExpansion?.maximumBoostEV = 1.4; $0.enhancements.hdrExpansion?.protectMidtones = false; $0[.exposure] = 0.1 }
        let detectsStaleMap = (try? await GainPredictionContext.shared.matches(editor.recipe)) == false
        await editor.estimateHDRExpansion()
        let recalculated = editor.recipe.enhancements.hdrExpansion
        let preservesGainSettings = recalculated?.strength == 0.42 && recalculated?.maximumBoostEV == 1.4 && recalculated?.protectMidtones == false
        let refreshesFingerprint = (try? await GainPredictionContext.shared.matches(editor.recipe)) == true
        editor.mutate { $0.enhancements.hdrExpansion?.strength = 0.75; $0.enhancements.hdrExpansion?.maximumBoostEV = 2; $0.enhancements.hdrExpansion?.protectMidtones = true }
        var settings = ExportSettings(); settings.hdr = true
        let jpeg = await editor.export(settings: settings)
        settings.format = .heic
        let heic = await editor.export(settings: settings)
        let saved = await editor.flush()
        editor.retry()
        for _ in 0..<500 { if !editor.isRendering { break }; try? await Task.sleep(for: .milliseconds(20)) }
        let hdrRecipe = editor.recipe
        let hdrPeak = editor.diagnostics?.peak ?? 0
        let neutral = if let image = editor.preview?.image { await shared.neutralSamples(image) } else { [[Float]]() }
        editor.previewSDR = true
        for _ in 0..<500 { if !editor.isRendering { break }; try? await Task.sleep(for: .milliseconds(20)) }
        let comparedSDR = editor.recipe == hdrRecipe && !editor.displayRecipe.enhancements.hdr
        editor.previewSDR = false
        let report: [String: Any] = ["generated": generated,"undo": undone,"redo": redone,
            "jpeg": jpeg != nil,"heic": heic != nil,"saved": saved,"hdrPeak": hdrPeak,"actualHDRPixels": hdrPeak > 1.2,
            "neutralRGB": neutral,"neutralRGBPassed": !neutral.isEmpty && neutral.allSatisfy { abs($0[0]-$0[1]) < 0.01 && abs($0[0]-$0[2]) < 0.01 },
            "sdrComparisonKeepsRecipe": comparedSDR,"detectsStaleMap": detectsStaleMap,"preservesGainSettings": preservesGainSettings,"refreshesFingerprint": refreshesFingerprint,"error": editor.errorMessage ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]) {
            await shared.writeGainMapReport(data)
        }
        editor.retry()
    }
    private func neutralSamples(_ image: CGImage) -> [[Float]] {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let context = CIContext(options: [.workingColorSpace: space])
        let source = CIImage(cgImage: image)
        return [700.0,900.0,1100.0].map { x in
            var pixel = [Float](repeating: 0,count: 4)
            pixel.withUnsafeMutableBytes { context.render(source,toBitmap: $0.baseAddress!,rowBytes: 16,
                bounds: CGRect(x: x*Double(image.width)/1200,y: 100*Double(image.height)/900,width: 1,height: 1),format: .RGBAf,colorSpace: space) }
            return Array(pixel.prefix(3))
        }
    }
    private func writeGainMapReport(_ data: Data) {
        if let root = try? OriginalImportService.applicationRoot() {
            try? data.write(to: root.appendingPathComponent("gain-map-smoke-report.json"),options: .atomic)
        }
    }

    @MainActor static func exerciseInteraction(editor: EditorStore) async {
        guard ProcessInfo.processInfo.arguments.contains("--editor-smoke-test") else { return }
        editor.reset()
        if ProcessInfo.processInfo.arguments.contains("--editor-smoke-gamut") { editor.set(.gamutExpansion,70); editor.finishGesture() }
        for _ in 0..<150 { if !editor.isRendering { break }; try? await Task.sleep(for: .milliseconds(20)) }
        let before = editor.previewFrameCount
        let renderStartCount = editor.interactiveRenderStarts.count
        let started = ContinuousClock.now
        for index in 0..<80 {
            editor.set(.exposure,Double(index)/79*1.5)
            try? await Task.sleep(for: .milliseconds(16))
        }
        let during = editor.previewFrameCount-before
        let released = ContinuousClock.now
        editor.finishGesture()
        for _ in 0..<500 { if !editor.isRendering { break }; try? await Task.sleep(for: .milliseconds(20)) }
        let end = ContinuousClock.now
        var report: [String: Any] = ["environment": "iOS 27 Simulator; synthetic 1200x900 chart", "inputEvents": 80,
            "gamutStrength": editor.recipe[.gamutExpansion],"framesWhileDragging": during,"totalFrames": editor.previewFrameCount-before,
            "dragSeconds": Double(started.duration(to: released).components.attoseconds)/1e18 + Double(started.duration(to: released).components.seconds),
            "settleSeconds": Double(released.duration(to: end).components.attoseconds)/1e18 + Double(released.duration(to: end).components.seconds),
            "finalRecipeMatches": editor.presentedRecipe == editor.recipe,
            "finalPreviewWidth": editor.preview?.image.width ?? 0,"error": editor.errorMessage ?? ""]
        let starts = Array(editor.interactiveRenderStarts.dropFirst(renderStartCount))
        let intervals = zip(starts,starts.dropFirst()).map { first, second in
            let duration = first.duration(to: second)
            return Double(duration.components.seconds) + Double(duration.components.attoseconds)/1e18
        }
        report["interactiveRenderCount"] = starts.count
        report["minimumInteractiveIntervalMs"] = (intervals.min() ?? 0)*1000
        report["interactiveCapPassed"] = !intervals.isEmpty && intervals.allSatisfy { $0 >= 1.0/30.0 }
        // A fast end-of-gesture update must survive the throttle, and idle time must not keep rendering.
        editor.set(.exposure,1.6); editor.set(.exposure,1.7); editor.finishGesture()
        for _ in 0..<250 { if !editor.isRendering { break }; try? await Task.sleep(for: .milliseconds(20)) }
        report["trailingValueMatches"] = editor.presentedRecipe == editor.recipe && editor.recipe[.exposure] == 1.7
        let idleFrames = editor.previewFrameCount
        try? await Task.sleep(for: .milliseconds(250))
        report["idleDoesNotRender"] = idleFrames == editor.previewFrameCount
        // Rapid transitions must reject drag results from the preceding view/history state.
        editor.set(.contrast,35); editor.toggleComparison()
        for _ in 0..<250 { if !editor.isRendering { break }; try? await Task.sleep(for: .milliseconds(20)) }
        report["comparisonMatches"] = editor.presentedRecipe == editor.displayRecipe && editor.isComparing
        editor.toggleComparison(); editor.undo(); editor.redo()
        for _ in 0..<250 { if !editor.isRendering { break }; try? await Task.sleep(for: .milliseconds(20)) }
        report["historyMatches"] = editor.presentedRecipe == editor.recipe && !editor.isComparing
        _ = await editor.flush(); editor.retry()
        for _ in 0..<250 { if !editor.isRendering { break }; try? await Task.sleep(for: .milliseconds(20)) }
        report["resumeMatches"] = editor.presentedRecipe == editor.recipe && !editor.isRendering
        if let data = try? JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]) { await shared.writeInteractionReport(data) }
    }
    private func writeInteractionReport(_ data: Data) {
        if let root = try? OriginalImportService.applicationRoot() { try? data.write(to: root.appendingPathComponent("interaction-smoke-report.json"),options: .atomic) }
    }

    @MainActor static func exerciseRemoval(editor: EditorStore) async {
        guard ProcessInfo.processInfo.arguments.contains("--editor-smoke-test") else { return }
        editor.reset(); editor.setSpatialMode(true)
        for _ in 0..<250 { if !editor.isRendering { break }; try? await Task.sleep(for: .milliseconds(20)) }
        let original = editor.recipe, frames = editor.previewFrameCount
        editor.removalSelection.clear()
        editor.appendRemovalStroke(MaskStroke(points: [.init(0.30,0.24),.init(0.43,0.24),.init(0.43,0.40)],radius: 0.035,feather: 0,erasing: false))
        editor.appendRemovalStroke(MaskStroke(points: [.init(0.36,0.24)],radius: 0.016,feather: 0,erasing: true))
        try? await Task.sleep(for: .milliseconds(150))
        var report: [String: Any] = ["environment": "iOS 27 Simulator; generated 1200x900 chart; programmatic workflow",
            "paintDoesNotEditRecipe": editor.recipe == original, "paintDoesNotRenderPhoto": frames == editor.previewFrameCount]
        if ProcessInfo.processInfo.arguments.contains("--editor-smoke-removal-run") {
            // Cancellation retains the user's selection and rejects incomplete inference results.
            let selected = editor.removalSelection
            let operation = Task { await editor.runRemoval() }
            for _ in 0..<100 { if editor.isAnalyzing { break }; await Task.yield() }
            editor.cancelAnalysis(); await operation.value
            report["cancelKeepsSelection"] = editor.removalSelection == selected
            report["cancelDoesNotEditRecipe"] = editor.recipe == original
            await editor.runRemoval()
            let result = editor.recipe
            report["generatedPatch"] = result.enhancements.removals?.count == 1
            report["successClearsSelection"] = editor.removalSelection.strokes.isEmpty
            editor.undo(); report["undo"] = editor.recipe == original
            editor.redo(); report["redo"] = editor.recipe == result
            report["saved"] = await editor.flush()
            await editor.load(); report["reopened"] = editor.recipe == result
        }
        report["error"] = editor.errorMessage ?? ""
        if let data = try? JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]) {
            await shared.writeRemovalReport(data)
        }
    }
    private func writeRemovalReport(_ data: Data) {
        if let root = try? OriginalImportService.applicationRoot() {
            try? data.write(to: root.appendingPathComponent("removal-smoke-report.json"),options: .atomic)
        }
    }

    static let shared = EditorSmokeFixture()
    @MainActor static func exerciseProfessional(editor: EditorStore) async {
        guard ProcessInfo.processInfo.arguments.contains("--editor-smoke-test") else { return }
        editor.reset()
        var mask = LocalMask(kind: .radial); mask.exposure = 0.5
        editor.mutate { $0.enhancements.masks = [mask]; $0.enhancements.grading[0].saturation = 10; $0.enhancements.grading[0].hue = 220 }
        editor.activeMask = mask.id
        await editor.removeSelectedArea()
        let removal = editor.recipe.enhancements.removals?.count == 1
        await editor.estimateDepth()
        let depth = editor.recipe.enhancements.depth != nil
        await editor.saveVersion(name: "Professional simulator smoke")
        let recipe = editor.recipe
        editor.undo(); editor.redo()
        let history = editor.recipe == recipe
        var options = ExportSettings(); options.hdr = true
        let hdr = await editor.export(settings: options)
        options.hdr = false; options.format = .tiff
        let tiff = await editor.export(settings: options)
        let saved = await editor.flush()
        let report: [String: Any] = ["removal": removal,"depth": depth,"history": history,"hdr": hdr != nil,"tiff": tiff != nil,"saved": saved,"error": editor.errorMessage ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]) { await shared.writeProfessionalReport(data) }
        editor.showMaskOverlay = true; editor.retry()
    }
    private func writeProfessionalReport(_ data: Data) {
        if let root = try? OriginalImportService.applicationRoot() { try? data.write(to: root.appendingPathComponent("professional-smoke-report.json"),options: .atomic) }
    }
    func create() throws -> URL {
        if ProcessInfo.processInfo.arguments.contains("--editor-smoke-raw") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("raw-smoke.dng")
        }
        guard let context = CGContext(data: nil, width: 1200, height: 900, bitsPerComponent: 8,
            bytesPerRow: 4800, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw EditorFailure.renderFailed }
        context.setFillColor(CGColor(gray: 0.12, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.76,0.26,0.23), (0.91,0.54,0.20), (0.88,0.79,0.31), (0.31,0.52,0.35),
            (0.23,0.54,0.62), (0.26,0.37,0.67), (0.52,0.32,0.62), (0.72,0.34,0.53),
            (0.70,0.49,0.36), (0.86,0.68,0.53), (0.39,0.46,0.54), (0.55,0.59,0.42)
        ]
        for (index, rgb) in palette.enumerated() {
            context.setFillColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
            context.fill(CGRect(x: 48 + (index % 4) * 282, y: 225 + (index / 4) * 213, width: 258, height: 189))
        }
        for index in 0..<1104 {
            context.setFillColor(CGColor(gray: CGFloat(index) / 1103, alpha: 1))
            context.fill(CGRect(x: 48 + index, y: 48, width: 1, height: 140))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Editor test chart.jpg")
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EditorFailure.renderFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EditorFailure.renderFailed }
        return url
    }
}
#endif
