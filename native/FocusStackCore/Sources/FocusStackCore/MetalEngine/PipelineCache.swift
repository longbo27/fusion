import Metal
import Foundation

public final class LibraryMarker: NSObject {}
public final class PipelineCache {
    public let copy: any MTLComputePipelineState
    public let luminance: any MTLComputePipelineState
    public let focus: any MTLComputePipelineState
    public init(device: any MTLDevice) throws {
        let bundle = Bundle.module
        let sources = try ["Passthrough", "Luminance", "FocusPrototype"].map { name in
            guard let url = bundle.url(forResource: name, withExtension: "metal", subdirectory: "Kernels") else {
                throw NativeError.resource("Missing shared shader resource \(name)")
            }
            return try String(contentsOf: url,encoding: .utf8)
        }.joined(separator: "\n")
        let options = MTLCompileOptions(); if #available(macOS 15.0, iOS 18.0, *) { options.mathMode = .safe }
        else { options.fastMathEnabled = false }
        let library = try device.makeLibrary(source: sources,options: options)
        func make(_ name: String) throws -> any MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw NativeError.resource("Missing kernel \(name)") }
            return try device.makeComputePipelineState(function: function)
        }
        copy = try make("copy16"); luminance = try make("luminance16"); focus = try make("sobelFocus")
    }
}
