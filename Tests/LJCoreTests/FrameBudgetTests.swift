import Testing
import Foundation
@testable import LJCore

@Suite struct FrameBudgetTests {
    @Test func stepsDownUntilUnderBudget() {
        var b = FrameBudget()
        let d = b.encode { Data(count: Int($0 * 150_000)) }!
        #expect(d.count <= 92160)
        #expect(b.q == 0.60)
    }
    @Test func stopsAtFloor() {
        var b = FrameBudget()
        let d = b.encode { _ in Data(count: 200 * 1024) }!
        #expect(d.count == 200 * 1024)
        #expect(b.q == 0.40)
    }
    @Test func raisesQualityWhenFarUnder() {
        var b = FrameBudget()
        _ = b.encode { Data(count: Int($0 * 50_000)) }
        #expect(b.q == 0.85)
    }
    @Test func neverExceedsMax() {
        var b = FrameBudget()
        for _ in 0..<10 { _ = b.encode { _ in Data(count: 1000) } }
        #expect(b.q == 0.90)
    }
    /// Hardware JPEG sizes jump between quality steps (q 0.60 → 46 KB, 0.65 → 100+ KB): the budget must
    /// not raise into a quality that just overflowed, or every frame costs two encodes.
    @Test func doesNotOscillateAcrossASizeCliff() {
        var b = FrameBudget()
        var calls = 0
        let enc: (Double) -> Data = { q in calls += 1; return Data(count: q >= 0.65 - 1e-9 ? 110_000 : 46_000) }
        for _ in 0..<100 { #expect(b.encode(enc)!.count <= 92160) }
        #expect(calls <= 100 + 4) // only the first frame steps down (0.80 → 0.60: 5 encodes)
        #expect(b.q == 0.60)
    }

    @Test func retriesHigherQualityAfterHoldExpires() {
        var b = FrameBudget()
        var big = true
        var tried: [Double] = []
        let enc: (Double) -> Data = { q in tried.append(q); return Data(count: big && q > 0.6 + 1e-9 ? 110_000 : 30_000) }
        _ = b.encode(enc)
        big = false // content got simpler
        for _ in 0..<(FrameBudget.ceilingHold + 5) { _ = b.encode(enc) }
        #expect(tried.max()! > 0.6 + 1e-9 && b.q > 0.6 + 1e-9)
    }

    /// An encoder failure (nil or empty) is not "far under budget": nil out, quality unchanged.
    @Test func failureLeavesBudgetUnchanged() {
        var b = FrameBudget()
        #expect(b.encode { _ in nil } == nil)
        #expect(b.q == 0.80)
        #expect(b.encode { _ in Data() } == nil)
        #expect(b.q == 0.80)
    }
}
