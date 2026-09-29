import Foundation
import Observation

@MainActor @Observable
final class EditorStore {
    private(set) var rawControls: RAWControls?
    private(set) var document: EditDocument?
    private(set) var recipe = EditRecipe()
    private(set) var preview: PhotoPreview?
    #if DEBUG
    private(set) var previewFrameCount = 0
    private(set) var presentedRecipe: EditRecipe?
    private(set) var interactiveRenderStarts: [ContinuousClock.Instant] = []
    #endif
    private(set) var presets: [UserPreset] = []
    private(set) var isRendering = false
    private(set) var loadFailed = false
    private(set) var isExporting = false
    private(set) var isSaving = false
    private(set) var saved = true
    private(set) var isComparing = false
    var errorMessage: String?
    var activeMask: UUID? { didSet { requestRender() } }
    var showMaskOverlay = true { didSet { requestRender() } }
    var maskMode = false
    var pickingObject = false
    var excludeFromMask = false
    var erasingBrush = false
    private var analysisTask: Task<LocalMask,Error>?
    private var preparationTask: Task<Void,Error>?
    private var gainTask: Task<HDRExpansion,Error>?
    private(set) var sourceDynamicRange: SourceDynamicRange?
    private var depthTask: Task<DepthEffect,Error>?
    private var removalTask: Task<RemovalPatch,Error>?
    var pickingWhiteBalance = false
    var pickingDetail = false
    var pickingDepth = false
    var removalSelection = RemovalSelection()
    var removalErasing = false
    var removalNavigating = false
    var removalBrushRadius = 0.025
    var removalCanvasReset = 0
    private(set) var diagnostics: EditDiagnostics?
    var previewSDR = false { didSet { requestRender(immediate: true) } }
    var displayHeadroom: Double?
    var showHistogram = true { didSet { if showHistogram { requestRender(immediate: true) } } }
    var showClipping = false
    var cropMode = false
    private(set) var spatialMode = false
    private(set) var isAnalyzing = false
    private(set) var analysis: ImageAnalysis?
    private(set) var versions: [EditVersion] = []
    var detailPreview: PhotoPreview?
    private let service: EditingService?
    private var renderTask: Task<Void, Never>?
    private var exportTask: Task<URL, Error>?
    private var generation = 0
    private var previewEpoch = 0
    private var workerID = UUID()
    private var refinementTask: Task<Void,Never>?
    private var previewPacingTask: Task<Void,Error>?
    private var lastInteractiveRenderStart: ContinuousClock.Instant?
    private let interactiveFrameInterval: Duration = .nanoseconds(33_333_334)
    private var pendingPreview: PreviewRequest?
    private struct PreviewRequest {
        let document: EditDocument
        let recipe: EditRecipe
        let generation: Int
        let epoch: Int
        let interactive: Bool
        let clipping: Bool
        let maskID: UUID?
    }

    init(asset: SourceAsset) {
        do { service = try EditingService.applicationService(asset: asset) }
        catch { service = nil; errorMessage = error.localizedDescription }
    }
    var canUndo: Bool { !(document?.history.undoStack.isEmpty ?? true) }
    var canRedo: Bool { !(document?.history.redoStack.isEmpty ?? true) }

    func load() async {
        guard document == nil, let service else { return }
        loadFailed = false
        do {
            document = try await service.load()
            recipe = document?.history.current ?? EditRecipe()
            if let document { rawControls = try await service.rawControls(document) }
            sourceDynamicRange = try await service.sourceDynamicRange()
            versions = try await service.versions()
            do { presets = try await service.presets() }
            catch { errorMessage = "프리셋을 읽지 못했습니다. 저장한 프리셋은 보존됩니다." }
            requestRender(immediate: true)
        } catch { loadFailed = true; errorMessage = error.localizedDescription }
    }

    func setRAW(_ parameter: RAWParameter,_ value: Double) {
        guard let defaults = rawControls?.defaults,let initial = defaults[parameter],value.isFinite,!isExporting else { return }
        var raw = recipe.rawAdjustments ?? RAWAdjustments()
        let clamped = min(max(value,parameter.range.lowerBound),parameter.range.upperBound)
        raw[parameter] = abs(clamped-initial) < 0.001 ? nil : clamped
        recipe.rawAdjustments = raw.values.isEmpty ? nil : raw
        isComparing = false; requestRender()
    }
    func resetRAW() { mutate { $0.rawAdjustments = nil } }

