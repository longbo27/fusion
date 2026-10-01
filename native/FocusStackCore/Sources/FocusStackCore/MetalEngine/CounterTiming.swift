import Foundation
import Metal

// A single reusable pair of counter samples, owned by the serial GPU actor.
public final class CounterTiming {
    public let samples: (any MTLCounterSampleBuffer)?
    private var cpuStart: UInt64 = 0, gpuStart: UInt64 = 0
    public init(device: any MTLDevice) {
        if device.supportsCounterSampling(.atStageBoundary),
           let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }) {
            let descriptor = MTLCounterSampleBufferDescriptor()
            descriptor.counterSet = set; descriptor.storageMode = .shared
            descriptor.sampleCount = 2; descriptor.label = "FocusStack bounded stage timing"
            samples = try? device.makeCounterSampleBuffer(descriptor: descriptor)
        } else { samples = nil }
    }
    public func pass(device: any MTLDevice) -> MTLComputePassDescriptor {
        let pass = MTLComputePassDescriptor()
        if let samples {
            pass.sampleBufferAttachments[0].sampleBuffer = samples
            pass.sampleBufferAttachments[0].startOfEncoderSampleIndex = 0
            pass.sampleBufferAttachments[0].endOfEncoderSampleIndex = 1
            let start = device.sampleTimestamps(); cpuStart = start.cpu; gpuStart = start.gpu
        }
        return pass
    }
    public func resolve(device: any MTLDevice, command: any MTLCommandBuffer) -> (ms: Double, method: String) {
        var cpuEnd: UInt64 = 0, gpuEnd: UInt64 = 0
        if let samples {
            let end = device.sampleTimestamps(); cpuEnd = end.cpu; gpuEnd = end.gpu
            if let data = try? samples.resolveCounterRange(0..<2), data.count >= 16 {
                let start = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0,as: UInt64.self) }
                let end = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8,as: UInt64.self) }
                if start != MTLCounterErrorValue, end != MTLCounterErrorValue,
                   end > start, cpuEnd > cpuStart, gpuEnd > gpuStart {
                    // sampleTimestamps CPU values are nanoseconds; calibrate clocks rather
                    // than assuming raw GPU ticks have nanosecond units on every chip.
                    let ratio = Double(cpuEnd-cpuStart)/Double(gpuEnd-gpuStart)
                    let ms = Double(end-start)*ratio/1_000_000
                    if ms.isFinite && ms > 0 { return (ms,"MTLCounterSampleBuffer stage timestamps; CPU/GPU clock calibrated") }
                }
            }
        }
        return ((command.gpuEndTime-command.gpuStartTime)*1000,"Command-buffer GPU timestamps (counter sampling unavailable/invalid)")
    }
}
