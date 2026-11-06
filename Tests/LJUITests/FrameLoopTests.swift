import Testing
import Foundation
import CoreGraphics
import LJCore
@testable import LJUI

private let pixel: CGImage = {
    let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    return ctx.makeImage()!
}()

/// FrameLoopCore wired to counters; ticks at 60 Hz from `start` (…:30 past a whole minute).
@MainActor
private final class Harness {
    let start = Date(timeIntervalSince1970: 1_793_786_430)
    var renders = 0
    var encodes = 0
    var pushes: [Data] = []
    var connected = true
    var encodeFails = false
    var rails: [RailMotion?] = []
    private(set) var n = 0
    lazy var core = FrameLoopCore(
        render: { [unowned self] _, _, _, rail in renders += 1; rails.append(rail); return pixel },
        encode: { [unowned self] _ in encodes += 1; return encodeFails ? nil : Data([0xff, 0xd8]) },
        push: { [unowned self] d in pushes.append(d) },
        isConnected: { [unowned self] in connected })

    /// Runs `count` ticks of 1/60 s each.
    func ticks(_ count: Int, _ s: UiState) {
        for _ in 0..<count {
            let t = Double(n) / 60
            core.tick(state: s, now: start.addingTimeInterval(t), t: t)
            n += 1
        }
    }
}

private var warning: UiState {
    var s = UiState()
    s.audio = AudioOutput(name: "MacBook Pro Speakers", transport: .builtin, isBuiltInSpeaker: true)
    return s
}

@MainActor
@Suite struct FrameLoopTests {
    @Test func staticStateSendsNothing() {
        let h = Harness()
        h.ticks(60, UiState())
        #expect(h.pushes.isEmpty)
        #expect(h.renders == 0)
        #expect(h.core.fps == 0)
    }

    @Test func stateChangeWhileIdleRendersNextTick() {
        let h = Harness()
        h.ticks(10, UiState())
        h.core.markDirty()
        h.ticks(1, UiState())
        #expect(h.pushes.count == 1)
        h.ticks(30, UiState())
        #expect(h.pushes.count == 1)
        #expect(h.renders == 1 && h.encodes == 1)
    }

    /// Page slides are full-rate: every tick.
    @Test func animatingStateSendsEveryTick() {
        let h = Harness()
        let s = reduce(UiState(), .nextPage, now: h.start).0
        h.ticks(30, s)
        #expect(h.pushes.count == 30)
    }

    /// The speaker warning (stripes/flash) is ambient: capped at 20 fps.
    @Test func warningAloneAnimatesAt20fps() {
        let h = Harness()
        h.ticks(60, warning)
        #expect(h.pushes.count == 20)
        #expect(h.core.fps == 20)
    }

    /// Music playing on the visible Music page: every 60 Hz tick.
    @Test func frameLoopRunsMusicAt60() {
        let h = Harness()
        var s = UiState()
        s.music = NowPlaying(title: "Enemy", artist: "Imagine Dragons", album: "Arcane", appName: "Spotify",
                             bundleID: "com.spotify.client", duration: 173, elapsed: 10, elapsedAt: h.start, playing: true)
        h.ticks(60, s)
        #expect(h.pushes.count == 60)
        // Paused: static.
        s.music!.playing = false
        let before = h.pushes.count
        h.ticks(60, s)
        #expect(h.pushes.count == before)
    }

    /// (b) An active page transition lifts an ambient animation back to 60 fps.
    @Test func pageTransitionRestoresFullRateOverAmbient() {
        let h = Harness()
        var s = warning
        s = reduce(s, .nextPage, now: h.start).0
        h.ticks(30, s)                 // slide: t 0 ..< 0.5 s
        #expect(h.pushes.count == 30)
        h.ticks(30, s)                 // slide over, warning only
        #expect(h.pushes.count == 30 + 10)
    }

    /// (a) A glide alone (no slide, no warning) is ambient: ≤ 20 frames/s.
    @Test func glideAloneIsCappedAt20fps() {
        let h = Harness()
        var s = UiState()
        s.system = SystemStats(cpu: 10, memUsedBytes: 4, memTotalBytes: 16)
        h.core.markDirty()
        h.ticks(60, s)
        #expect(h.pushes.count == 1)
        s.system!.cpu = 90             // big jump: bars glide for a while
        h.core.markDirty()
        let before = h.pushes.count
        h.ticks(60, s)
        let n = h.pushes.count - before
        #expect(n > 5 && n <= 21)      // the dirty frame + ≤ 20 glide frames
    }

