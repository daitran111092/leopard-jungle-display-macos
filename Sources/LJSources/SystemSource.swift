import Foundation
import Darwin
import LJCore

/// Samples host CPU, memory and per-process usage every `interval` seconds and emits `aggregate(...)` (top 3 apps).
///
/// - Host CPU %: `host_processor_info` tick deltas over all cores, 0–100.
/// - Memory used: like Activity Monitor's "Memory Used" = app memory (internal − purgeable) + wired + compressed,
///   from `host_statistics64`; total = physical memory.
/// - Per process: `proc_pid_rusage` CPU-time deltas (100 % = one full core, as in Activity Monitor) and
///   `ri_phys_footprint` (Activity Monitor's "Memory" column) as `rssBytes`. Grouped by the outermost enclosing
///   `.app` of `proc_pidpath`. Processes we may not inspect (other users' / root) are skipped.
///
/// The first sample has no previous one, so host and per-process CPU read 0. `onSample` runs on a private queue.
public final class SystemSource: @unchecked Sendable {
    private let interval: TimeInterval
    private let onSample: @Sendable (SystemStats) -> Void
    private let queue = DispatchQueue(label: "vn.kahn.ljdisplay.system")
    // Confined to `queue`.
    private var timer: DispatchSourceTimer?
    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var lastProcTimes: [Int32: UInt64] = [:] // pid → cpu time in ns
    private var lastSampleNs: UInt64 = 0
    private var identities: [Int32: ProcIdentity] = [:]
    private let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    public init(interval: TimeInterval = 1, onSample: @escaping @Sendable (SystemStats) -> Void) {
        self.interval = interval
        self.onSample = onSample
    }

    deinit { timer?.cancel() }

    public func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.sample() }
            timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            lastTicks = nil
            lastProcTimes = [:]
            lastSampleNs = 0
            identities = [:]
        }
    }

    private func sample() {
        let (used, total) = Self.memory()
        let stats = aggregate(cpu: hostCPU(), memUsed: used, memTotal: total, procs: processes())
        if timer != nil { onSample(stats) }
    }

    // MARK: - Host CPU

    private func hostCPU() -> Double {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return 0 }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var busy: UInt64 = 0, total: UInt64 = 0
        let states = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(count) {
            let base = cpu * states
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let sys = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            busy += user + sys + nice
            total += user + sys + nice + idle
        }
        defer { lastTicks = (busy, total) }
        guard let prev = lastTicks, total > prev.total, busy >= prev.busy else { return 0 }
        return min(100, Double(busy - prev.busy) / Double(total - prev.total) * 100)
    }

    // MARK: - Memory

    static func memory() -> (used: UInt64, total: UInt64) {
        let total = ProcessInfo.processInfo.physicalMemory
        var vm = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let st = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard st == KERN_SUCCESS else { return (0, total) }
        let page = UInt64(getpagesize())
        let app = UInt64(vm.internal_page_count) &- min(UInt64(vm.purgeable_count), UInt64(vm.internal_page_count))
        let used = (app + UInt64(vm.wire_count) + UInt64(vm.compressor_page_count)) * page
        return (min(used, total), total)
    }

    // MARK: - Processes

    private func processes() -> [ProcSample] {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let wallNs = lastSampleNs == 0 ? 0 : now - lastSampleNs
        lastSampleNs = now

        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let got = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }

        var out: [ProcSample] = []
        var times: [Int32: UInt64] = [:]
        var ids: [Int32: ProcIdentity] = [:]
        for pid in pids.prefix(Int(got)) where pid > 0 {
            var ru = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
                }
            }
            guard ok == 0 else { continue }
            // Identity lookups (path, argv) only for processes not seen before; keyed by start time against pid reuse.
            let id: ProcIdentity
            if let c = identities[pid], c.start == ru.ri_proc_start_abstime { id = c } else {
                id = Self.identity(pid, start: ru.ri_proc_start_abstime)
            }
            ids[pid] = id
            let cpuNs = (ru.ri_user_time + ru.ri_system_time) * UInt64(timebase.numer) / UInt64(timebase.denom)
            times[pid] = cpuNs
            var cpu = 0.0
            if wallNs > 0, let prev = lastProcTimes[pid], cpuNs >= prev {
                cpu = Double(cpuNs - prev) / Double(wallNs) * 100
            }
            out.append(ProcSample(pid: pid, name: id.name, appPath: id.appPath, cpu: cpu, rssBytes: ru.ri_phys_footprint))
        }
        lastProcTimes = times
        identities = ids
        return out
    }

    struct ProcIdentity { var start: UInt64; var name: String; var appPath: String? }

    /// App processes: path-derived name + enclosing app. Others: argv[0]'s last component (what `ps` and
    /// Activity Monitor show, e.g. "claude" for ~/.local/share/claude/versions/2.1.311), else the path's, else p_comm.
    static func identity(_ pid: Int32, start: UInt64) -> ProcIdentity {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4) // PROC_PIDPATHINFO_MAXSIZE
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? cString(buf) : nil
        let app = path.flatMap(enclosingAppPath)
        let base = path.map { ($0 as NSString).lastPathComponent }
        let name = app != nil ? base! : (argv0(pid) ?? base ?? procName(pid))
        return ProcIdentity(start: start, name: name, appPath: app)
    }

    /// Last path component of argv[0] via KERN_PROCARGS2 (layout: argc i32, exec path, NULs, argv[0], …).
    static func argv0(_ pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        var i = 4
        while i < size && buf[i] != 0 { i += 1 } // exec path
        while i < size && buf[i] == 0 { i += 1 } // padding
        let startIdx = i
        while i < size && buf[i] != 0 { i += 1 }
        guard i > startIdx else { return nil }
        let a = String(decoding: buf[startIdx..<i], as: UTF8.self)
        let last = (a as NSString).lastPathComponent
        return last.isEmpty ? nil : last
    }

    static func procName(_ pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        return proc_name(pid, &buf, UInt32(buf.count)) > 0 ? cString(buf) : "pid \(pid)"
    }
}

private func cString(_ buf: [CChar]) -> String {
    let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
}

/// The outermost `.app` bundle containing `path` (so helper apps nested inside a bundle group with their parent),
/// or nil if the path is not inside an app bundle.
func enclosingAppPath(_ path: String) -> String? {
    guard let r = path.range(of: ".app/") else { return nil }
    return String(path[..<r.lowerBound]) + ".app"
}
