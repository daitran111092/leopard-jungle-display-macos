import Foundation

/// Process CPU (% of one core since the previous call) and memory.
public struct ProcMeter {
    private var lastCPU = ProcMeter.cpuSeconds()
    private var lastWall = ProcessInfo.processInfo.systemUptime

    public init() {}

    public static func cpuSeconds() -> Double {
        var ru = rusage()
        getrusage(RUSAGE_SELF, &ru)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(ru.ru_utime) + s(ru.ru_stime)
    }

    public static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.resident_size : 0
    }

    /// Physical footprint (private dirty + compressed; what Activity Monitor's Memory column shows).
    /// RSS also counts resident pages of the shared dyld cache (SwiftUI, AppKit…), ~100+ MB here.
    public static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    public mutating func cpuPercent() -> Double {
        let c = Self.cpuSeconds(), w = ProcessInfo.processInfo.systemUptime
        defer { lastCPU = c; lastWall = w }
        return w > lastWall ? (c - lastCPU) / (w - lastWall) * 100 : 0
    }
}
