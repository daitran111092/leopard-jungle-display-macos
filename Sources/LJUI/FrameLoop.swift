import CoreGraphics
import Foundation
import LJCore

/// The app's frame loop: a 60 Hz `DispatchSourceTimer` on the main queue driving `FrameLoopCore` with
/// `RootView` → `ViewRenderer` → `FrameEncoder` (adaptive 300 KB / q ≤ 0.95 budget) → `push`.
///
/// Animation time is wall clock: `now = Date()`, `t = now − start`. An `AppStore` observer marks the core
/// dirty; call `panelConnected()` after every (re)connect so the new session gets a frame at once.
@MainActor
public final class FrameLoop {
    public static let hz = 60.0

    public let store: AppStore
    /// Timer rate (ticks per second), 1…60.
    public let hz: Double
    public let core: FrameLoopCore
    private let startDate = Date()
    private var timer: DispatchSourceTimer?

    /// Rendering resources, shared by the core's closures.
    @MainActor private final class Pipeline {
        let renderer: ViewRenderer<RootView>
        let encoder: FrameEncoder
        /// Panel frames: up to q 0.95 within 300 KB (~11 ms over USB bulk, so 60 fps still fits).
        var budget: FrameBudget = { var b = FrameBudget(); b.maxBytes = 300 * 1024; b.maxQ = 0.95; return b }()
        var stats = FrameStats()
        var lastPushNs: UInt64 = 0
        init(_ initial: RootView, log: @escaping (String) -> Void) {
            renderer = ViewRenderer(size: Screen.size, initial: initial)
            encoder = FrameEncoder(log: log)
        }
    }

    /// `log` receives encoder events (hardware JPEG failures/recovery) for the app log.
    public init(store: AppStore, hz: Double = FrameLoop.hz, push: @escaping (Data) -> Void, isConnected: @escaping () -> Bool,
                log: @escaping (String) -> Void = { _ in }) {
        self.store = store
        self.hz = min(max(hz, 1), Self.hz)
        // Prewarm fonts, decor (incl. monkey.png) and SwiftUI: the first real frame must not stall the loop.
        Fonts.register()
        for theme in [Theme.jinx, .jinxBlue] { _ = Decor.image(theme) }
        let p = Pipeline(RootView(state: store.state, t: 0, now: startDate), log: log)
        var warm = FrameBudget()
        _ = p.encoder.encode(p.renderer.render(RootView(state: store.state, t: 0, now: startDate)), budget: &warm)
        core = FrameLoopCore(
            render: { s, t, now, rail in
                let t0 = DispatchTime.now().uptimeNanoseconds
                let img = p.renderer.render(RootView(state: s, t: t, now: now, rail: rail))
                p.stats.renderNs += DispatchTime.now().uptimeNanoseconds - t0
                return img
            },
            encode: { img in
                let t0 = DispatchTime.now().uptimeNanoseconds
                let d = p.encoder.encode(img, budget: &p.budget)
                p.stats.encodeNs += DispatchTime.now().uptimeNanoseconds - t0
                guard let d else { return nil }
                p.stats.frames += 1
                p.stats.bytes += d.count
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if p.lastPushNs > 0 {
                    let gapMs = Double(nowNs - p.lastPushNs) / 1e6
                    if gapMs < 250 {                                   // ignore idle gaps between animations
                        p.stats.maxGapMs = max(p.stats.maxGapMs, gapMs)
                        if gapMs > 50 { p.stats.lateFrames += 1 }
                    }
                }
                p.lastPushNs = nowNs
                p.stats.quality = p.budget.q
                return d
            },
            push: push,
            isConnected: isConnected)
        store.observe { [weak core] in core?.markDirty() }
        pipeline = p
    }

    private let pipeline: Pipeline

    /// Per-frame cost counters since the last call (for logging), then reset.
    public func takeStats() -> FrameStats {
        defer { pipeline.stats = FrameStats() }
        return pipeline.stats
    }

    /// Frames pushed in the last second (0 while the timer is stopped).
    public var fps: Double { timer == nil ? 0 : core.fps }

    /// True while the 60 Hz timer runs.
    public var isRunning: Bool { timer != nil }

    public func panelConnected() { core.markDirty() }

    public func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1 / hz, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.tick() } }
        timer = t
        t.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        autoreleasepool {
            let now = Date()
            core.tick(state: store.state, now: now, t: now.timeIntervalSince(startDate))
        }
    }
}

/// Render/encode cost accumulated by `FrameLoop` between `takeStats()` calls.
public struct FrameStats: Sendable {
    public var frames = 0
    public var renderNs: UInt64 = 0
    public var encodeNs: UInt64 = 0
    public var bytes = 0
    /// JPEG quality after the latest frame.
    public var quality = 0.0
    /// Longest gap between consecutive pushed frames during continuous animation (ms), and how many exceeded 50 ms.
    public var maxGapMs = 0.0
    public var lateFrames = 0

    public var renderMs: Double { frames == 0 ? 0 : Double(renderNs) / 1e6 / Double(frames) }
    public var encodeMs: Double { frames == 0 ? 0 : Double(encodeNs) / 1e6 / Double(frames) }
    public var avgKB: Double { frames == 0 ? 0 : Double(bytes) / 1024 / Double(frames) }
}
