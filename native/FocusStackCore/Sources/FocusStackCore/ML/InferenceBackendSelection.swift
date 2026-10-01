import Foundation

public enum MotionInferenceBackend:String,Codable,Sendable,CaseIterable {case cpu,cpuGPU,cpuANE,all,metalML}
public struct InferenceBackendMeasurement:Codable,Sendable {
    public let backend:MotionInferenceBackend,medianMS:Double,validated:Bool
    public init(backend:MotionInferenceBackend,medianMS:Double,validated:Bool){self.backend=backend;self.medianMS=medianMS;self.validated=validated}
}
public enum InferenceBackendSelection {
    public static func choose(_ measurements:[InferenceBackendMeasurement],neuralEngine:Bool,metalML:Bool)->MotionInferenceBackend? {
        measurements.filter{$0.validated && $0.medianMS.isFinite && $0.medianMS>0 && ($0.backend != .cpuANE || neuralEngine) && ($0.backend != .metalML || metalML)}.min{$0.medianMS<$1.medianMS}?.backend
    }
}
