import Metal
import Foundation

// Ownership stays inside the scheduler actor; immutable setup is never mutated by UI.
public final class MetalContext {
    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    public let capabilities: MetalCapabilities
    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(maxCommandBufferCount: 2) else {
            throw NativeError.unavailable("Metal GPU unavailable")
        }
        self.device = device; self.queue = queue
        capabilities = MetalCapabilities.detect(device)
    }
}
