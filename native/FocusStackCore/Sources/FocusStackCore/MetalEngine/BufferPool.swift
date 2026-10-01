import Metal

// Internal to GPU scheduler: synchronous lease ownership avoids actor reentrancy races.
// One idle resource replaces the previous dimension; no per-source/dimension accumulation.
public final class BufferPool {
    public let capacity: Int
    private var idle: TileResources?
    public private(set) var inFlight = 0
    public private(set) var highWater = 0
    public private(set) var allocations = 0
    public init(capacity: Int = 1) throws {
        guard (1...2).contains(capacity) else { throw NativeError.invalid("Only 1–2 in-flight tiles supported") }
        self.capacity = capacity
    }
    public func acquire(device: any MTLDevice, descriptor: TileDescriptor) throws -> TileResources {
        guard inFlight < capacity else { throw NativeError.resource("Tile capacity reached; backpressure required") }
        let result: TileResources
        if let available = idle, available.descriptor.width == descriptor.width, available.descriptor.height == descriptor.height {
            result = available; idle = nil
        } else { idle = nil; result = try TileResources(device: device, descriptor: descriptor); allocations += 1 }
        inFlight += 1; highWater = max(highWater, inFlight)
        return result
    }
    public func release(_ resource: TileResources) { precondition(inFlight > 0); inFlight -= 1; idle = resource }
}
