import Testing
import Foundation
@testable import LJCore

@Suite struct FormatTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    @Test func time() {
        #expect(fmtTime(84) == "1:24")
        #expect(fmtTime(0) == "0:00")
        #expect(fmtTime(173.9) == "2:53")
        #expect(fmtTime(3725) == "1:02:05")
        #expect(fmtTime(-5) == "0:00")
        #expect(fmtTime(.nan) == "0:00")
    }

    @Test func resetIn() {
        #expect(fmtResetIn(now.addingTimeInterval(80 * 60), now: now) == "1h 20m")
        #expect(fmtResetIn(now.addingTimeInterval(45 * 60), now: now) == "45m")
        #expect(fmtResetIn(now.addingTimeInterval(3 * 3600 + 5 * 60), now: now) == "3h 05m")
        #expect(fmtResetIn(now.addingTimeInterval(-30), now: now) == "0m")
    }

    @Test func resetAt() {
        let utc = TimeZone(identifier: "UTC")!
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 5; c.hour = 14; c.minute = 0  // a Thursday
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let d = cal.date(from: c)!
        #expect(fmtResetAt(d, tz: utc) == "Thu 14:00")
        #expect(fmtResetAt(d, tz: TimeZone(identifier: "Asia/Ho_Chi_Minh")!) == "Thu 21:00")
    }

    @Test func relative() {
        #expect(fmtRelative(now.addingTimeInterval(-10), now: now) == "just now")
        #expect(fmtRelative(now.addingTimeInterval(-59), now: now) == "just now")
        #expect(fmtRelative(now.addingTimeInterval(5), now: now) == "just now")
        #expect(fmtRelative(now.addingTimeInterval(-4 * 60), now: now) == "4 min")
        #expect(fmtRelative(now.addingTimeInterval(-2 * 3600 - 100), now: now) == "2 h")
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let monday = cal.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 9))!
        #expect(fmtRelative(monday, now: monday.addingTimeInterval(2 * 86400), tz: utc) == "Mon")
    }

    @Test func bytes() {
        #expect(fmtBytes(UInt64(4.2 * 1_073_741_824)) == "4.2 GB")
        #expect(fmtBytes(512 * 1_048_576) == "512 MB")
        #expect(fmtBytes(24 * 1_073_741_824) == "24.0 GB")
        #expect(fmtBytes(0) == "0 MB")
    }

    @Test func battery() {
        #expect(batteryClass(82) == .ok)
        #expect(batteryClass(25) == .ok)
        #expect(batteryClass(24) == .low)
        #expect(batteryClass(0) == .low)
        #expect(batteryClass(nil) == .na)
    }
}
