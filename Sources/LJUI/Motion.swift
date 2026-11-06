import Foundation
import LJCore

/// What the rail draws for the system meters on this frame.
///
/// `RootView` stays a pure function of its inputs: the bar glide and the 2 Hz readout latch live
/// in `RailGlide`, a tiny stateful helper owned by the frame loop. Each tick the loop calls
/// `glide.step(state, t:)` and passes the result to `RootView(state:t:now:rail:)`. Without a
/// `RailMotion` (fixtures, tests) the rail draws the state's values directly.
public struct RailMotion: Equatable, Sendable {
    /// Displayed CPU bar fill, 0...1 (eases toward the target).
    public var cpuBar: Double
    /// Displayed RAM bar fill, 0...1.
    public var memBar: Double
    /// The stats shown as text: latched at most twice a second (`floor(t * 2)`).
    public var readout: SystemStats

    public init(cpuBar: Double, memBar: Double, readout: SystemStats) {
        self.cpuBar = cpuBar; self.memBar = memBar; self.readout = readout
    }
}

extension SystemStats {
    var cpuFraction: Double { min(1, max(0, cpu / 100)) }
    var memFraction: Double { memTotalBytes == 0 ? 0 : min(1, Double(memUsedBytes) / Double(memTotalBytes)) }
}

/// Bars glide: exponential easing toward the target with time constant `tau`
/// (the mockup's 0.25-per-frame at 17 fps ≈ 0.2 s), snapping within ~1 px of bar width.
/// Readouts are latched on each `floor(t * 2)` tick, or at once when the last latch is ≥ 0.5 s old
/// (so a 1 Hz sample shows in the frame its state change triggers, without a follow-up latch frame).
@MainActor
public final class RailGlide {
    public static let tau = 0.2
    /// Approximate drawn width of one meter bar (rail 620 px, two meters side by side).
    public static let barWidthPx = 270.0
    /// Snap distance: one pixel of bar width.
    public static let epsilon = 1 / barWidthPx
    /// Largest dt one step may advance the glide by (s).
    public static let maxStep = 1.0 / 30

    public private(set) var motion: RailMotion?
    private var lastT: TimeInterval?
    private var tick = Int.min
    private var latchedAt = -Double.infinity

    public init() {}

    @discardableResult
    public func step(_ s: UiState, t: TimeInterval) -> RailMotion? {
        defer { lastT = t }
        guard let sys = s.system else { motion = nil; return nil }
        guard var m = motion else {
            tick = Int(floor(t * 2))
            latchedAt = t
            motion = RailMotion(cpuBar: sys.cpuFraction, memBar: sys.memFraction, readout: sys)
            return motion
        }
        // Clamp dt: the loop sends no frames while static, so the first step after an idle gap
        // would otherwise see dt ≈ seconds, get k ≈ 1 and snap. A new target always eases from here.
        let dt = min(Self.maxStep, max(0, t - (lastT ?? t)))
        let k = 1 - exp(-dt / Self.tau)
        m.cpuBar = Self.approach(m.cpuBar, sys.cpuFraction, k)
        m.memBar = Self.approach(m.memBar, sys.memFraction, k)
        let q = Int(floor(t * 2))
        if m.readout != sys, q != tick || t - latchedAt >= 0.5 { tick = q; latchedAt = t; m.readout = sys }
        else if q != tick { tick = q }
        motion = m
        return m
    }

    /// True while bars are still moving or a newer readout is waiting for the next 2 Hz tick.
    public func isConverging(_ s: UiState) -> Bool {
        guard let m = motion, let sys = s.system else { return false }
        return barsMoving(s) || m.readout != sys
    }

    /// True while a bar is still easing toward its target (the readout latch is not counted:
    /// the frame loop draws a latch change as a single frame).
    public func barsMoving(_ s: UiState) -> Bool {
        guard let m = motion, let sys = s.system else { return false }
        return m.cpuBar != sys.cpuFraction || m.memBar != sys.memFraction
    }

    private static func approach(_ v: Double, _ target: Double, _ k: Double) -> Double {
        let n = v + (target - v) * k
        return abs(target - n) < epsilon ? target : n
    }
}

public enum Anim {
    /// Page slide duration (ease-out-cubic).
    public static let pageSlide: TimeInterval = 0.5
    /// Frame rate cap for ambient-only animation (rail glide, speaker-warning stripes/flash).
    public static let ambientFPS = 20.0
    /// Frame rate cap while music plays on the visible Music page.
    public static let musicFPS = 60.0
}

/// How often the frame loop must draw. Ordered by rate: `none < ambient < music < full`.
public enum AnimationRate: Int, Comparable, Sendable {
    /// Nothing moves: draw only on state changes.
    case none
    /// Only ambient motion (glide, warning): at most `Anim.ambientFPS`.
    case ambient
    /// Music playing on the visible Music page (EQ bars, beat pulse, seek): at most `Anim.musicFPS`.
    case music
    /// A page transition: every tick (60 fps).
    case full

    public static func < (a: AnimationRate, b: AnimationRate) -> Bool { a.rawValue < b.rawValue }
}

/// Full rate while a page slide is < 0.5 s old; `.music` while music plays on the Music page; ambient in
/// the speaker warning state or while the rail bars are still gliding (`glideConverging`).
public func animationRate(_ s: UiState, now: Date, glideConverging: Bool = false) -> AnimationRate {
    // Range check: after a backward wall-clock step the age is negative; treat the slide as finished.
    if let at = s.pageChangedAt, (0..<Anim.pageSlide).contains(now.timeIntervalSince(at)) { return .full }
    if s.page == .music, s.music?.playing == true { return .music }
    if s.audio?.isBuiltInSpeaker == true || glideConverging { return .ambient }
    return .none
}

/// True when anything animates (any `AnimationRate` but `.none`).
public func needsAnimation(_ s: UiState, now: Date, glideConverging: Bool = false) -> Bool {
    animationRate(s, now: now, glideConverging: glideConverging) != .none
}
