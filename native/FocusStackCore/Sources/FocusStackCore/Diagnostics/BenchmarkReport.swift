import Foundation

public struct BenchmarkReport: Codable, Sendable {
    public let tileWidth: Int, tileHeight: Int, device: String
    public let uploadMS: Double, luminanceMS: Double, focusMS: Double, readbackMS: Double
    public let gpuTotalMS: Double, pipelineWallMS: Double, cpuReferenceMS: Double
    public let luminanceMaxError: Float, gradientMaxError: Float, energyMaxError: Float
    public let checksum: Double
    public let memory: MemorySnapshot
    public let metalAllocatedBytes: UInt64, estimatedTileBytes: UInt64
    public let timingMethod: String
}
public struct GPUResult: Sendable {
    public let luminance: [Float]
    public let gradients: [SIMD4<Float>]
    public let copied: [UInt16]
    public let report: BenchmarkReport
}
