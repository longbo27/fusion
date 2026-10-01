import Foundation
import Metal

// No CPU readback is required by this contract. The caller binds shared tensor GPU
// resources into an argument table and owns residency/lifetime until GPU completion.
// No model package/pipeline exists in Foundation, so no inference is dispatched.
public struct MetalMLBridge {
    public let capabilities: MetalCapabilities
    public init(capabilities: MetalCapabilities) { self.capabilities = capabilities }
    public var status: String {
        capabilities.machineLearningEncoder && capabilities.tensor ? "Tensor/ML encoder available. No production model loaded." : "ML path unavailable; standard Metal compute remains supported."
    }
    #if compiler(>=6.2)
    @available(macOS 26.0, iOS 26.0, *)
    public func makeTensor(device: any MTLDevice, width: Int, height: Int) throws -> any MTLTensor {
        guard capabilities.tensor, width > 0, height > 0, width <= 2048, height <= 2048 else {
            throw NativeError.unavailable("Bounded tensor path unavailable")
        }
        let descriptor = MTLTensorDescriptor()
        var values = [width,height]
        descriptor.dimensions = values.withUnsafeMutableBufferPointer { MTLTensorExtents(__rank: 2, values: $0.baseAddress!)! }
        descriptor.dataType = .float32; descriptor.usage = [.compute,.machineLearning]; descriptor.storageMode = .shared
        let tensor = try device.makeTensor(descriptor: descriptor)
        return tensor
    }
    @available(macOS 26.0, iOS 26.0, *)
    public func encode(command: any MTL4CommandBuffer, pipeline: any MTL4MachineLearningPipelineState,
                arguments: any MTL4ArgumentTable, intermediates: any MTLHeap) throws {
        guard capabilities.metal4, capabilities.machineLearningEncoder, capabilities.tensor,
              intermediates.size >= pipeline.intermediatesHeapSize,
              let encoder = command.makeMachineLearningCommandEncoder() else {
            throw NativeError.unavailable("ML encoder/resources unavailable")
        }
        encoder.setPipelineState(pipeline); encoder.setArgumentTable(arguments)
        encoder.dispatchNetwork(intermediatesHeap: intermediates); encoder.endEncoding()
    }
    #endif
}