    func set(_ adjustment: Adjustment, _ value: Double) {
        guard document != nil, !isExporting else { return }
        recipe[adjustment] = value
        isComparing = false
        requestRender()
    }
    func setColor(_ index: Int, key: WritableKeyPath<ColorBand, Double>, value: Double) {
        guard document != nil, (0..<8).contains(index), value.isFinite, !isExporting else { return }
        recipe.colors[index][keyPath: key] = min(max(value, -100), 100)
        isComparing = false
        requestRender()
    }
    func finishGesture() {
        guard var document else { return }
        guard document.history.current != recipe else { requestRender(immediate: true); return }
        isComparing = false
        document.history.commit(recipe)
        document.revision += 1
        self.document = document
        persist(document)
        requestRender(immediate: true)
    }
    func changeGeometry(_ action: (inout EditRecipe) -> Void) {
        action(&recipe); finishGesture()
    }
    func undo() {
        finishGesture()
        guard var document, canUndo else { return }
        document.history.undo(); applyHistory(document)
    }
    func redo() {
        guard var document, canRedo else { return }
        document.history.redo(); applyHistory(document)
    }
    func reset() {
        recipe = EditRecipe(); finishGesture()
    }
    func toggleComparison() {
        isComparing.toggle(); requestRender(immediate: true)
    }
    func retry() { requestRender(immediate: true) }

    func applyPreset(_ preset: EditRecipe) {
        var result = preset.colorOnly
        result.rawAdjustments = recipe.rawAdjustments
        let geometry = recipe.geometryOnly
        result.aspect = geometry.aspect; result.quarterTurns = geometry.quarterTurns
        result.flipHorizontal = geometry.flipHorizontal
        for key in [Adjustment.straighten, .cropScale, .cropX, .cropY, .perspectiveVertical, .perspectiveHorizontal, .lensDistortion] { result[key] = geometry[key] }
        result.enhancements.masks = recipe.enhancements.masks; result.enhancements.retouches = recipe.enhancements.retouches
        result[.lensBlur] = recipe[.lensBlur]
        result.enhancements.depth = recipe.enhancements.depth
        result.enhancements.removals = recipe.enhancements.removals
        result.enhancements.hdrExpansion = recipe.enhancements.hdrExpansion
        recipe = result; finishGesture()
    }
    func savePreset(name: String) async {
        guard let service else { return }
        do { presets = try await service.savePreset(UserPreset(name: String(name.prefix(60)), recipe: recipe)) }
        catch { errorMessage = error.localizedDescription }
    }
    func flush() async -> Bool {
        finishGesture()
        stopPreview()
        guard let document, let service else { return true }
        isSaving = true
        defer { isSaving = false }
        do { try await service.save(document); saved = true; return true }
        catch { saved = false; errorMessage = error.localizedDescription; return false }
    }
    func export(settings: ExportSettings) async -> URL? {
        finishGesture()
        guard let snapshot = document, let service, !isExporting else { return nil }
        isExporting = true
        stopPreview()
        defer { isExporting = false; exportTask = nil }
        let task = Task {
            try await service.save(snapshot)
            return try await service.export(snapshot, settings: settings,
                directory: FileManager.default.temporaryDirectory.appendingPathComponent("VelynExports"))
        }
        exportTask = task
        do { return try await task.value }
        catch is CancellationError { return nil }
        catch { errorMessage = error.localizedDescription; return nil }
    }
    func cancelExport() { exportTask?.cancel() }

