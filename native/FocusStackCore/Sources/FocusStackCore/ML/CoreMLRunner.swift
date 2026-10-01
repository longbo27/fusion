import CoreML
import Foundation

// Model ownership never crosses isolation; no model is shipped or silently selected.
public actor CoreMLRunner {
    public init() {}
    private var model: MLModel?
    public static func configuration() -> MLModelConfiguration {
        let config = MLModelConfiguration(); config.computeUnits = .all; return config
    }
    public func load(compiledModelURL: URL) throws {
        model = try MLModel(contentsOf: compiledModelURL, configuration: Self.configuration())
    }
    public func status() -> String { model == nil ? "No production model loaded." : "Model loaded; execution placement requires compute-plan inspection." }
}
