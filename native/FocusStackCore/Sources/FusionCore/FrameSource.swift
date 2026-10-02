import Foundation
import CryptoKit

public enum FrameSourceKind:String,Codable,Sendable { case stillImage,imageSequenceFrame,videoFrame }
public struct FrameSource:Codable,Sendable,Identifiable {
    public var id:UUID,kind:FrameSourceKind,url:URL,frameID:String?,timestampSeconds:Double?
    public var modificationDate:Date?
    public var modificationTime:Double?
    public var filename:String,size:UInt64,sha256:String,metadataFingerprint:String,colorProfileSHA256:String?
    public init(id:UUID=UUID(),kind:FrameSourceKind = .stillImage,url:URL,frameID:String?=nil,timestampSeconds:Double?=nil,size:UInt64,sha256:String,metadataFingerprint:String,colorProfileSHA256:String?=nil){modificationDate=try? url.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate;modificationTime=modificationDate?.timeIntervalSince1970;self.id=id;self.kind=kind;self.url=url.standardizedFileURL;self.frameID=frameID;self.timestampSeconds=timestampSeconds;filename=url.lastPathComponent;self.size=size;self.sha256=sha256;self.metadataFingerprint=metadataFingerprint;self.colorProfileSHA256=colorProfileSHA256}
}
public enum TechnicalHash {
    public static func data(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    /// One 1 MiB read at a time, independent of source size/count.
    public static func file(_ url:URL)throws->String {
        let f=try FileHandle(forReadingFrom:url);defer{try? f.close()};var hash=SHA256()
        // Foundation may autorelease read objects on Darwin. Drain each chunk,
        // including when called outside the engine's per-tile pool.
        while try autoreleasepool(invoking:{
            guard let d=try f.read(upToCount:1048576),!d.isEmpty else{return false}
            try Task.checkCancellation();hash.update(data:d);return true
        }){}
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    public static func source(_ url:URL)throws->FrameSource {
        let metadata=try LibTIFFTileProvider(url:url).metadata(),attributes=try FileManager.default.attributesOfItem(atPath:url.path)
        let size=(attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let fingerprint="\(metadata.width):\(metadata.height):\(metadata.bits):\(metadata.orientation):\(metadata.dpiX):\(metadata.dpiY):\(metadata.resolutionUnit):\(metadata.icc.map(data) ?? "unknown")"
        return FrameSource(url:url,size:size,sha256:try file(url),metadataFingerprint:data(Data(fingerprint.utf8)),colorProfileSHA256:metadata.icc.map(data))
    }
}
/// A future decoder factory resolves still/sequence/video sources to tile access.
/// V3 production decoding remains the validated RGB16 TIFF adapter.
public protocol FrameTileResolver:Sendable {func provider(for source:FrameSource)throws->any TileProvider}
public struct TIFFFrameResolver:FrameTileResolver {
    public init(){}
    public func provider(for source:FrameSource)throws->any TileProvider{
        guard source.kind != .videoFrame,["tif","tiff"].contains(source.url.pathExtension.lowercased()) else{throw NativeError.unavailable("Source kind/codec is an extension point, not an implemented decoder")}
        return LibTIFFTileProvider(url:source.url)
    }
}
public struct IncrementalPlan:Sendable {
    public let cores:[TileDescriptor],readHalo:Int
    public init(edit:PixelRegion,width:Int,height:Int,tileEdge:Int,quality:StackQuality)throws {
        guard edit.valid,width>0,height>0,tileEdge>0,tileEdge<=1024 else{throw NativeError.invalid("Incremental geometry")}
        readHalo=quality.halo+32
        // Exclusion changes focus/weights in the halo too. Recompute neighboring
        // cores whose dependency footprint intersects the edited constraint.
        let x0=max(0,edit.x-readHalo),y0=max(0,edit.y-readHalo),x1=min(width,edit.x+edit.width+readHalo),y1=min(height,edit.y+edit.height+readHalo)
        var result=[TileDescriptor]()
        if x1>x0 && y1>y0{for y in stride(from:y0/tileEdge*tileEdge,to:y1,by:tileEdge){for x in stride(from:x0/tileEdge*tileEdge,to:x1,by:tileEdge){result.append(try TileDescriptor(x:x,y:y,width:min(tileEdge,width-x),height:min(tileEdge,height-y)))}}}
        cores=result
    }
}