    private func applyHistory(_ next: EditDocument) {
        var next = next; next.revision += 1
        document = next; recipe = next.history.current; isComparing = false
        persist(next); requestRender(immediate: true)
    }
    private func persist(_ snapshot: EditDocument) {
        guard let service else { return }
        saved = false; isSaving = true
        Task {
            do {
                try await service.save(snapshot)
                if document?.revision == snapshot.revision { saved = true; isSaving = false }
            } catch {
                if document?.revision == snapshot.revision { isSaving = false; saved = false; errorMessage = error.localizedDescription }
            }
        }
    }
    private func stopPreview() {
        previewEpoch += 1
        refinementTask?.cancel(); refinementTask = nil
        pendingPreview = nil
        previewPacingTask?.cancel(); previewPacingTask = nil
        renderTask?.cancel(); renderTask = nil
        workerID = UUID()
        isRendering = false
    }
    private func requestRender(immediate: Bool = false) {
        guard let document, service != nil else { return }
        refinementTask?.cancel()
        generation += 1
        if immediate { previewEpoch += 1 }
        let request = PreviewRequest(document: document,recipe: displayRecipe,generation: generation,epoch: previewEpoch,
                                     interactive: !immediate,clipping: showClipping,
                                     maskID: maskMode && showMaskOverlay && !isComparing ? activeMask : nil)
        enqueuePreview(request)
        if !immediate {
            refinementTask = Task {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard !Task.isCancelled, generation == request.generation else { return }
                enqueuePreview(PreviewRequest(document: request.document,recipe: request.recipe,generation: request.generation,
                    epoch: request.epoch,interactive: false,clipping: request.clipping,maskID: request.maskID))
            }
        }
    }
    private func enqueuePreview(_ request: PreviewRequest) {
        pendingPreview = request // One pending slot; intermediate slider values never form a queue.
        if !request.interactive { previewPacingTask?.cancel() }
        isRendering = true
        guard renderTask == nil, let service else { return }
        let worker = UUID(); workerID = worker
        renderTask = Task {
            defer { if workerID == worker { renderTask = nil; isRendering = false } }
            while !Task.isCancelled, let next = pendingPreview {
                if next.interactive, let last = lastInteractiveRenderStart {
                    let deadline = last.advanced(by: interactiveFrameInterval)
                    if ContinuousClock.now < deadline {
                        // Throttle before rendering, not just before displaying. New drag values do not reset the deadline.
                        let wait = Task { try await Task.sleep(until: deadline,clock: .continuous) }
                        previewPacingTask = wait
                        do { try await wait.value } catch { if Task.isCancelled { break } }
                        if workerID == worker { previewPacingTask = nil }
                        continue // Read the newest pending value after waiting (or an immediate final request).
                    }
                }
                pendingPreview = nil
                if next.interactive {
                    let now = ContinuousClock.now
                    lastInteractiveRenderStart = now
                    #if DEBUG
                    interactiveRenderStarts.append(now)
                    if interactiveRenderStarts.count > 500 { interactiveRenderStarts.removeFirst() }
                    #endif
                }
                do {
                    let result = try await service.render(next.document,recipe: next.recipe,maxPixelSize: next.interactive ? 768 : 1536,
                                                          showClipping: next.clipping,overlayMaskID: next.maskID)
                    try Task.checkCancellation()
                    // Keep completed drag frames visible. Comparison/undo/commit changes the epoch and rejects older frames.
                    guard next.epoch == previewEpoch else { continue }
                    preview = result
                    #if DEBUG
                    previewFrameCount += 1; presentedRecipe = next.recipe
                    #endif
                    if !next.interactive, pendingPreview == nil, next.generation == generation, showHistogram {
                        let stats = try await service.diagnostics(next.document,recipe: next.recipe)
                        if !Task.isCancelled, next.generation == generation { diagnostics = stats }
                    }
                } catch is CancellationError { break }
                catch { if next.generation == generation { errorMessage = error.localizedDescription } }
            }
        }
    }

}

