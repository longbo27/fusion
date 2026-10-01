import Foundation
import CoreML

public struct MLHardwareInspector: Sendable {
    public let devices: [String]
    public let neuralEngineDetected: Bool
    public init() {
        if #available(macOS 14.0, iOS 17.0, *) {
            let all = MLComputeDevice.allComputeDevices
            devices = all.map { Self.label($0) }
            neuralEngineDetected = all.contains { if case .neuralEngine = $0 { return true }; return false }
        } else { devices = ["Enumeration unavailable (requires macOS 14)"]; neuralEngineDetected = false }
    }
    @available(macOS 14.0, iOS 17.0, *)
    public static func label(_ device: MLComputeDevice) -> String {
        switch device {
        case .cpu: return "CPU"
        case .gpu(let gpu): return "GPU: \(gpu.metalDevice.name)"
        case .neuralEngine(let ane): return "Apple Neural Engine (\(ane.totalCoreCount) cores)"
        @unknown default: return "Unknown compute device"
        }
    }
}
