import CoreML
import Foundation

/// The camera cutout's person matte network: Core ML programs run in turn (backbone, context,
/// decoder, refiner) on a 1024×576 normalized RGB image, giving a 1024×576 matte.
final class PersonMatteNetwork: @unchecked Sendable {
    /// The bundled model.
    static let model = "pp-mattingv2-ss9-refined"
    /// How long a Neural Engine load may take (a first load compiles) before the GPU takes over.
    static let neuralEngineLoadTimeout: TimeInterval = 60
    /// One network loads at a time, so a first compile happens once.
    private static let firstUseLock = NSLock()

    private let backbone: MLModel
    private let context: MLModel
    private let decoder: MLModel
    private let refiner: MLModel

    /// `<resources>/PersonMatte/<model>`, nil where it is not bundled.
    static func bundledDirectory(model: String = model) -> URL? {
        let url = Bundle.module.resourceURL?.appendingPathComponent("PersonMatte", isDirectory: true).appendingPathComponent(model, isDirectory: true)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Whether the cutout's matte runs here: the bundled programs are present.
    static var isSupported: Bool { bundledDirectory() != nil }

    init(directory: URL) throws {
        func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
            let url = directory.appendingPathComponent(name + ".mlmodelc", isDirectory: true)
            guard FileManager.default.fileExists(atPath: url.path) else { throw MatteChunkError.message("No compiled matte program " + name) }
            return try Self.loadModel(at: url, units: units)
        }
        backbone = try load("backbone", .cpuAndNeuralEngine)
        context = try load("context", .cpuOnly)
        decoder = try load("decoder", .cpuAndNeuralEngine)
        refiner = try load("refiner", .cpuAndGPU)
    }

    private static func configuration(_ units: MLComputeUnits) -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = units
        var hints = configuration.optimizationHints
        hints.specializationStrategy = .fastPrediction
        configuration.optimizationHints = hints
        return configuration
    }

    /// Neural Engine loads run on a thread of their own; one that takes longer than the timeout
    /// gives way to the GPU.
    static func loadModel(at url: URL, units: MLComputeUnits) throws -> MLModel {
        guard units == .all || units == .cpuAndNeuralEngine else {
            return try MLModel(contentsOf: url, configuration: configuration(units))
        }
        final class LoadResult: @unchecked Sendable {
            let done = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var result: Result<MLModel, Error>?
        }
        let box = LoadResult()
        let thread = Thread {
            let loaded = Result { try MLModel(contentsOf: url, configuration: configuration(units)) }
            box.lock.lock()
            box.result = loaded
            box.lock.unlock()
            box.done.signal()
        }
        thread.start()
        if box.done.wait(timeout: .now() + neuralEngineLoadTimeout) == .success {
            box.lock.lock()
            let result = box.result
            box.lock.unlock()
            if let result { return try result.get() }
        }
        FileHandle.standardError.write(Data(("[PersonMatte] " + url.lastPathComponent + ": no Neural Engine load in " + String(Int(neuralEngineLoadTimeout)) + " s, on the GPU instead\n").utf8))
        return try MLModel(contentsOf: url, configuration: configuration(.cpuAndGPU))
    }

    /// Loads the bundled network and runs it once, holding the first-use lock.
    static func loadBundled() throws -> PersonMatteNetwork {
        guard let directory = bundledDirectory() else { throw MatteChunkError.message("The camera matte model is not bundled") }
        firstUseLock.lock()
        defer { firstUseLock.unlock() }
        let network = try PersonMatteNetwork(directory: directory)
        _ = try network.matte(try MLMultiArray(shape: [1, 3, NSNumber(value: FrameMatter.height), NSNumber(value: FrameMatter.width)], dataType: .float16))
        return network
    }

    private static func predict(_ model: MLModel, _ inputs: [String: MLFeatureValue]) throws -> MLFeatureProvider {
        try model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs))
    }

    /// `image`: [1, 3, 576, 1024] half floats, r, g, b in −1…1. Returns the [1, 1, 576, 1024] matte.
    func matte(_ image: MLMultiArray) throws -> MLMultiArray {
        let picture = MLFeatureValue(multiArray: image)
        let features = try Self.predict(backbone, ["image": picture])
        func value(_ provider: MLFeatureProvider, _ name: String) throws -> MLFeatureValue {
            guard let value = provider.featureValue(for: name) else { throw MatteChunkError.message("The matte network returned no " + name) }
            return value
        }
        let dpp = try value(Self.predict(context, ["mid": try value(features, "mid")]), "dpp")
        var decoderInputs: [String: MLFeatureValue] = ["image": picture, "dpp": dpp]
        for index in 0...4 { decoderInputs["f" + String(index)] = try value(features, "f" + String(index)) }
        let decoded = try Self.predict(decoder, decoderInputs)
        let refined = try Self.predict(refiner, ["image": picture, "alpha": try value(decoded, "alpha"), "hidden": try value(decoded, "hidden")])
        guard let matte = refined.featureValue(for: "matte")?.multiArrayValue else { throw MatteChunkError.message("The matte network returned no matte") }
        return matte
    }
}
