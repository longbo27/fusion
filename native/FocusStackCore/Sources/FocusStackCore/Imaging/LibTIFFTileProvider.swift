import Foundation
import CTIFFBridge

public struct TIFFBackendMetadata: Sendable {
    public let width: Int, height: Int, rawWidth: Int, rawHeight: Int, bits: Int, orientation: Int
    public let compression: Int, segmentCount: UInt64, rowsPerStrip: Int, tileWidth: Int, tileHeight: Int
    public let tiled: Bool, bigTIFF: Bool
    public let icc: Data?
    public let dpiX: Double, dpiY: Double, resolutionUnit: Int
    public let artist: String?, copyright: String?, description: String?
    public var summary: String { "\(width)×\(height) RGB\(bits), orientation \(orientation), \(bigTIFF ? "BigTIFF" : "classic TIFF"), codec \(compression), \(segmentCount) \(tiled ? "tiles" : "strips"), rows/strip \(rowsPerStrip), tile \(tileWidth)×\(tileHeight), ICC \(icc?.count ?? 0) bytes" }
}
public struct TIFFDecodePlan: Codable, Sendable {
    public let decodedSegmentBytes: UInt64, encodedSegmentBytes: UInt64, requiredSegments: UInt64, plannedBytes: UInt64
    public let directUncompressedRows: Bool
}
public struct LibTIFFTileProvider: TileProvider {
    public let url: URL
    public init(url: URL) { self.url = url }
    private func withFile<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var error = [CChar](repeating: 0,count: 1024)
        let budget = MemoryMonitor.budget(recommended: ProcessInfo.processInfo.physicalMemory)
        guard budget > 64*1048576, let file = fs_tiff_open(url.path,budget,&error,error.count) else {
            throw NativeError.invalid(error.withUnsafeBufferPointer { String(cString: $0.baseAddress!) })
        }
        defer { fs_tiff_close(file) }
        return try body(file)
    }
    public func metadata() throws -> TIFFBackendMetadata {
        try withFile { file in
            var i = FSTiffInfo(); guard fs_tiff_info(file,&i) != 0 else { throw NativeError.invalid("No TIFF metadata") }
            var length: UInt32 = 0
            let bytes = fs_tiff_icc(file,&length)
            let icc = bytes.map { Data(bytes: $0,count: Int(length)) }
            func text(_ tag: UInt32) -> String? { fs_tiff_text(file,tag).map { String(cString: $0) } }
            let description = text(270)
            return TIFFBackendMetadata(width: Int(i.width),height: Int(i.height),rawWidth: Int(i.raw_width),rawHeight: Int(i.raw_height),
                bits: Int(i.bits),orientation: Int(i.orientation),compression: Int(i.compression),segmentCount: i.segments,
                rowsPerStrip: Int(i.rows_per_strip),tileWidth: Int(i.tile_width),tileHeight: Int(i.tile_height),tiled: i.tiled != 0,bigTIFF: i.big != 0,
                icc: icc,dpiX: i.orientation >= 5 ? i.dpi_y : i.dpi_x,dpiY: i.orientation >= 5 ? i.dpi_x : i.dpi_y,resolutionUnit: Int(i.resolution_unit),
                artist: text(315),copyright: text(33432),description: description.flatMap { $0.hasPrefix("{") || $0.hasPrefix("<") ? nil : $0 })
        }
    }
    public func plan(_ d: TileDescriptor) throws -> TIFFDecodePlan {
        try withFile { file in
            var p = FSDecodePlan()
            guard fs_tiff_plan(file,UInt32(d.x),UInt32(d.y),UInt32(d.width),UInt32(d.height),&p) != 0 else { throw NativeError.invalid(String(cString: fs_tiff_error(file))) }
            return TIFFDecodePlan(decodedSegmentBytes: p.decoded_bytes,encodedSegmentBytes: p.encoded_bytes,requiredSegments: p.segments,
                plannedBytes: p.planned_bytes,directUncompressedRows: p.direct_rows != 0)
        }
    }
    public func read(_ descriptor: TileDescriptor) async throws -> RGB16Tile { try readSync(descriptor) }
    public func readSync(_ d: TileDescriptor) throws -> RGB16Tile {
        try withFile { file in
            var p = FSDecodePlan()
            guard fs_tiff_plan(file,UInt32(d.x),UInt32(d.y),UInt32(d.width),UInt32(d.height),&p) != 0 else { throw NativeError.invalid(String(cString: fs_tiff_error(file))) }
            let budget = MemoryMonitor.budget(recommended: ProcessInfo.processInfo.physicalMemory)
            guard p.planned_bytes <= budget else { throw NativeError.resource("TIFF codec decode admission exceeds current memory budget") }
            var pixels = [UInt16](repeating: 0,count: d.pixelCount*4)
            let result = pixels.withUnsafeMutableBufferPointer { fs_tiff_read(file,UInt32(d.x),UInt32(d.y),UInt32(d.width),UInt32(d.height),$0.baseAddress,budget) }
            guard result != 0 else { throw NativeError.invalid(String(cString: fs_tiff_error(file))) }
            return try RGB16Tile(descriptor: d,rgba: pixels)
        }
    }
}
