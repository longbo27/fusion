import Foundation
import Metal

public struct MetalCapabilities: Sendable {
    public let currentAllocatedBytes: UInt64
    public let deviceName: String
    public let unifiedMemory: Bool
    public let recommendedWorkingSet: UInt64
    public let maxBufferLength: Int
    public let maxThreadgroupMemory: Int
    public let maximumValidatedTextureExtent = 2048
    public let maxThreadgroup: String
    public let families: [String]
    public let metal4: Bool
    public let tensor: Bool
    public let machineLearningEncoder: Bool
    public let probeNotes: String
    public static func detect(_ device: any MTLDevice) -> MetalCapabilities {
        let candidates: [(String, MTLGPUFamily)] = [("Apple7", .apple7), ("Apple8", .apple8), ("Apple9", .apple9), ("Mac2", .mac2), ("Common3", .common3), ("Metal3", .metal3)]
        var families = candidates.filter { device.supportsFamily($0.1) }.map { $0.0 }
        var metal4 = false, tensor = false, encoder = false
        var notes = "Metal 4 requires macOS 26+ and SDK Swift compiler 6.2+"
        #if compiler(>=6.2)
        if #available(macOS 26.0, iOS 26.0, *) {
            metal4 = device.supportsFamily(.metal4)
            if metal4 { families.append("Metal4") }
            // Probe a minimal real resource; symbol availability is insufficient.
            let descriptor = MTLTensorDescriptor()
            var extents = [16, 16]
            descriptor.dimensions = extents.withUnsafeMutableBufferPointer { MTLTensorExtents(__rank: 2, values: $0.baseAddress!)! }
            descriptor.dataType = .float32
            descriptor.usage = [.compute, .machineLearning]
            descriptor.storageMode = .shared
            do { _ = try device.makeTensor(descriptor: descriptor); tensor = true }
            catch { notes = "Tensor probe: \(error.localizedDescription)" }
            if metal4, let command = device.makeCommandBuffer(), let allocator = try? device.makeCommandAllocator(descriptor: MTL4CommandAllocatorDescriptor()) {
                command.beginCommandBuffer(allocator: allocator)
                if let ml = command.makeMachineLearningCommandEncoder() { encoder = true; ml.endEncoding() }
                command.endCommandBuffer()
            }
            if tensor { notes = "Real 16×16 Float32 ML/compute tensor allocated; ML encoder construction \(encoder ? "succeeded" : "unavailable"). No model dispatched." }
        }
        #endif
        return MetalCapabilities(currentAllocatedBytes: UInt64(device.currentAllocatedSize),deviceName: device.name, unifiedMemory: device.hasUnifiedMemory,
            recommendedWorkingSet: device.recommendedMaxWorkingSetSize, maxBufferLength: device.maxBufferLength,
            maxThreadgroupMemory: device.maxThreadgroupMemoryLength,
            maxThreadgroup: "\(device.maxThreadsPerThreadgroup.width) × \(device.maxThreadsPerThreadgroup.height) × \(device.maxThreadsPerThreadgroup.depth)",
            families: families, metal4: metal4, tensor: tensor, machineLearningEncoder: encoder, probeNotes: notes)
    }
    public static func choosePath(metal4: Bool, tensor: Bool, encoder: Bool, modelLoaded: Bool) -> String {
        metal4 && tensor && encoder && modelLoaded ? "Metal ML eligible; model execution must be validated" : "Standard Metal compute; no production model loaded"
    }
}
