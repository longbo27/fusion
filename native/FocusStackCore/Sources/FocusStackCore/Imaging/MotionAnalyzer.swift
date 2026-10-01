import Foundation
import Vision
import CoreVideo
import CoreGraphics
import QuartzCore

public struct MotionReport: Codable, Sendable {
    public let runtimeMS: Double, width: Int, height: Int
    public let pixelFormat: UInt32, outputBytes: Int
    public let memoryBefore: MemorySnapshot, memoryAfter: MemorySnapshot
}
public struct MotionAnalyzer {
    public init() {}
    // Experimental feature input only; never makes focus ownership decisions.
    public static func analyze(first: CGImage, second: CGImage) throws -> MotionReport {
        guard #available(macOS 11.0, iOS 14.0, *) else { throw NativeError.unavailable("Vision optical flow requires macOS 11") }
        guard first.width <= 2048, first.height <= 2048, first.width == second.width, first.height == second.height else {
            throw NativeError.invalid("Optical flow requires equal bounded tiles")
        }
        let before = MemoryMonitor.snapshot(), start = CACurrentMediaTime()
        let request = VNGenerateOpticalFlowRequest(targetedCGImage: second, options: [:])
        request.computationAccuracy = .low
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
        try VNImageRequestHandler(cgImage: first, options: [:]).perform([request])
        guard let output = request.results?.first?.pixelBuffer else { throw NativeError.unavailable("Vision produced no optical flow") }
        return MotionReport(runtimeMS: (CACurrentMediaTime()-start)*1000,
            width: CVPixelBufferGetWidth(output), height: CVPixelBufferGetHeight(output),
            pixelFormat: CVPixelBufferGetPixelFormatType(output),outputBytes: CVPixelBufferGetDataSize(output),
            memoryBefore: before,memoryAfter: MemoryMonitor.snapshot())
    }
    public static func fixture(shift: Int = 0, size: Int = 128) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: size*size*4)
        for y in 0..<size { for x in 0..<size {
            let v = UInt8(truncatingIfNeeded: ((x+shift)*31) ^ (y*47) ^ ((x+shift)*y))
            for c in 0..<3 { bytes[(y*size+x)*4+c] = v }
        }}
        // Separate 8-bit Vision-only test fixture, never enters the RGB16 photo path.
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        guard let image = CGImage(width: size,height: size,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: size*4,
            space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent) else { throw NativeError.invalid("Vision fixture failed") }
        return image
    }
}
