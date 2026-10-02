import Foundation
import FusionCore
import Darwin

public struct AuditRecord:Codable,Sendable {
    public var sequence:Int,date:Date,operation:ProcessingOperation,previousHash:String?,payload:JSONValue
}
public enum AuditTrail {
    public static func append(url:URL,operation:ProcessingOperation,payload:JSONValue,date:Date=Date())throws->String {
        let fd=open(url.path,O_RDWR|O_CREAT|O_NOFOLLOW,0o600);guard fd>=0 else{throw NativeError.resource("Cannot open audit")};defer{close(fd)}
        guard flock(fd,LOCK_EX)==0 else{throw NativeError.resource("Cannot lock audit")};defer{flock(fd,LOCK_UN)}
        let existing=try verify(url:url)
        let record=AuditRecord(sequence:existing.count,date:date,operation:operation,previousHash:existing.head,payload:payload)
        let data=try CanonicalJSON.data(record);guard data.count<=1048576 else{throw NativeError.resource("Audit event too large")}
        let file=FileHandle(fileDescriptor:fd,closeOnDealloc:false);try file.seekToEnd();try file.write(contentsOf:data+Data([10]));try file.synchronize()
        return TechnicalHash.data(data)
    }
    public static func verify(url:URL)throws->(count:Int,head:String?) {
        guard FileManager.default.fileExists(atPath:url.path)else{return(0,nil)}
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max;guard size<=32*1048576 else{throw NativeError.resource("Audit exceeds bounded history budget")}
        let data=try Data(contentsOf:url);guard data.isEmpty||data.last==10 else{throw NativeError.invalid("Truncated audit record")}
        var head:String?,count=0
        for line in data.split(separator:10){let record=try CanonicalJSON.decoder().decode(AuditRecord.self,from:Data(line));guard record.sequence==count,record.previousHash==head else{throw NativeError.invalid("Audit chain mismatch")};head=TechnicalHash.data(Data(line));count+=1}
        return(count,head)
    }
}
