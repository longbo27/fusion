import Foundation
import ImageIO
import CoreGraphics

public struct ImageIOTileProvider: TileProvider {
    public let url: URL
    // ImageIO offers an image-at-index decoder, not a public guaranteed TIFF ROI decoder.
    // Production reads reject full images over this conservative bound BEFORE decoding.
    public let maximumDecodedBytes: UInt64
    public init(url: URL, maximumDecodedBytes: UInt64 = 64 * 1024 * 1024) {
        self.url = url; self.maximumDecodedBytes = maximumDecodedBytes
    }
    public func read(_ descriptor: TileDescriptor) async throws -> RGB16Tile { try readSync(descriptor) }
    public func readSync(_ d: TileDescriptor) throws -> RGB16Tile {
        let metadata = try TIFFInspector.inspect(url)
        guard metadata.estimatedDecodedBytes <= maximumDecodedBytes else {
            throw NativeError.unavailable("ImageIO full decode exceeds safe bound; production TIFF ROI backend pending")
        }
        let diskBytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        let codecBytes = metadata.estimatedDecodedBytes.multipliedReportingOverflow(by: 3)
        let withEncoded = codecBytes.partialValue.addingReportingOverflow(diskBytes)
        let planned = withEncoded.partialValue.addingReportingOverflow(d.estimatedWorkingBytes)
        guard !codecBytes.overflow, !withEncoded.overflow, !planned.overflow,
              planned.partialValue < MemoryMonitor.budget(recommended: ProcessInfo.processInfo.physicalMemory) else {
            throw NativeError.resource("ImageIO codec buffers/encoded input/tile exceed available memory after OS reserve and current RSS")
        }
        guard metadata.bitsPerSample == 16, metadata.channels == 3, metadata.orientation == 1,
              d.x <= metadata.width-d.width, d.y <= metadata.height-d.height else {
            throw NativeError.invalid("Foundation tile reader requires orientation-1 RGB16 and an in-bounds tile")
        }
        let source = try TIFFInspector.source(url)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let crop = image.cropping(to: CGRect(x: d.x, y: d.y, width: d.width, height: d.height)),
              crop.bitsPerComponent == 16, crop.bitsPerPixel == 48 || crop.bitsPerPixel == 64,
              crop.colorSpace?.model == .rgb,
              crop.alphaInfo == .none || crop.alphaInfo == .noneSkipLast,
              let data = crop.dataProvider?.data else {
            throw NativeError.unavailable("ImageIO returned an unsupported representation; no automatic conversion")
        }
        guard let bytes = CFDataGetBytePtr(data) else { throw NativeError.invalid("No decoded pixels") }
        let stride = crop.bitsPerPixel/8
        guard CFDataGetLength(data) >= crop.bytesPerRow*d.height else { throw NativeError.invalid("Short decoded buffer") }
        let little = crop.bitmapInfo.intersection(.byteOrderMask) == .byteOrder16Little
        var rgba = [UInt16](repeating: 65535, count: d.pixelCount*4)
        for y in 0..<d.height { for x in 0..<d.width { for c in 0..<3 {
            let p = y*crop.bytesPerRow+x*stride+c*2
            rgba[(y*d.width+x)*4+c] = little ? UInt16(bytes[p]) | UInt16(bytes[p+1])<<8 : UInt16(bytes[p])<<8 | UInt16(bytes[p+1])
        }}}
        return try RGB16Tile(descriptor: d, rgba: rgba)
    }
}
