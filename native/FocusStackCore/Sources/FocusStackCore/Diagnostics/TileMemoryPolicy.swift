import Foundation

public enum ApplePlatformMemoryClass: Sendable {
    case desktop, mobile
    public static var current: Self {
        #if os(iOS)
        return .mobile // iPhone + iPad; no UI dependency
        #else
        return .desktop
        #endif
    }
}

// Memory-only policy can be exercised on macOS for smaller mobile envelopes.
// Never keyed to chip marketing names. A future mobile host should lower budgets
// on memory pressure and react to lifecycle events outside this shared engine.
public struct TileMemoryPolicy: Sendable {
    public let platform: ApplePlatformMemoryClass
    public let physicalBytes: UInt64
    public let recommendedGPUBytes: UInt64
    public let residentBytes: UInt64
    public init(platform: ApplePlatformMemoryClass = .current, physicalBytes: UInt64,
                recommendedGPUBytes: UInt64, residentBytes: UInt64) {
        self.platform = platform; self.physicalBytes = physicalBytes
        self.recommendedGPUBytes = recommendedGPUBytes; self.residentBytes = residentBytes
    }
    public var reserveBytes: UInt64 {
        switch platform {
        case .desktop: return max(4*1024*1024*1024, physicalBytes/4)
        case .mobile: return max(512*1024*1024, physicalBytes*2/5)
        }
    }
    public var availableBudgetBytes: UInt64 {
        guard physicalBytes > reserveBytes, residentBytes < physicalBytes-reserveBytes else { return 0 }
        let available = physicalBytes-reserveBytes-residentBytes
        let gpuCap = platform == .desktop ? recommendedGPUBytes*3/4 : recommendedGPUBytes/4
        return min(available,gpuCap)
    }
    public var maximumInFlightTiles: Int { platform == .desktop ? 2 : 1 }
    public var preferredTileEdge: Int {
        let candidates = platform == .desktop ? [2048,1024,512,256,128] : [512,256,128]
        return candidates.first { UInt64($0*$0*128) <= availableBudgetBytes/2 } ?? 0
    }
    public func validate(edge: Int, inFlight: Int) throws {
        guard edge > 0, edge <= (platform == .desktop ? 2048 : 512),
              inFlight > 0, inFlight <= maximumInFlightTiles,
              UInt64(edge*edge*128*inFlight) < availableBudgetBytes else {
            throw NativeError.resource("Tile plan exceeds capability/platform memory envelope")
        }
    }
}
