import Metal
import Foundation

public enum NativeError: Error, LocalizedError, Sendable {
    case invalid(String), unavailable(String), resource(String)
    public var errorDescription: String? {
        switch self { case .invalid(let s), .unavailable(let s), .resource(let s): return s }
    }
}
public enum PixelFormat: String, Sendable {
    // Integer texture reads preserve each uint16 exactly; normalization is explicit Float32.
    case rgba16Uint
    public var metal: MTLPixelFormat { .rgba16Uint }
    public var bytesPerPixel: Int { 8 }
    public var bitsPerChannel: Int { 16 }
}
