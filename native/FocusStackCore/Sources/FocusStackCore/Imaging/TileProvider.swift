import Foundation

public struct TileDescriptor: Hashable, Sendable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(x: Int = 0, y: Int = 0, width: Int, height: Int) throws {
        guard x >= 0, y >= 0, width > 0, height > 0, width <= 2048, height <= 2048 else {
            throw NativeError.invalid("Tile extent must be 1...2048 with nonnegative global origin")
        }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var pixelCount: Int { width * height }
    // Source, exact copy, luminance, gx/gy/energy, readback + CPU reference + packing margin.
    public var estimatedWorkingBytes: UInt64 { UInt64(pixelCount * 128) }
}
public struct RGB16Tile: Sendable {
    public let descriptor: TileDescriptor
    public let rgba: [UInt16]
    public init(descriptor: TileDescriptor, rgba: [UInt16]) throws {
        guard rgba.count == descriptor.pixelCount * 4 else { throw NativeError.invalid("RGBA16 tile size mismatch") }
        self.descriptor = descriptor; self.rgba = rgba
    }
}
public protocol TileProvider: Sendable {
    func read(_ descriptor: TileDescriptor) async throws -> RGB16Tile
}
public struct SyntheticTileProvider: TileProvider {
    public init() {}
    public func read(_ descriptor: TileDescriptor) async throws -> RGB16Tile { try Self.make(descriptor) }
    public static func make(_ d: TileDescriptor) throws -> RGB16Tile {
        var pixels = [UInt16](repeating: 65535, count: d.pixelCount * 4)
        for y in 0..<d.height { for x in 0..<d.width {
            let p = (y*d.width+x)*4, gx = x+d.x, gy = y+d.y
            pixels[p] = UInt16(truncatingIfNeeded: gx*7919 + gy*1049 + 1)
            pixels[p+1] = UInt16(truncatingIfNeeded: gx*17 + gy*3253 + 257)
            pixels[p+2] = UInt16(truncatingIfNeeded: gx*4093 + gy*37 + 65534)
        }}
        return try RGB16Tile(descriptor: d, rgba: pixels)
    }
}
