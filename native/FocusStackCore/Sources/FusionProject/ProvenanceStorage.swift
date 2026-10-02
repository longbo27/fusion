import Foundation
import Compression
import FusionCore

public struct ProvenanceBlock:Codable,Sendable {
    public var id:String,path:String,sha256:String,x:Int,y:Int,width:Int,height:Int,compressedBytes:Int,rawBytes:Int
    public var summary:SourceFaithfulReport,coverage:CoverageSummary
}
public enum ProvenanceStorage {
    public static func write(_ tile:ProductEvidenceTile,to directory:URL)throws->ProvenanceBlock {
        let d=tile.descriptor,raw=tile.words.withUnsafeBytes{Data($0)},id="\(d.x)-\(d.y)",path="\(id)-\(UUID().uuidString).fsp"
        var destination=Data(count:raw.count+65536)
        let count=destination.withUnsafeMutableBytes{dst in raw.withUnsafeBytes{src in compression_encode_buffer(dst.bindMemory(to:UInt8.self).baseAddress!,dst.count,src.bindMemory(to:UInt8.self).baseAddress!,src.count,nil,COMPRESSION_LZFSE)}}
        let compressed=count>0 && count<raw.count;let body=compressed ? destination.prefix(count):raw[...]
        var header=Data("FSP3".utf8)
        for v in [UInt32(1),UInt32(d.width),UInt32(d.height),UInt32(raw.count),compressed ? UInt32(1):0]{var le=v.littleEndian;withUnsafeBytes(of:&le){header.append(contentsOf:$0)}}
        header.append(body);try header.write(to:directory.appendingPathComponent(path),options:.atomic)
        var summary=SourceFaithfulReport(),coverage=CoverageSummary()
        for word in tile.words{summary.add(word);coverage.evaluatedPixels+=1;if word.z>>24>=128{coverage.adequateEvidencePixels+=1};if word.z>>24<51{coverage.lowEvidencePixels+=1}}
        return ProvenanceBlock(id:id,path:path,sha256:TechnicalHash.data(header),x:d.x,y:d.y,width:d.width,height:d.height,compressedBytes:header.count,rawBytes:raw.count,summary:summary,coverage:coverage)
    }
    public static func read(_ block:ProvenanceBlock,from directory:URL)throws->ProductEvidenceTile {
        guard !block.path.contains("/"),block.path.hasSuffix(".fsp"),block.x>=0,block.y>=0,block.width>0,block.width<=1024,block.height>0,block.height<=1024,block.rawBytes==block.width*block.height*16,block.compressedBytes<=block.rawBytes+24 else{throw NativeError.invalid("Invalid provenance block index")}
        let url=directory.appendingPathComponent(block.path)
        let attributes=try url.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey])
        guard attributes.isSymbolicLink==false,attributes.fileSize==block.compressedBytes else{throw NativeError.invalid("Symlink provenance payload")}
        let bytes=try Data(contentsOf:url);guard bytes.count==block.compressedBytes,bytes.count>=24,TechnicalHash.data(bytes)==block.sha256,String(decoding:bytes.prefix(4),as:UTF8.self)=="FSP3"else{throw NativeError.invalid("Provenance integrity mismatch")}
        func value(_ offset:Int)->UInt32{bytes.withUnsafeBytes{UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:offset,as:UInt32.self))}}
        guard value(4)==1,value(8)==block.width,value(12)==block.height,value(16)==block.rawBytes,value(20)<=1 else{throw NativeError.invalid("Unsupported provenance schema")}
        let body=bytes.dropFirst(24);var raw=Data(count:block.rawBytes)
        if value(20)==0{guard body.count==raw.count else{throw NativeError.invalid("Raw provenance extent")};raw=Data(body)}else{
            let count=raw.withUnsafeMutableBytes{dst in body.withUnsafeBytes{src in compression_decode_buffer(dst.bindMemory(to:UInt8.self).baseAddress!,dst.count,src.bindMemory(to:UInt8.self).baseAddress!,src.count,nil,COMPRESSION_LZFSE)}}
            guard count==raw.count else{throw NativeError.invalid("Provenance decode extent")}
        }
        var words=[SIMD4<UInt32>](repeating:.zero,count:block.width*block.height)
        _=words.withUnsafeMutableBytes{dst in raw.copyBytes(to:dst)}
        return try ProductEvidenceTile(descriptor:TileDescriptor(x:block.x,y:block.y,width:block.width,height:block.height),words:words)
    }
}
