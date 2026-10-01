import Foundation
import Darwin

public struct MemorySnapshot: Codable, Sendable {
    public let residentBytes: UInt64
    public let lifetimePeakBytes: UInt64
}
public enum MemoryMonitor {
    public static func snapshot() -> MemorySnapshot {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        // Darwin ru_maxrss is bytes, unlike Linux KiB.
        return MemorySnapshot(residentBytes: status == KERN_SUCCESS ? UInt64(info.resident_size) : 0,
            lifetimePeakBytes: UInt64(max(0, usage.ru_maxrss)))
    }
    public static func budget(recommended: UInt64) -> UInt64 {
        TileMemoryPolicy(physicalBytes: ProcessInfo.processInfo.physicalMemory,
            recommendedGPUBytes: recommended, residentBytes: snapshot().residentBytes).availableBudgetBytes
    }
}
