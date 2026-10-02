import Foundation
import FusionCore
import Darwin

enum ProjectWriteLock {
    static func perform<T>(directory:URL,_ body:()throws->T)throws->T {
        let fd=open(directory.appendingPathComponent("processing/write.lock").path,O_RDWR|O_CREAT|O_NOFOLLOW,0o600)
        guard fd>=0 else{throw NativeError.resource("Cannot open project lock")};defer{close(fd)}
        guard flock(fd,LOCK_EX)==0 else{throw NativeError.resource("Cannot lock project")};defer{flock(fd,LOCK_UN)}
        return try body()
    }
}