extension EditorStore {
    func mutate(_ action: (inout EditRecipe) -> Void, commit: Bool = true) {
        guard document != nil, !isExporting else { return }
        action(&recipe); isComparing = false
        if commit { finishGesture() } else { requestRender() }
    }
    func autoTone() async {
        guard let service, let document else { return }
        let snapshot = recipe
        do {
            let result = try await service.analyze(document, recipe: snapshot)
            guard recipe == snapshot else { return }
            mutate { $0[.exposure] += result.suggestedExposure; $0[.highlights] -= result.highlights * 100; $0[.shadows] += result.shadows * 100 }
        } catch { errorMessage = error.localizedDescription }
    }
    func autoWhiteBalance() async {
        guard let service, let document else { return }
        let snapshot = recipe
        do {
            let result = try await service.analyze(document, recipe: snapshot)
            guard recipe == snapshot else { return }
            mutate { $0[.warmth] += result.suggestedWarmth; $0[.tint] += result.suggestedTint }
        } catch { errorMessage = error.localizedDescription }
    }
    func sampleWhiteBalance(at point: PhotoPoint) async {
        guard let service, let document else { return }
        let snapshot = recipe
        do {
            let (warmth,tint) = try await service.sampleWhiteBalance(document, recipe: displayRecipe, point: point)
            guard recipe == snapshot else { return }
            mutate { $0[.warmth] += warmth; $0[.tint] += tint }
        } catch { errorMessage = error.localizedDescription }
    }
    func addMask(_ kind: MaskKind) async {
        guard recipe.enhancements.masks.count < 32 else { errorMessage = "한 사진에 마스크를 최대 32개 만들 수 있습니다."; return }
        if kind == .object { activeMask = nil; pickingObject = true; return }
        guard let service, let document, !isAnalyzing else { return }
        isAnalyzing = true; defer { isAnalyzing = false }
        do {
            var mask: LocalMask
            if kind == .subject || kind == .background {
                let task = Task { try await service.makeSubjectMask(document,background: kind == .background) }; analysisTask = task
                mask = try await task.value; analysisTask = nil
            }
            else { mask = LocalMask(kind: kind); if kind == .brush { mask.points = [] } }
            mask.name = "\(kind.rawValue) \(recipe.enhancements.masks.count + 1)"
            let created = mask
            mutate { if $0.enhancements.masks.count < 32 { $0.enhancements.masks.append(created) } }
            activeMask = created.id
        } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }
    func editMask(_ action: (inout LocalMask) -> Void, commit: Bool = true) {
        guard let index = recipe.enhancements.masks.firstIndex(where: { $0.id == activeMask }) else { return }
        mutate({ action(&$0.enhancements.masks[index]) }, commit: commit)
    }
    func removeMask() { mutate { $0.enhancements.masks.removeAll { $0.id == activeMask } }; activeMask = nil }
    func setSpatialMode(_ enabled: Bool) { spatialMode = enabled; requestRender(immediate: true) }
    var displayRecipe: EditRecipe {
        var result = isComparing ? recipe.geometryOnly : recipe
        if previewSDR { result.enhancements.hdr = false }
        if cropMode { result.aspect = .original; result[.cropScale] = 100; result[.cropX] = 50; result[.cropY] = 50 }
        if spatialMode || pickingDepth {
            result.aspect = .original; result.quarterTurns = 0; result.flipHorizontal = false
            for key in [Adjustment.straighten, .cropScale, .cropX, .cropY, .perspectiveVertical, .perspectiveHorizontal, .lensDistortion] { result[key] = key.defaultValue }
        }
        return result
    }
    func loadDetail(at point: PhotoPoint) async {
        finishGesture()
        guard let service, let document else { return }
        do { detailPreview = try await service.renderDetail(document, center: point) }
        catch { errorMessage = error.localizedDescription }
    }
    func saveVersion(name: String) async {
        guard let service else { return }
        do { versions = try await service.saveVersion(name: name, recipe: recipe) }
        catch { errorMessage = error.localizedDescription }
    }
    func restoreVersion(_ version: EditVersion) { mutate { $0 = version.recipe } }
    func importPreset(_ url: URL) async {
        guard let service else { return }
        do { presets = try await service.importPreset(at: url) } catch { errorMessage = error.localizedDescription }
    }
    func exportPreset() async -> URL? {
        guard let service else { return nil }
        do { return try await service.exportPreset(recipe, name: "나의 프리셋") } catch { errorMessage = error.localizedDescription; return nil }
    }
    func deletePreset(_ id: UUID) async {
        guard let service else { return }
        do { presets = try await service.deletePreset(id) } catch { errorMessage = error.localizedDescription }
    }
}


