import Foundation
import ImageIO
import CoreGraphics

public struct TIFFInspector {
    public init() {}
    public static func source(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetCount(source) > 0,
            CGImageSourceGetType(source) as String? == "public.tiff" else {
            throw NativeError.invalid("Not a readable TIFF source")
        }
        return source
    }
    public static func inspect(_ url: URL) throws -> ImageMetadata {
        let source = try source(url)
        guard let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (p[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
              let height = (p[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= Int(UInt32.max), height <= Int(UInt32.max) else {
            throw NativeError.invalid("TIFF dimensions unavailable")
        }
        // Lazy image descriptor; no CGContext draw or pixel data request here.
        let image = CGImageSourceCreateImageAtIndex(source, 0,
            [kCGImageSourceShouldCache: false, kCGImageSourceShouldAllowFloat: false] as CFDictionary)
        let tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let bits = (p[kCGImagePropertyDepth as String] as? NSNumber)?.intValue ?? image?.bitsPerComponent ?? 0
        let model = p[kCGImagePropertyColorModel as String] as? String ?? "unknown"
        let name = p[kCGImagePropertyProfileName as String] as? String
        let sourceICC = try TIFFProfileReader.readICC(url)
        let profile = ColorProfile(space: image?.colorSpace, name: name, exactSourceICC: sourceICC)
        let channels = (image?.colorSpace?.numberOfComponents ?? (model == "RGB" ? 3 : 0)) + ((p[kCGImagePropertyHasAlpha as String] as? Bool == true) ? 1 : 0)
        let decodedEstimate = UInt64(width).multipliedReportingOverflow(by: UInt64(height))
        let byteEstimate = decodedEstimate.partialValue.multipliedReportingOverflow(by: UInt64(max(channels, 4)) * UInt64(max(bits, 8)/8))
        guard !decodedEstimate.overflow, !byteEstimate.overflow else { throw NativeError.invalid("TIFF decoded-size overflow") }
        let color = ImageColorMetadata(model: model,
            spaceDescription: image?.colorSpace?.name as String? ?? profile.colorSyncDescription ?? model,
            profile: profile,
            embeddedProfileEvidence: sourceICC.map { "present, \($0.count) original tag bytes preserved" } ?? "absent (ImageIO space is inferred; no transfer curve is assumed)")
        return ImageMetadata(width: width, height: height, bitsPerSample: bits, channels: channels,
            orientation: (p[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1,
            dpiX: (p[kCGImagePropertyDPIWidth as String] as? NSNumber)?.doubleValue,
            dpiY: (p[kCGImagePropertyDPIHeight as String] as? NSNumber)?.doubleValue,
            compression: (tiff[kCGImagePropertyTIFFCompression as String] as? NSNumber)?.intValue,
            color: color, estimatedDecodedBytes: byteEstimate.partialValue)
    }
}
