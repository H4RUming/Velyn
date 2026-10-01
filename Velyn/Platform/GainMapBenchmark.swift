#if DEBUG || GAIN_BENCHMARK_CLI
import Foundation
import CoreML

/// Explicit developer diagnostic. Uses generated tensors, never the photo library.
actor GainMapBenchmark {
    static let shared = GainMapBenchmark()
    private var started = false

    func runBundled() async {
        guard !started else { return }; started = true
        let destination = URL.documentsDirectory.appendingPathComponent("gain-benchmark.json")
        do {
            let urls = ["VelynGainMap", "VelynGainMap1024"].compactMap {
                Bundle.main.url(forResource: $0, withExtension: "mlmodelc")
            }
            try await run(urls: urls, destination: destination)
        } catch {
            try? Data(String(describing: error).utf8).write(to: destination.appendingPathExtension("error"))
        }
    }

    func run(urls: [URL], destination: URL) async throws {
        var rows = [[String: Any]]()
        for url in urls {
            var references = [[Float]]()
            for (name, units) in [("cpu", MLComputeUnits.cpuOnly), ("cpu-ne", .cpuAndNeuralEngine), ("all", .all), ("cpu-gpu", .cpuAndGPU)] {
                try Task.checkCancellation()
                var row: [String: Any] = ["model": url.lastPathComponent, "backend": name,
                    "thermalStart": ProcessInfo.processInfo.thermalState.rawValue]
                do {
                    let configuration = MLModelConfiguration(); configuration.computeUnits = units
                    let start = Date()
                    let model = try MLModel(contentsOf: url, configuration: configuration)
                    row["loadSeconds"] = Date().timeIntervalSince(start)
                    let shape = model.modelDescription.inputDescriptionsByName["image"]!.multiArrayConstraint!.shape
                    let size = shape[2].intValue
                    row["size"] = size
                    var measurements = [[String: Any]]()
                    for pattern in 0..<2 {
                        let inputs = try provider(size: size, pattern: pattern)
                        let warmStart = Date()
                        let first = try predict(model, inputs: inputs)
                        let warmSeconds = Date().timeIntervalSince(warmStart)
                        if units == .cpuOnly { references.append(first) }
                        guard references.count > pattern else { throw CocoaError(.fileReadCorruptFile) }
                        let reference = references[pattern]
                        var maxError: Float = 0, sumError: Double = 0
                        for i in first.indices {
                            let error = abs(first[i] - reference[i]); maxError = max(maxError, error); sumError += Double(error)
                        }
                        var timings = [Double]()
                        for _ in 0..<3 {
                            try Task.checkCancellation()
                            let tick = Date()
                            try infer(model, inputs: inputs)
                            timings.append(Date().timeIntervalSince(tick))
                        }
                        measurements.append(["pattern": pattern == 0 ? "constant-0.5" : "asymmetric-color-ramp",
                            "warmupSeconds": warmSeconds, "seconds": timings,
                            "finite": first.allSatisfy(\.isFinite), "minimum": first.min()!, "maximum": first.max()!,
                            "maxErrorEV": maxError, "meanErrorEV": sumError / Double(first.count),
                            "samples": [size/8, size/2, size*7/8].flatMap { y in
                                [size/8, size/2, size*7/8].map { x in first[y*size+x] }
                            }])
                    }
                    row["measurements"] = measurements
                    let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
                    var counts = [String: Int](), costs = [String: Double](), nonNE = [[String: Any]]()
                    func visit(_ block: MLModelStructure.Program.Block) {
                        for operation in block.operations {
                            if let usage = plan.deviceUsage(for: operation) {
                                let device: String
                                switch usage.preferred { case .cpu: device = "cpu"; case .gpu: device = "gpu"; case .neuralEngine: device = "neural-engine"; @unknown default: device = "unknown" }
                                counts[device, default: 0] += 1
                                costs[device, default: 0] += plan.estimatedCost(of: operation)?.weight ?? 0
                                if device != "neural-engine" {
                                    nonNE.append(["operator": operation.operatorName, "outputs": operation.outputs.map(\.name), "device": device])
                                }
                            }
                            for nested in operation.blocks { visit(nested) }
                        }
                    }
                    if case .program(let program) = plan.modelStructure {
                        for function in program.functions.values { visit(function.block) }
                    }
                    row["preferredOperationCounts"] = counts
                    row["estimatedCostByDevice"] = costs
                    row["nonNeuralEngineOperations"] = nonNE
                } catch is CancellationError { throw CancellationError() }
                catch { row["error"] = String(describing: error) }
                row["thermalEnd"] = ProcessInfo.processInfo.thermalState.rawValue
                rows.append(row)
                let report: [String: Any] = ["environment": ProcessInfo.processInfo.operatingSystemVersionString,
                    "syntheticInputsOnly": true, "results": rows]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .atomic)
            }
        }
    }

    private func provider(size: Int, pattern: Int) throws -> MLDictionaryFeatureProvider {
        func tensor(_ side: Int) throws -> MLMultiArray {
            let array = try MLMultiArray(shape: [1,3,NSNumber(value: side),NSNumber(value: side)], dataType: .float32)
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            for c in 0..<3 { for y in 0..<side { for x in 0..<side {
                pointer[c*side*side+y*side+x] = pattern == 0 ? 0.5 :
                    Float((x * (c+1) + y * (3-c)) % side) / Float(side-1)
            } } }
            return array
        }
        return try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: tensor(size)),
                                                            "thumbnail": MLFeatureValue(multiArray: tensor(256))])
    }

    private func predict(_ model: MLModel, inputs: MLDictionaryFeatureProvider) throws -> [Float] {
        let output = try model.prediction(from: inputs).featureValue(for: "log_gain")!.multiArrayValue!
        return (0..<output.count).map { output[$0].floatValue }
    }

    private func infer(_ model: MLModel, inputs: MLDictionaryFeatureProvider) throws {
        _ = try model.prediction(from: inputs)
    }
}

#if GAIN_BENCHMARK_CLI
@main struct GainBenchmarkCLI {
    static func main() async throws {
        try await GainMapBenchmark.shared.run(urls: CommandLine.arguments.dropFirst(2).map { URL(fileURLWithPath: $0) },
                                             destination: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
#endif
#endif
