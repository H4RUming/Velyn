import Foundation
import CoreML
import CoreImage
import ImageIO

extension EditingService {
    public func sourceDynamicRange() throws -> SourceDynamicRange {
        if asset.isRAW { return .raw }
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil) else { throw EditorFailure.renderFailed }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        for type in [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap] {
            if CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, index, type) != nil { return .hdr }
        }
        guard let image = CIImage(contentsOf: original, options: [.expandToHDR: true]) else { throw EditorFailure.renderFailed }
        return image.contentHeadroom > 1.01 ? .hdr : .sdr
    }

    /// GMNet real-world weights are bundled; inference never downloads or transmits photos.
    public func estimateHDRExpansion(_ document: EditDocument, recipe: EditRecipe, modelURL: URL? = nil) throws -> HDRExpansion {
        try Task.checkCancellation()
        guard recipe.isValid else { throw EditorFailure.invalidDocument }
        guard try sourceDynamicRange() == .sdr else { throw EditorFailure.hdrExpansionRequiresSDR }
        let model = try gainModel(override: modelURL)
        let size = try GainModelCalibration.sideLength(model)
        // Use the same color/retouch state that the map will multiply, before geometry.
        let base = recipe.gainPredictionBase
        let image = try processed(document, recipe: base, maxPixelSize: 1536)
        let scale = Double(size) / max(image.extent.width, image.extent.height)
        let width = max(1, Int((image.extent.width * scale).rounded()))
        let height = max(1, Int((image.extent.height * scale).rounded()))
        let left = (size - width) / 2, bottom = (size - height) / 2
        let valid = CGRect(x: left, y: bottom, width: width, height: height)
        let local = image.transformed(by: CGAffineTransform(scaleX: Double(width)/image.extent.width, y: Double(height)/image.extent.height))
            .transformed(by: CGAffineTransform(translationX: CGFloat(left), y: CGFloat(bottom))).clampedToExtent()
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        let thumbnail = image.transformed(by: CGAffineTransform(scaleX: 256/image.extent.width, y: 256/image.extent.height))
        let inputs = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(multiArray: gainMapTensor(local, size: size)),
            "thumbnail": MLFeatureValue(multiArray: gainMapTensor(thumbnail, size: 256))
        ])
        try Task.checkCancellation()
        let output = try model.prediction(from: inputs)
        try Task.checkCancellation()
        guard let tensor = output.featureValue(for: "log_gain")?.multiArrayValue,
              tensor.shape.map(\.intValue) == [1, 1, size, size] else { throw EditorFailure.renderFailed }
        var rawMinimum = Float.infinity,rawMaximum = -Float.infinity
        var samples = [Float](repeating: 0, count: size*size)
        let strides = tensor.strides.map(\.intValue)
        for y in 0..<size {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in 0..<size {
                let value = tensor[y*strides[2]+x*strides[3]].floatValue
                guard value.isFinite else { throw EditorFailure.renderFailed }
                rawMinimum = min(rawMinimum,value); rawMaximum = max(rawMaximum,value)
                samples[y*size+x] = min(1, max(0, value/log2(Float(5))))
            }
        }
        let map = CIImage(bitmapData: samples.withUnsafeBytes { Data($0) }, bytesPerRow: size*4,
                          size: CGSize(width: size,height: size), format: .Rf, colorSpace: nil)
        let cropped = RenderPipeline.normalized(map.cropped(to: valid))
        let protectionBlend = try gainProtectionBlend(image)
        let id = try storeGainMap(cropped)
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--editor-smoke-test") {
            var probe = [Float](repeating: 0,count: width*height*4)
            probe.withUnsafeMutableBytes { context.render(cropped,toBitmap: $0.baseAddress!,rowBytes: width*16,bounds: cropped.extent,format: .RGBAf,colorSpace: RenderPipeline.linearSpace) }
            let values = stride(from: 0,to: probe.count,by: 4).map { probe[$0] }
            let report: [String: Any] = ["rawMin": rawMinimum,"rawMax": rawMaximum,"tensorMin": samples.min() ?? -1,"tensorMax": samples.max() ?? -1,
                "tensorMean": samples.reduce(0,+)/Float(samples.count),"ciMapMin": values.min() ?? -1,"ciMapMax": values.max() ?? -1]
            try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("gain-inference-debug.json"))
        }
        #endif
        var expansion = HDRExpansion(resourceID: id)
        expansion.predictionFingerprint = recipe.gainPredictionFingerprint
        expansion.protectionBlend = protectionBlend
        expansion.edgeAwareUpsampling = true
        return expansion
    }

    /// Check against a pinned PyTorch conversion reference before trusting a backend.
    /// GPU execution can return a correctly shaped but invalid all-zero tensor.
    private func gainModel(override: URL?) throws -> MLModel {
        if let override { return try checkedGainModel(at:override,useCache:false) }
        if let cached = gainMapModel { return cached }
        // Avoid paying for a larger tensor on small originals or CPU-only devices.
        // The mixed-precision model keeps its small global branch on CPU.
        let hasNeuralEngine = MLComputeDevice.allComputeDevices.contains { if case .neuralEngine = $0 { return true }; return false }
        if hasNeuralEngine, max(asset.pixelWidth,asset.pixelHeight) >= 1024,
           let high = Bundle.main.url(forResource:"VelynGainMap1024",withExtension:"mlmodelc") {
            do { return try checkedGainModel(at:high,useCache:true,backends:[.cpuAndNeuralEngine]) }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation() }
        }
        guard let standard = Bundle.main.url(forResource:"VelynGainMap",withExtension:"mlmodelc") else { throw EditorFailure.modelUnavailable }
        return try checkedGainModel(at:standard,useCache:true)
    }

    private func checkedGainModel(at url: URL,useCache: Bool,backends: [MLComputeUnits] = [.cpuAndNeuralEngine,.cpuAndGPU,.cpuOnly]) throws -> MLModel {
        if useCache,let cached = gainMapModel { return cached }
        for units in backends {
            try Task.checkCancellation()
            do {
                let configuration = MLModelConfiguration(); configuration.computeUnits = units
                let candidate = try MLModel(contentsOf: url,configuration: configuration)
                let size = try GainModelCalibration.sideLength(candidate)
                var passed = true
                for pattern in 0..<2 {
                    let output = try candidate.prediction(from: GainModelCalibration.input(size:size,pattern:pattern))
                    try Task.checkCancellation()
                    guard let values = output.featureValue(for:"log_gain")?.multiArrayValue,
                          GainModelCalibration.accepts(values,size:size,pattern:pattern) else { passed = false; break }
                }
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--editor-smoke-test") {
                    let name = units == .cpuOnly ? "cpu" : units == .cpuAndNeuralEngine ? "cpu-ne" : "cpu-gpu"
                    let report: [String: Any] = ["backend": name,"passed": passed,"size": size]
                    try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: root.appendingPathComponent("gain-backend-\(name).json"))
                }
                #endif
                if passed { if useCache { gainMapModel = candidate }; return candidate }
            } catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); continue }
        }
        throw EditorFailure.gainModelValidation
    }

    func gainMapTensor(_ image: CIImage, size: Int) throws -> MLMultiArray {
        var bytes = [UInt8](repeating: 0, count: size*size*4)
        bytes.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: size*4,
                           bounds: CGRect(x: 0,y: 0,width: size,height: size), format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        }
        let tensor = try MLMultiArray(shape: [1,3,NSNumber(value: size),NSNumber(value: size)], dataType: .float32)
        let pointer = tensor.dataPointer.bindMemory(to: Float.self, capacity: tensor.count)
        for channel in 0..<3 {
            for i in 0..<size*size { pointer[channel*size*size+i] = Float(bytes[i*4+channel])/255 }
        }
        return tensor
    }

    /// Numeric 16-bit samples are read with color management disabled.
    func storeGainMap(_ map: CIImage) throws -> UUID {
        let directory = package.appendingPathComponent("masks")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw EditorFailure.invalidDocument }
        let id = UUID(), staging = directory.appendingPathComponent(".\(UUID()).png"), final = directory.appendingPathComponent("\(id).png")
        defer { try? FileManager.default.removeItem(at: staging) }
        try context.writePNGRepresentation(of: GainMapPipeline.scalarMap(map), to: staging, format: .RGBA16,
                                            colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: staging, to: final)
        if Task.isCancelled { try? FileManager.default.removeItem(at: final); throw CancellationError() }
        return id
    }

    /// Only for a newly generated result that has never been committed to history.
    public func discardUncommittedGainMap(_ expansion: HDRExpansion) {
        try? FileManager.default.removeItem(at: package.appendingPathComponent("masks/\(expansion.resourceID).png"))
    }
}

