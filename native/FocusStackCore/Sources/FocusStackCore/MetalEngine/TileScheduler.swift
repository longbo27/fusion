import Foundation

// Producer-facing entry point: admits a descriptor BEFORE decoding. A second
// producer gets explicit backpressure, never an unbounded queue of RGB16 tiles.
public actor TileScheduler {
    private let pipeline: GPUTilePipeline
    private var busy = false
    public init(memoryClass: ApplePlatformMemoryClass = .current) throws { pipeline = try GPUTilePipeline(memoryClass: memoryClass) }
    public func processPrototype(provider: any TileProvider, descriptor: TileDescriptor) async throws -> BenchmarkReport {
        guard !busy else { throw NativeError.resource("Tile scheduler busy; await the current tile before submitting another") }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        try await pipeline.validateDescriptor(descriptor)
        let tile = try await provider.read(descriptor)
        let result = try await pipeline.run(tile)
        return result.report
    }
}
