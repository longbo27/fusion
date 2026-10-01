import Foundation
import Metal
import QuartzCore

public actor GPUTilePipeline {
    private let memoryClass: ApplePlatformMemoryClass
    private let context: MetalContext
    private let cache: PipelineCache
    private let pool: BufferPool
    private let timing: CounterTiming
    public init(memoryClass: ApplePlatformMemoryClass = .current) throws {
        self.memoryClass = memoryClass
        let context = try MetalContext()
        self.context = context; cache = try PipelineCache(device: context.device)
        pool = try BufferPool(capacity: 1)
        timing = CounterTiming(device: context.device)
    }
    public func diagnostics() -> (capabilities: MetalCapabilities, allocations: Int, highWater: Int) {
        (context.capabilities, pool.allocations, pool.highWater)
    }
    public func validateDescriptor(_ d: TileDescriptor) throws {
        let policy = TileMemoryPolicy(platform: memoryClass,physicalBytes: ProcessInfo.processInfo.physicalMemory,
            recommendedGPUBytes: context.capabilities.recommendedWorkingSet,
            residentBytes: MemoryMonitor.snapshot().residentBytes)
        try policy.validate(edge: max(d.width,d.height),inFlight: 1)
        guard d.estimatedWorkingBytes < MemoryMonitor.budget(recommended: context.capabilities.recommendedWorkingSet) else {
            throw NativeError.resource("Insufficient memory headroom after OS reserve/current RSS/codec margin")
        }
    }
    // This intentionally does not suspend while holding a lease. Actor calls serialize
    // with backpressure; app gates submissions, queue and pool independently cap GPU work.
    public func run(_ tile: RGB16Tile) throws -> GPUResult {
        try Task.checkCancellation()
        let d = tile.descriptor
        try validateDescriptor(d)
        let r = try pool.acquire(device: context.device, descriptor: d)
        defer { pool.release(r) }
        let start = CACurrentMediaTime()
        tile.rgba.withUnsafeBytes {
            r.source.replace(region: MTLRegionMake2D(0,0,d.width,d.height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: d.width*8)
        }
        let uploadMS = (CACurrentMediaTime()-start)*1000
        func execute(_ pipeline: any MTLComputePipelineState, _ bind: (any MTLComputeCommandEncoder) -> Void) throws -> (ms: Double, method: String) {
            guard let command = context.queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder(descriptor: timing.pass(device: context.device)) else {
                throw NativeError.resource("Command encoding failed")
            }
            encoder.setComputePipelineState(pipeline); bind(encoder)
            let width = pipeline.threadExecutionWidth
            let height = min(8, pipeline.maxTotalThreadsPerThreadgroup/width)
            encoder.dispatchThreads(MTLSize(width: d.width,height: d.height,depth: 1),
                threadsPerThreadgroup: MTLSize(width: width,height: height,depth: 1))
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            guard command.status == .completed else { throw NativeError.resource(command.error?.localizedDescription ?? "GPU failed") }
            return timing.resolve(device: context.device,command: command)
        }
        // Separate buffers give honest per-stage GPU timestamps for foundation benchmarks.
        // Three serial command buffers, maximum one outstanding; batching is a later optimization.
        let copyMS = try execute(cache.copy) { $0.setTexture(r.source,index: 0); $0.setTexture(r.copied,index: 1) }
        let luminanceMS = try execute(cache.luminance) { $0.setTexture(r.copied,index: 0); $0.setBuffer(r.luminance,offset: 0,index: 0) }
        var size = SIMD2<UInt32>(UInt32(d.width),UInt32(d.height))
        let focusMS = try execute(cache.focus) {
            $0.setBuffer(r.luminance,offset: 0,index: 0); $0.setBuffer(r.gradients,offset: 0,index: 1)
            $0.setBytes(&size,length: MemoryLayout<SIMD2<UInt32>>.size,index: 2)
        }
        let readStart = CACurrentMediaTime()
        let l = Array(UnsafeBufferPointer(start: r.luminance.contents().assumingMemoryBound(to: Float.self),count: d.pixelCount))
        let g = Array(UnsafeBufferPointer(start: r.gradients.contents().assumingMemoryBound(to: SIMD4<Float>.self),count: d.pixelCount))
        var copied = [UInt16](repeating: 0,count: tile.rgba.count)
        copied.withUnsafeMutableBytes { r.copied.getBytes($0.baseAddress!,bytesPerRow: d.width*8,
            from: MTLRegionMake2D(0,0,d.width,d.height),mipmapLevel: 0) }
        let readMS = (CACurrentMediaTime()-readStart)*1000
        let wallMS = (CACurrentMediaTime()-start)*1000
        let cpuStart = CACurrentMediaTime(), cpu = CPUReference.run(tile)
        let cpuMS = (CACurrentMediaTime()-cpuStart)*1000
        var le: Float = 0, ge: Float = 0, ee: Float = 0
        var checksum: Double = 0
        for i in 0..<d.pixelCount {
            le = max(le,abs(l[i]-cpu.luminance[i])); ge = max(ge,max(abs(g[i].x-cpu.gradients[i].x),abs(g[i].y-cpu.gradients[i].y)))
            ee = max(ee,abs(g[i].z-cpu.gradients[i].z)); checksum += Double(g[i].z)
        }
        guard copied == tile.rgba, le <= CPUReference.luminanceTolerance,
              ge <= CPUReference.gradientTolerance, ee <= CPUReference.energyTolerance else {
            throw NativeError.invalid("GPU numerical validation failed: \(le), \(ge), \(ee)")
        }
        let report = BenchmarkReport(tileWidth: d.width,tileHeight: d.height,device: context.device.name,
            uploadMS: uploadMS,luminanceMS: luminanceMS.ms,focusMS: focusMS.ms,readbackMS: readMS,
            gpuTotalMS: copyMS.ms+luminanceMS.ms+focusMS.ms,pipelineWallMS: wallMS,cpuReferenceMS: cpuMS,
            luminanceMaxError: le,gradientMaxError: ge,energyMaxError: ee,checksum: checksum,
            memory: MemoryMonitor.snapshot(),metalAllocatedBytes: UInt64(context.device.currentAllocatedSize),
            estimatedTileBytes: d.estimatedWorkingBytes,
            timingMethod: [copyMS.method,luminanceMS.method,focusMS.method].allSatisfy { $0 == copyMS.method } ? copyMS.method+" (GPU total includes copy); upload/readback CPU wall" : "Mixed stage timing with command-buffer fallback; upload/readback CPU wall")
        return GPUResult(luminance: l,gradients: g,copied: copied,report: report)
    }
}