struct GainMapPipeline {
    /// Rf stores (R, 0, 0, 1), not grayscale. The red channel is the numeric
    /// log-gain sample. Broadcast it before curves/multiplication, including
    /// for older PNG maps that were saved with empty green and blue channels.
    static func scalarMap(_ map: CIImage) -> CIImage {
        let red = CIVector(x: 1,y: 0,z: 0,w: 0)
        return map.applyingFilter("CIColorMatrix",parameters: [
            "inputRVector": red,"inputGVector": red,"inputBVector": red,
            "inputAVector": CIVector(x: 0,y: 0,z: 0,w: 0),
            "inputBiasVector": CIVector(x: 0,y: 0,z: 0,w: 1)
        ]).cropped(to: map.extent)
    }

    static func apply(_ image: CIImage, map: CIImage, expansion: HDRExpansion) -> CIImage {
        guard expansion.strength > 0, expansion.maximumBoostEV > 0 else { return image }
        var resized = scalarMap(map).transformed(by: CGAffineTransform(scaleX: image.extent.width/map.extent.width,
                                                           y: image.extent.height/map.extent.height))
            .transformed(by: CGAffineTransform(translationX: image.extent.minX,y: image.extent.minY))
            .cropped(to: image.extent)
        if expansion.edgeAwareUpsampling == true && image.extent.width > map.extent.width && image.extent.height > map.extent.height {
            let guide = RenderPipeline.normalized(image)
            let refined = guide.applyingFilter("CIEdgePreserveUpsampleFilter",parameters: [
                "inputSmallImage": RenderPipeline.normalized(scalarMap(map)),
                "inputSpatialSigma": 3.0,"inputLumaSigma": 0.15
            ])
            resized = scalarMap(refined).transformed(by: .init(translationX: image.extent.minX,y: image.extent.minY)).cropped(to: image.extent)
                .applyingFilter("CIColorClamp",parameters: ["inputMinComponents":CIVector(x:0,y:0,z:0,w:1),"inputMaxComponents":CIVector(x:1,y:1,z:1,w:1)])
        }
        if expansion.protectMidtones == true {
            // Scalar luminance gating preserves RGB ratios; it does not infer missing detail.
            let luma = CIVector(x: 0.2126,y: 0.7152,z: 0.0722,w: 0)
            let luminance = image.applyingFilter("CIColorMatrix",parameters: ["inputRVector": luma,"inputGVector": luma,"inputBVector": luma,
                "inputAVector": CIVector(x: 0,y: 0,z: 0,w: 0),"inputBiasVector": CIVector(x: 0,y: 0,z: 0,w: 1)])
                .applyingFilter("CIColorClamp",parameters: ["inputMinComponents": CIVector(x: 0,y: 0,z: 0,w: 1),"inputMaxComponents": CIVector(x: 1,y: 1,z: 1,w: 1)])
            var protection = [Float]()
            for i in 0..<1024 {
                let value = Float(GainMapTonePolicy.protection(luminance:Double(i)/1023,blend:expansion.protectionBlend ?? 0))
                protection += [value,value,value]
            }
            let gate = luminance.applyingFilter("CIColorCurves",parameters: ["inputCurvesData": protection.withUnsafeBytes { Data($0) },
                "inputCurvesDomain": CIVector(x: 0,y: 1),"inputColorSpace": RenderPipeline.linearSpace])
            resized = resized.applyingFilter("CIMultiplyCompositing",parameters: [kCIInputBackgroundImageKey: gate])
        }
        var table = [Float]()
        for i in 0..<1024 {
            let gain = Float(exp2(min(Double(i)/1023 * log2(5) * expansion.strength, expansion.maximumBoostEV)))
            table += [gain,gain,gain]
        }
        let gain = resized.applyingFilter("CIColorCurves", parameters: [
            "inputCurvesData": table.withUnsafeBytes { Data($0) },
            "inputCurvesDomain": CIVector(x: 0,y: 1), "inputColorSpace": RenderPipeline.linearSpace
        ])
        return image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gain]).cropped(to: image.extent)
    }
}
