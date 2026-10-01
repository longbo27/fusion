import Foundation
import Metal
import Vision

public struct HardwareReport: Sendable {
    public let model: String, chip: String, architecture: String, os: String
    public let physicalBytes: UInt64
    public let metal: MetalCapabilities?
    public let ml: MLHardwareInspector
    public let memory: MemorySnapshot
    public var recommendedBudget: UInt64 { metal.map { MemoryMonitor.budget(recommended: $0.recommendedWorkingSet) } ?? 0 }
    public static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name,nil,&size,nil,0) == 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0,count: size)
        guard sysctlbyname(name,&bytes,&size,nil,0) == 0 else { return "unknown" }
        return bytes.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
    public static func collect() -> HardwareReport {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unsupported architecture"
        #endif
        return HardwareReport(model: sysctlString("hw.model"),chip: sysctlString("machdep.cpu.brand_string"),
            architecture: architecture,os: ProcessInfo.processInfo.operatingSystemVersionString,
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            metal: MTLCreateSystemDefaultDevice().map { MetalCapabilities.detect($0) },ml: MLHardwareInspector(),memory: MemoryMonitor.snapshot())
    }
    public var text: String {
        let m = metal
        return "Model: \(model)\nChip: \(chip)\nArchitecture: \(architecture)\nOS: \(os)\nPhysical memory: \(physicalBytes) bytes\nMetal: \(m?.deviceName ?? "unavailable")\nUnified memory: \(m?.unifiedMemory.description ?? "unknown")\nRecommended working set: \(m?.recommendedWorkingSet ?? 0) bytes\nMax buffer: \(m?.maxBufferLength ?? 0) bytes\nThreadgroup memory: \(m?.maxThreadgroupMemory ?? 0) bytes\nTexture extent: validated 2048²; public MTLDevice exposes no maximum 2D dimension query\nMax threadgroup dimensions (not product): \(m?.maxThreadgroup ?? "unknown")\nFamilies: \(m?.families.joined(separator: ", ") ?? "none")\nMetal 4: \(m?.metal4 ?? false)\nTensor: \(m?.tensor ?? false)\nML encoder: \(m?.machineLearningEncoder ?? false)\nProbe: \(m?.probeNotes ?? "none")\nCore ML: \(ml.devices.joined(separator: ", "))\nANE detected: \(ml.neuralEngineDetected)\nNo production model loaded."
    }
}