    /// (c) A 1 Hz sample whose change is below 1 px of bar width: the dirty frame, then nothing.
    @Test func subPixelSampleCausesNoFollowUpFrames() {
        let h = Harness()
        var s = UiState()
        s.system = SystemStats(cpu: 10, memUsedBytes: 4, memTotalBytes: 16)
        h.core.markDirty()
        h.ticks(60, s)                 // first sample, settled; 1 s later the next one arrives
        s.system!.cpu = 10.2           // 0.002 of bar width < epsilon
        h.core.markDirty()
        let before = h.pushes.count
        h.ticks(60, s)
        #expect(h.pushes.count - before == 1)
        #expect(h.rails.last??.readout.cpu == 10.2) // the dirty frame already shows the new readout
    }

    @Test func pageSlideAnimatesForHalfASecondThenStops() {
        let h = Harness()
        var s = UiState()
        s = reduce(s, .nextPage, now: h.start).0
        h.core.markDirty()
        h.ticks(60, s)
        #expect(h.pushes.count == 30) // t = 0 ..< 0.5 s
    }

    @Test func noRenderWhileDisconnected() {
        let h = Harness()
        h.connected = false
        h.core.markDirty()
        h.ticks(60, warning)
        #expect(h.renders == 0 && h.encodes == 0 && h.pushes.isEmpty)
        // Dirty survives the disconnect: the first connected tick draws a static state.
        h.connected = true
        h.ticks(5, UiState())
        #expect(h.pushes.count == 1)
    }

    @Test func encodeFailurePushesNothingAndStaysDirty() {
        let h = Harness()
        h.encodeFails = true
        h.core.markDirty()
        h.ticks(1, UiState())
        #expect(h.encodes == 1 && h.pushes.isEmpty)
        #expect(h.core.fps == 0)
        h.encodeFails = false
        h.ticks(1, UiState())          // still dirty: retried on the next tick
        #expect(h.pushes.count == 1)
        h.ticks(10, UiState())
        #expect(h.pushes.count == 1)
    }

    /// A backward wall-clock jump after a page change must not pin the loop at full rate.
    @Test func backwardClockJumpDoesNotPinFullRate() {
        let h = Harness()
        let future = h.start.addingTimeInterval(3600) // page changed "an hour from now" = clock stepped back
        var s = UiState()
        s = reduce(s, .nextPage, now: future).0
        h.core.markDirty()
        h.ticks(60, s)
        #expect(h.pushes.count == 1)
        #expect(animationRate(s, now: h.start) == .none)
    }

    @Test func fpsCountsLastSecond() {
        let h = Harness()
        let slide = reduce(UiState(), .nextPage, now: h.start).0
        h.ticks(30, slide)
        h.ticks(30, UiState())
        #expect(h.core.fps == 30)
        h.ticks(15, UiState()) // the window slides past the first 15 slide frames
        #expect(h.core.fps == 15)
        h.ticks(60, UiState())
        #expect(h.core.fps == 0)
    }

    @Test func minuteRolloverRedrawsTheClock() {
        let h = Harness()
        h.core.markDirty()
        h.ticks(1, UiState())          // hh:mm:30
        h.ticks(1798, UiState())       // up to hh:mm:59.97
        #expect(h.pushes.count == 1)
        h.ticks(2, UiState())          // reaches hh:(mm+1):00
        #expect(h.pushes.count == 2)
    }

    @Test func glideIsSteppedAndPassedToRender() {
        let h = Harness()
        var s = UiState()
        s.system = SystemStats(cpu: 10, memUsedBytes: 4, memTotalBytes: 16)
        h.core.markDirty()
        h.ticks(1, s)
        #expect(h.rails.last??.cpuBar == 0.10)
        s.system!.cpu = 60 // new sample: bars glide for a while, then stop
        h.core.markDirty()
        h.ticks(1, s)
        let first = h.rails.last??.cpuBar ?? 0
        #expect(first > 0.10 && first < 0.60)
        h.ticks(120, s)
        #expect(h.rails.last??.cpuBar == 0.60)
        let settled = h.pushes.count
        h.ticks(60, s)
        #expect(h.pushes.count == settled)
    }
}
