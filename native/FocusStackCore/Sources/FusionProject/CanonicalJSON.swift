import Foundation
import FusionCore

public enum JSONValue:Codable,Sendable,Equatable {
    case object([String:Self]),array([Self]),string(String),integer(Int64),number(Double),bool(Bool),null
    public init(from decoder:Decoder)throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil(){self = .null}else if let v=try? c.decode(Bool.self){self = .bool(v)}else if let v=try? c.decode(Int64.self){self = .integer(v)}else if let v=try? c.decode(Double.self){self = .number(v)}else if let v=try? c.decode(String.self){self = .string(v)}else if let v=try? c.decode([Self].self){self = .array(v)}else{self = .object(try c.decode([String:Self].self))}
    }
    public func encode(to encoder:Encoder)throws {
        var c=encoder.singleValueContainer();switch self{case .object(let v):try c.encode(v);case .array(let v):try c.encode(v);case .string(let v):try c.encode(v);case .integer(let v):try c.encode(v);case .number(let v):try c.encode(v);case .bool(let v):try c.encode(v);case .null:try c.encodeNil()}
    }
    /// Recursive merge preserves unknown fields, including ID-keyed records.
    public func updating(with known:Self)->Self {
        switch(self,known){
        case(.object(var a),.object(let b)):for(k,v)in b{a[k]=a[k]?.updating(with:v) ?? v};return .object(a)
        case(.array(let a),.array(let b)):return .array(b.map{value in
            if case .object(let fields)=value,let id=fields["id"],let old=a.first(where:{if case .object(let f)=$0{return f["id"]==id};return false}){return old.updating(with:value)};return value
        })
        default:return known}
    }
}
public enum CanonicalJSON {
    public static func encoder()->JSONEncoder{let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];e.dateEncodingStrategy = .iso8601;return e}
    public static func decoder()->JSONDecoder{let d=JSONDecoder();d.dateDecodingStrategy = .iso8601;return d}
    public static func data<T:Encodable>(_ v:T)throws->Data{try encoder().encode(v)}
    public static func read<T:Decodable>(_ type:T.Type,url:URL,limit:Int=8*1048576)throws->T {
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max
        guard size<=limit else{throw NativeError.resource("Project metadata exceeds bounded limit")}
        return try decoder().decode(type,from:Data(contentsOf:url))
    }
}
