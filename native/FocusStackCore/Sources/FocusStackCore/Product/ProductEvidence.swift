import Foundation

public enum SourceFaithfulMode:String,Codable,Sendable {case capturedSourcesOnly}

/// Platform-neutral sparse rectangular ownership constraints. Hosts can rasterize
/// Pencil/brush strokes into bounded rectangles; no painted photographic RGB.
public enum OwnershipAction: Codable, Sendable, Equatable {
    case auto, bestFocus, reference, source(Int), exclude(Int), lock(Int)
    public var code: UInt32 { switch self { case .auto:0; case .bestFocus:1; case .reference:2; case .source:3; case .exclude:4; case .lock:5 } }
    public var sourceIndex: Int { switch self { case .source(let i),.exclude(let i),.lock(let i):i; default:0 } }
}
public struct PixelRegion: Codable, Hashable, Sendable {
    public var x:Int, y:Int, width:Int, height:Int
    public init(x:Int,y:Int,width:Int,height:Int) { self.x=x;self.y=y;self.width=width;self.height=height }
    public var valid:Bool { x>=0 && y>=0 && width>0 && height>0 && x<=Int.max-width && y<=Int.max-height }
    public func contains(x:Int,y:Int)->Bool { valid && x>=self.x && y>=self.y && x-self.x<width && y-self.y<height }
    public func intersects(_ other:Self)->Bool { valid && other.valid && x<other.x+other.width && other.x<x+width && y<other.y+other.height && other.y<y+height }
}
public struct OwnershipConstraint: Codable, Sendable, Equatable, Identifiable {
    public var id:UUID, region:PixelRegion, action:OwnershipAction
    public init(id:UUID=UUID(),region:PixelRegion,action:OwnershipAction){self.id=id;self.region=region;self.action=action}
}
/// Four little-endian uint32 words per pixel, only ONE bounded core tile resident.
/// x: primary/secondary-candidate UInt16; y: best candidate/mode/manual status;
/// z: focus/motion/registration/coverage UInt8; w: motion uncertainty / third candidate / QA.
/// Multiband candidates are NOT asserted to be exhaustive RGB contributors.
public struct ProductEvidenceTile: Sendable {
    public let descriptor:TileDescriptor
    public let words:[SIMD4<UInt32>]
    public init(descriptor:TileDescriptor,words:[SIMD4<UInt32>])throws {
        guard words.count==descriptor.pixelCount else{throw NativeError.invalid("Evidence extent mismatch")}
        self.descriptor=descriptor;self.words=words
    }
}