extension EditorStore {
    func cancelAnalysis() { analysisTask?.cancel(); preparationTask?.cancel(); depthTask?.cancel(); removalTask?.cancel(); gainTask?.cancel() }
    func removeSelectedArea() async {
        guard let service,let document,let activeMask,!isAnalyzing else { return }
        isAnalyzing = true; defer { isAnalyzing = false; removalTask = nil }
        let snapshot = recipe
        let task = Task { try await service.removeSelection(document,recipe: snapshot,maskID: activeMask) }; removalTask = task
        do {
            let patch = try await task.value
            guard !task.isCancelled,recipe == snapshot else { await service.discardUncommittedRemoval(patch); return }
            mutate { $0.enhancements.removals = ($0.enhancements.removals ?? []) + [patch] }
            showMaskOverlay = false
        } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }
    func appendRemovalStroke(_ stroke: MaskStroke) {
        guard !isAnalyzing,!isComparing else { return }
        if !removalSelection.append(stroke) { errorMessage = "선택 영역이 너무 복잡합니다. 일부 영역을 먼저 실행하거나 비워 주세요." }
    }
    func runRemoval() async {
        guard let service,let document,!isAnalyzing,!isExporting,removalSelection.hasPaint else { return }
        finishGesture()
        let snapshot = recipe, selection = removalSelection
        isAnalyzing = true; defer { isAnalyzing = false; removalTask = nil }
        let task = Task { try await service.removeSelection(document,recipe: snapshot,selection: selection.mask) }
        removalTask = task
        do {
            let patch = try await task.value
            guard !task.isCancelled,recipe == snapshot,removalSelection == selection else {
                await service.discardUncommittedRemoval(patch); return
            }
            mutate { $0.enhancements.removals = ($0.enhancements.removals ?? []) + [patch] }
            removalSelection.clear()
        } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }
    func estimateDepth() async {
        guard let service,let document,!isAnalyzing else { return }
        isAnalyzing = true; defer { isAnalyzing = false; depthTask = nil }
        let snapshot = recipe
        let task = Task { try await service.estimateDepth(document) }; depthTask = task
        do {
            let result = try await task.value
            guard recipe == snapshot else { return }
            mutate { $0.enhancements.depth = result }
        } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }
    func chooseDepthFocus() { pickingDepth.toggle(); retry() }
    func focusDepth(at point: PhotoPoint) async {
        guard let service else { return }
        let snapshot = recipe
        do {
            let value = try await service.depthAtPoint(snapshot,point: point)
            guard recipe == snapshot else { return }
            mutate { $0.enhancements.depth?.focus = value }
        } catch { errorMessage = error.localizedDescription }
        pickingDepth = false; retry()
    }
    func prepareSelectionAssets() async {
        guard let service,!isAnalyzing else { return }
        isAnalyzing = true; defer { isAnalyzing = false; preparationTask = nil }
        let task = Task { try await service.prepareSelectionAssets() }; preparationTask = task
        do { try await task.value } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }
    func selectObject(at point: PhotoPoint) async {
        guard let service,let document,!isAnalyzing else { return }
        isAnalyzing = true; defer { isAnalyzing = false; analysisTask = nil }
        let previous = recipe.enhancements.masks.first { $0.id == activeMask && $0.kind == .object }
        guard previous != nil || recipe.enhancements.masks.count < 32 else { errorMessage = "한 사진에 마스크를 최대 32개 만들 수 있습니다."; return }
        var points = previous?.points ?? [], excluded = previous?.excludedPoints ?? []
        if excludeFromMask && previous != nil { excluded.append(point) } else { points.append(point) }
        let includePoints = points, excludePoints = excluded
        let task = Task { try await service.makePointMask(document,points: includePoints,excluding: excludePoints) }
        analysisTask = task
        do {
            let result = try await task.value
            if let previous {
                mutate { recipe in
                    guard let index = recipe.enhancements.masks.firstIndex(where: { $0.id == previous.id && $0.resourceID == previous.resourceID }) else { return }
                    recipe.enhancements.masks[index].resourceID = result.resourceID
                    recipe.enhancements.masks[index].points = includePoints
                    recipe.enhancements.masks[index].excludedPoints = excludePoints
                }
            } else { mutate { $0.enhancements.masks.append(result) }; activeMask = result.id }
            pickingObject = false
        } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }
}


extension EditorStore {
    func estimateHDRExpansion() async {
        finishGesture()
        guard let service, let document, !isAnalyzing, !isExporting, sourceDynamicRange == .sdr else { return }
        isAnalyzing = true
        defer { isAnalyzing = false; gainTask = nil }
        let snapshot = recipe
        let task = Task { try await service.estimateHDRExpansion(document, recipe: snapshot) }
        gainTask = task
        do {
            let result = try await task.value
            guard !task.isCancelled, recipe == snapshot, !isExporting else {
                await service.discardUncommittedGainMap(result)
                return
            }
            mutate { $0.enhancements.hdrExpansion = result; $0.enhancements.hdr = true }
        } catch is CancellationError { } catch { errorMessage = error.localizedDescription }
    }
}

extension EditorStore {
    func prepareExport(settings: ExportSettings) async throws -> PreparedExport {
        guard let service, let document else { throw EditorFailure.exportFailed }
        return try await service.prepareExport(document,settings: settings)
    }
    func copyPreparedExport(_ prepared: PreparedExport) async throws -> URL {
        guard let service else { throw EditorFailure.exportFailed }
        return try await service.copyPreparedExport(prepared)
    }
    func discardExport(_ url: URL) async { await service?.discardExport(url) }
}
