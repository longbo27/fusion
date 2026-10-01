import Foundation
import Darwin
import CTIFFBridge

public enum TIFFCompression: UInt16, Sendable { case none = 1, lzw = 5, deflate = 8 }
public enum TIFFWriteLayout: Sendable { case strips(rows: Int), tiles(edge: Int) }
public struct TIFFWriteReport: Codable, Sendable {
    public let compressionWorkers:Int
    public let encodeSeconds: Double, validationSeconds: Double, rawScratchBytes: UInt64, outputBytes: UInt64
}
// Owned by one stack actor. Staging is disk-backed RGB16, never a resident frame.
public final class TIFFOutputWriter {
    private let output: URL, raw: URL, temporary: URL
    private let file: FileHandle
    private let width: Int, height: Int, blockEdge: Int
    private let metadata: TIFFBackendMetadata?
    private let layout: TIFFWriteLayout, compression: TIFFCompression, forceBig: Bool
    private let requestedWorkers:Int
    private var nextX = 0, nextY = 0, finished = false
    public init(output: URL,width: Int,height: Int,blockEdge: Int,metadata: TIFFBackendMetadata? = nil,
                layout: TIFFWriteLayout = .strips(rows: 32),compression: TIFFCompression = .deflate,forceBigTIFF: Bool = false,compressionWorkers:Int = 0) throws {
        guard (0...2).contains(compressionWorkers),width > 0,height > 0,width <= Int(UInt32.max),height <= Int(UInt32.max),blockEdge >= 1,blockEdge <= 2048,
              !FileManager.default.fileExists(atPath: output.path) else { throw NativeError.invalid("Invalid output extent or destination already exists") }
        switch layout {
        case .strips(let rows): guard rows > 0,rows <= 2048 else { throw NativeError.invalid("Invalid output strip height") }
        case .tiles(let edge): guard edge > 0,edge <= 2048,edge%16 == 0 else { throw NativeError.invalid("TIFF tile edge must be a multiple of 16") }
        }
        self.requestedWorkers=compressionWorkers;self.output=output;self.width=width;self.height=height;self.blockEdge=blockEdge;self.metadata=metadata
        self.layout=layout;self.compression=compression;self.forceBig=forceBigTIFF
        raw=output.deletingLastPathComponent().appendingPathComponent(".focusstack-\(UUID().uuidString).raw")
        temporary=output.deletingLastPathComponent().appendingPathComponent(".focusstack-\(UUID().uuidString).tiff.partial")
        let descriptor = open(raw.path,O_CREAT|O_EXCL|O_RDWR,0o600)
        guard descriptor >= 0 else { throw NativeError.resource("Cannot create exclusive sibling staging") }
        file=FileHandle(fileDescriptor: descriptor,closeOnDealloc: true)
        let size=UInt64(width).multipliedReportingOverflow(by: UInt64(height)*6)
        guard !size.overflow,size.partialValue <= UInt64(Int64.max),ftruncate(descriptor,off_t(size.partialValue)) == 0 else {
            try? file.close();try? FileManager.default.removeItem(at: raw);throw NativeError.resource("Cannot reserve RGB16 staging")
        }
    }
    deinit { try? file.close();try? FileManager.default.removeItem(at: raw);if !finished { try? FileManager.default.removeItem(at: temporary) } }
    public func write(_ tile: RGB16Tile) throws {
        let d=tile.descriptor
        guard !finished,d.x==nextX,d.y==nextY,d.width==min(blockEdge,width-nextX),d.height==min(blockEdge,height-nextY) else {
            throw NativeError.invalid("Output tiles must cover the image exactly once in row-major core-grid order")
        }
        var row=[UInt16](repeating: 0,count: d.width*3)
        for y in 0..<d.height {
            for x in 0..<d.width { for c in 0..<3 { row[x*3+c]=tile.rgba[(y*d.width+x)*4+c] } }
            try file.seek(toOffset: UInt64((d.y+y)*width+d.x)*6)
            try row.withUnsafeBytes { try file.write(contentsOf: $0) }
        }
        nextX += d.width;if nextX==width { nextX=0;nextY+=d.height }
    }
    public func finish() throws -> TIFFWriteReport {
        guard !finished,nextX==0,nextY==height else { throw NativeError.invalid("Incomplete output coverage") }
        try file.synchronize()
        let budget=MemoryMonitor.budget(recommended: ProcessInfo.processInfo.physicalMemory)
        var error=[CChar](repeating: 0,count: 1024)
        let icc=metadata?.icc ?? Data(), start=Date.timeIntervalSinceReferenceDate
        let rows: UInt32,edge: UInt32
        switch layout { case .strips(let n): rows=UInt32(n);edge=0;case .tiles(let n): rows=0;edge=UInt32(n) }
        let canParallel=edge==0 && compression == .deflate
        let segmentBytes=UInt64(width)*UInt64(rows)*6
        let automatic=ApplePlatformMemoryClass.current == .desktop && UInt64(width)*UInt64(height)>=16_000_000 ? 2:1
        let workers=canParallel && segmentBytes*24+4*1048576<budget ? (requestedWorkers==0 ? automatic:requestedWorkers):1
        let code=icc.withUnsafeBytes {
            fs_write_tiff_from_raw(raw.path,temporary.path,UInt32(width),UInt32(height),compression.rawValue,edge,rows,forceBig ? 1 : 0,
                $0.baseAddress,UInt32(icc.count),metadata?.dpiX ?? 0,metadata?.dpiY ?? 0,UInt16(metadata?.resolutionUnit ?? 2),
                metadata?.artist ?? "",metadata?.copyright ?? "",metadata?.description ?? "",UInt32(workers),budget,&error,error.count)
        }
        guard code != 0 else { throw NativeError.invalid(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
        let encoded=Date.timeIntervalSinceReferenceDate, validation=icc.withUnsafeBytes {
            fs_validate_tiff_against_raw(raw.path,temporary.path,UInt32(width),UInt32(height),$0.baseAddress,UInt32(icc.count),budget,&error,error.count)
        }
        guard validation != 0 else { throw NativeError.invalid(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }) }
        let validated=Date.timeIntervalSinceReferenceDate
        let handle=try FileHandle(forWritingTo: temporary);try handle.synchronize();try handle.close()
        let bytes=(try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.uint64Value ?? 0
        // Atomic, exclusive publication: an existing output is never replaced.
        guard renamex_np(temporary.path,output.path,UInt32(RENAME_EXCL)) == 0 else { throw NativeError.resource("Atomic TIFF publication failed; destination preserved") }
        let directory=open(output.deletingLastPathComponent().path,O_RDONLY)
        if directory >= 0 { _=fsync(directory);close(directory) } // APFS directory fsync may return EINVAL.
        finished=true;try? file.close();try FileManager.default.removeItem(at: raw)
        return TIFFWriteReport(compressionWorkers:workers,encodeSeconds: encoded-start,validationSeconds: validated-encoded,rawScratchBytes: UInt64(width)*UInt64(height)*6,outputBytes: bytes)
    }
}
