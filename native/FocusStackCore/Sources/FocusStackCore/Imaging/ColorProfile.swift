import Foundation
import CoreGraphics
import ColorSync

public struct ColorProfile: Sendable {
    public let name: String?
    public let exactSourceICC: Data?
    // This is ColorSync's representation of the ImageIO color space. It is NOT
    // guaranteed to be the original TIFF ICC tag's exact bytes.
    public let imageIOICCRepresentation: Data?
    public let colorSyncDescription: String?
    public init(space: CGColorSpace?, name: String?, exactSourceICC: Data?) {
        self.exactSourceICC = exactSourceICC
        self.name = name
        imageIOICCRepresentation = space.flatMap { $0.copyICCData() as Data? }
        if let data = imageIOICCRepresentation,
           let profile = ColorSyncProfileCreate(data as CFData, nil)?.takeRetainedValue() {
            colorSyncDescription = ColorSyncProfileCopyDescriptionString(profile)?.takeRetainedValue() as String?
        } else { colorSyncDescription = nil }
    }
}
public struct ImageColorMetadata: Sendable {
    public let model: String
    public let spaceDescription: String
    public let profile: ColorProfile
    public let embeddedProfileEvidence: String
    public let transferPolicy = "Encoded source RGB; no transfer curve assumed. No color conversion in Metal."
}
