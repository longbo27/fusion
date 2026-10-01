import Foundation

public struct ImageMetadata: Sendable {
    public let width: Int, height: Int, bitsPerSample: Int, channels: Int, orientation: Int
    public let dpiX: Double?, dpiY: Double?
    public let compression: Int?
    public let color: ImageColorMetadata
    public let estimatedDecodedBytes: UInt64
    public var summary: String {
        "\(width) × \(height), \(bitsPerSample)-bit, \(channels) channels, orientation \(orientation), compression \(compression.map(String.init) ?? "unknown")\nICC: \(color.embeddedProfileEvidence)\nColor: \(color.spaceDescription)\nResolution: \(dpiX.map { String($0) } ?? "unknown") × \(dpiY.map { String($0) } ?? "unknown") dpi"
    }
}
