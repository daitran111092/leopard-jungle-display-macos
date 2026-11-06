import CoreGraphics
import Foundation
import LJCore

/// The frame loop's decision logic, clock-free so it can be tested tick by tick.
///
/// Each `tick` steps the rail glide (always, so its easing clock stays current), then renders,
/// encodes and pushes one frame iff the panel is connected AND any of:
/// - `markDirty()` was called since the last pushed frame (state change, panel (re)connect);
/// - `animationRate` is `.full` (page slide): every tick;
/// - `animationRate` is `.music` (music playing on the Music page) and ≥ 1/`Anim.musicFPS` s passed since
///   the last pushed frame, or `.ambient` (warning stripes/flash, bars gliding) and ≥ 1/`Anim.ambientFPS` s
///   (half a tick of slack for timer jitter in both);
/// - the rail glide settled, or latched a readout, since the last pushed frame (one frame, so the
///   resting bar position is always drawn even when the ambient cap skipped the landing tick);
/// - the wall-clock minute differs from the last pushed frame's (the nav clock).
/// While disconnected nothing is rendered and the dirty flag is kept for the next connected tick.
@MainActor
public final class FrameLoopCore {
    public typealias Render = (_ state: UiState, _ t: TimeInterval, _ now: Date, _ rail: RailMotion?) -> CGImage

    private let render: Render
    private let encode: (CGImage) -> Data?
    private let push: (Data) -> Void
    private let isConnected: () -> Bool
    private let glide = RailGlide()

    private var dirty = false
    private var lastMinute: Int?
    private var lastPushAt: Date?
    private var lastRail: RailMotion?
    /// Ambient frames are due after this long (1/20 s minus half a 60 Hz tick of jitter slack).
    static let ambientInterval = 1 / Anim.ambientFPS - 0.5 / 60
    /// Music frames are due after this long (1/`Anim.musicFPS` s minus half a 60 Hz tick).
    static let musicInterval = 1 / Anim.musicFPS - 0.5 / 60
    /// `now` of each frame pushed within the last second (oldest first).
    private var pushedAt: [Date] = []

    public init(render: @escaping Render,
                encode: @escaping (CGImage) -> Data?,
                push: @escaping (Data) -> Void,
                isConnected: @escaping () -> Bool) {
        self.render = render
        self.encode = encode
        self.push = push
        self.isConnected = isConnected
    }

    public func markDirty() { dirty = true }

    /// Frames pushed in the second up to the latest tick.
    public var fps: Double { Double(pushedAt.count) }

    public func tick(state: UiState, now: Date, t: TimeInterval) {
        trim(now)
        // Converging *into* this tick: a fresh sample starts the glide, and the step that lands it is still drawn.
        let moving = glide.barsMoving(state)
        let rail = glide.step(state, t: t)
        let minute = Int(floor(now.timeIntervalSince1970 / 60))
        guard isConnected() else { return }
        let minuteRolled = lastMinute.map { $0 != minute } ?? false
        // The glide came to rest (or latched a readout) on a tick the ambient cap skipped: draw it once.
        let railSettled = lastPushAt != nil && rail != lastRail && !glide.barsMoving(state)
        let due: Bool
        switch animationRate(state, now: now, glideConverging: moving) {
        case .full: due = true
        case .music: due = lastPushAt.map { now.timeIntervalSince($0) >= Self.musicInterval } ?? true
        case .ambient: due = lastPushAt.map { now.timeIntervalSince($0) >= Self.ambientInterval } ?? true
        case .none: due = false
        }
        guard dirty || minuteRolled || railSettled || due else { return }
        // Encode failure: push nothing, keep dirty so the next tick retries (an empty frame is never sent).
        guard let jpeg = encode(render(state, t, now, rail)), !jpeg.isEmpty else { dirty = true; return }
        push(jpeg)
        dirty = false
        lastMinute = minute
        lastPushAt = now
        lastRail = rail
        pushedAt.append(now)
    }

    private func trim(_ now: Date) {
        while let first = pushedAt.first, now.timeIntervalSince(first) >= 1 { pushedAt.removeFirst() }
    }
}
