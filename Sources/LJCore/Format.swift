import Foundation

/// Seconds → "m:ss" (or "h:mm:ss" from one hour). Negative / non-finite → "0:00".
public func fmtTime(_ s: Double) -> String {
    let total = s.isFinite && s > 0 ? Int(s) : 0
    let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

/// Time left until `d`: "1h 20m", "3h 05m", "45m". Past → "0m".
public func fmtResetIn(_ d: Date, now: Date) -> String {
    let mins = max(0, Int(d.timeIntervalSince(now) / 60))
    return mins >= 60 ? String(format: "%dh %02dm", mins / 60, mins % 60) : "\(mins)m"
}

private func formatter(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = tz
    f.dateFormat = pattern
    return f
}

/// Absolute reset time: "Thu 14:00".
public func fmtResetAt(_ d: Date, tz: TimeZone = .current) -> String {
    formatter("EEE HH:mm", tz).string(from: d)
}

/// "just now" (< 60 s, or in the future), "4 min", "2 h", else the weekday ("Mon").
public func fmtRelative(_ d: Date, now: Date, tz: TimeZone = .current) -> String {
    let s = now.timeIntervalSince(d)
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60)) min" }
    if s < 86400 { return "\(Int(s / 3600)) h" }
    return formatter("EEE", tz).string(from: d)
}

/// Binary units: "4.2 GB" from 1 GiB, else whole "512 MB".
public func fmtBytes(_ n: UInt64) -> String {
    let gib = 1_073_741_824.0, mib = 1_048_576.0
    let v = Double(n)
    return v >= gib ? String(format: "%.1f GB", v / gib) : String(format: "%.0f MB", v / mib)
}

public enum BatteryClass: Equatable, Sendable { case ok, low, na }

/// Battery colour class: nil → `.na`, below 25 % → `.low`.
public func batteryClass(_ p: Int?) -> BatteryClass {
    guard let p else { return .na }
    return p < 25 ? .low : .ok
}
