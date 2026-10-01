import Foundation

// Bounded metadata-only reader for the original ICC tag. ImageIO/ColorSync may
// describe an inferred space; only TIFF tag 34675 is evidence of an embedded ICC.
// No pixel/strip/tile codec is implemented here. First IFD only, classic + BigTIFF.
public struct TIFFProfileReader {
    public static func readICC(_ url: URL) throws -> Data? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard count >= 0, offset <= size, UInt64(count) <= size-offset else {
                throw NativeError.invalid("TIFF metadata offset exceeds file")
            }
            try file.seek(toOffset: offset)
            guard let data = try file.read(upToCount: count), data.count == count else {
                throw NativeError.invalid("Truncated TIFF metadata")
            }
            return data
        }
        let header = try read(0,8)
        let little: Bool
        if header[0] == 73 && header[1] == 73 { little = true }
        else if header[0] == 77 && header[1] == 77 { little = false }
        else { throw NativeError.invalid("Invalid TIFF byte order") }
        func number(_ data: Data, _ start: Int, _ count: Int) -> UInt64 {
            var value: UInt64 = 0
            for i in 0..<count {
                let j = little ? count-i-1 : i
                value = (value << 8) | UInt64(data[start+j])
            }
            return value
        }
        let magic = number(header,2,2)
        let big: Bool, first: UInt64
        if magic == 42 { big = false; first = number(header,4,4) }
        else if magic == 43 {
            guard number(header,4,2) == 8, number(header,6,2) == 0 else { throw NativeError.invalid("Unsupported BigTIFF header") }
            big = true; first = number(try read(8,8),0,8)
        } else { throw NativeError.invalid("Invalid TIFF magic") }
        let countBytes = big ? 8 : 2, entryBytes = big ? 20 : 12, inlineBytes = big ? 8 : 4
        let count = number(try read(first,countBytes),0,countBytes)
        guard count <= 16384 else { throw NativeError.invalid("TIFF IFD metadata count exceeds safe inspection bound") }
        let tableBytes = Int(count)*entryBytes
        // The complete metadata table is <=320 KiB; never proportional to image pixels.
        guard first <= size-UInt64(countBytes) else { throw NativeError.invalid("Truncated TIFF IFD") }
        let table = try read(first+UInt64(countBytes),tableBytes)
        for i in 0..<Int(count) {
            let p = i*entryBytes
            if number(table,p,2) != 34675 { continue }
            let type = number(table,p+2,2), length = number(table,p+4,big ? 8 : 4)
            guard type == 7 || type == 1, length > 0, length <= 16*1024*1024 else {
                throw NativeError.invalid("Unsupported/oversized TIFF ICC metadata; no silent profile loss")
            }
            let valueIndex = p+(big ? 12 : 8)
            if length <= UInt64(inlineBytes) { return Data(table[valueIndex..<valueIndex+Int(length)]) }
            return try read(number(table,valueIndex,inlineBytes),Int(length))
        }
        return nil
    }
}
