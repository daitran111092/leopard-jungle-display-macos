import Foundation

/// Groups per-process samples into apps and returns the top `top` by memory (RSS / footprint).
/// A process belongs to an app when it has an `appPath` (its enclosing `.app` bundle):
/// the app name is the last path component without `.app`. Otherwise it is grouped by `name`.
/// CPU and RSS are summed per group; ties sort by name for a stable order.
public func aggregate(cpu: Double, memUsed: UInt64, memTotal: UInt64, procs: [ProcSample], top: Int = 3) -> SystemStats {
    var groups: [String: AppUsage] = [:]
    for p in procs {
        let key: String
        if let path = p.appPath {
            var last = (path as NSString).lastPathComponent
            if last.hasSuffix(".app") { last.removeLast(4) }
            key = last
        } else {
            key = p.name
        }
        groups[key, default: AppUsage(name: key, cpu: 0, rssBytes: 0)].cpu += p.cpu
        groups[key]!.rssBytes += p.rssBytes
    }
    let sorted = groups.values.sorted { $0.rssBytes != $1.rssBytes ? $0.rssBytes > $1.rssBytes : $0.name < $1.name }
    return SystemStats(cpu: cpu, memUsedBytes: memUsed, memTotalBytes: memTotal, topApps: Array(sorted.prefix(max(0, top))))
}
