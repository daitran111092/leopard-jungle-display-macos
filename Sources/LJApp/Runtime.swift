import AppKit
import CoreText
import Foundation
import notify
import LJCore
import LJSources
import LJUI

/// The live dashboard, shared by `LJ Display.app` and `ljprobe stream`:
/// PanelDiscovery → PanelLink (connect off main, reconnect) ; Audio/Bluetooth/System/NowPlaying sources → AppStore ;
/// HotKeys → `reduce` → AppStore (+ effects; `.media` → MediaSendQueue → NowPlayingSource.send) ;
/// AppStore → FrameLoop → panel. Main-thread only.
///
/// The frame-loop timer runs only while the panel is connected, streaming is not paused and the Mac is
/// awake. Before system sleep the panel session is closed and discovery stopped; on wake discovery
/// restarts and reports the panel again, which reconnects.
@MainActor public final class LJRuntime {
    public struct Options {
        public var shortcuts: [Action: [String]]
        public var theme: Theme
        public var brightness: Int
        public var maxFps: Int
        /// Force the built-in-speaker warning (load test).
        public var forceWarn = false
        /// Run SystemSource (off → truly static rail).
        public var systemStats = true
        /// Log a stats line every this many seconds (0 → never).
        public var statsLogInterval: Int = 1
        /// Run NowPlayingSource (needs the mediaremote-adapter; see `NowPlayingSource.locateAdapter`).
        public var nowPlaying = true

        public init(config: AppConfig) {
            shortcuts = config.shortcuts
            theme = config.theme
            brightness = config.clampedBrightness
            maxFps = config.clampedMaxFps
        }
    }

    public let store: AppStore
    public let link = PanelLink()
    public let loop: FrameLoop
    public private(set) var paused = false
    public private(set) var failedKeys: [HotKeys.Failure] = []
    /// Frames handed to the panel since launch.
    public private(set) var framesPushed = 0
    /// Effects returned by the reducer, after the runtime ran its own (`.media` is sent by the runtime).
    public var onEffects: (([Effect]) -> Void)?
    /// Once a second, and after connect / disconnect / pause changes (e.g. to refresh a status line).
    public var onStatus: (() -> Void)?
    /// Panel backlight, percent; applied now and after every (re)connect.
    public var brightness: Int {
        didSet { brightness = min(max(brightness, 0), 100); link.setBrightness(brightness) }
    }

    private let options: Options
    private var keys: HotKeys!
    private var audio: AudioSource!
    private var bluetooth: BluetoothSource!
    private var system: SystemSource!
    private var nowPlaying: NowPlayingSource?
    private var media: MediaSendQueue!
    private var debugTokens: [Int32] = []
    private var discovery: PanelDiscovery!
    private var tick: DispatchSourceTimer?
    private var meter = ProcMeter()
    private var ticks = 0
    private var asleep = false
    private var sleepObservers: [NSObjectProtocol] = []
    private var started = false

    public init(options: Options) {
        self.options = options
        brightness = options.brightness
        var initial = UiState()
        initial.page = .music // the app always starts on the Music page
        initial.theme = options.theme
        let store = AppStore(initial)
        self.store = store
        let link = self.link
        loop = FrameLoop(store: store, hz: Double(options.maxFps), push: { d in link.push(d) }, isConnected: { link.isConnected && !link.isBusy },
                         log: { Log.line($0) })
        wire()
    }

    /// Current state for a status line: `Connected · 60 fps` / `Panel not found`.
    public var statusLine: String { Self.statusLine(connected: link.isConnected, fps: loop.fps) }

    public nonisolated static func statusLine(connected: Bool, fps: Double) -> String {
        connected ? "Connected · \(Int(fps.rounded())) fps" : "Panel not found"
    }

    private func wire() {
        link.onConnected = { [weak self] _ in
            guard let self else { return }
            link.setBrightness(brightness)
            loop.panelConnected()
            updateLoop()
        }
        link.onDisconnected = { [weak self] in self?.updateLoop() }

        let store = self.store
        let forceWarn = options.forceWarn
        bluetooth = BluetoothSource { devs in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                store.update { $0.bluetooth = devs }
                Log.line("bt: \(devs.map(\.name))")
            } }
        }
        @MainActor final class Last { var device: AudioOutput?? = nil } // nil = nothing seen yet
        let last = Last()
        audio = AudioSource { [weak self] out in
            DispatchQueue.main.async { MainActor.assumeIsolated {
                let deviceChanged = last.device.map { $0?.name != out?.name || $0?.transport != out?.transport } ?? true
                last.device = .some(out)
                store.update {
                    $0.audio = forceWarn ? AudioOutput(name: "MacBook Pro Speakers (--warn)", transport: .builtin, isBuiltInSpeaker: true) : out
                }
                Log.line("audio: \(out.map { "\"\($0.name)\" builtInSpeaker=\($0.isBuiltInSpeaker) format=\($0.sampleRate.map { fmtAudioFormat(sampleRate: $0, bitDepth: out?.bitDepth) } ?? "unknown")" } ?? "none")")
                // AirPods (dis)connecting always changes the default output device; volume steps don't need a BT re-read.
                if deviceChanged { self?.bluetooth.refresh() }
            } }
        }
        system = SystemSource { st in
            DispatchQueue.main.async { MainActor.assumeIsolated { store.update { $0.system = st } } }
        }
        if options.nowPlaying {
            if let dir = NowPlayingSource.locateAdapter() {
                @MainActor final class LastTrack { var key: String?? = nil }
                let lastTrack = LastTrack()
                nowPlaying = NowPlayingSource(adapterDir: dir, log: { msg in
                    DispatchQueue.main.async { Log.line(msg) }
                }) { np in
                    DispatchQueue.main.async { MainActor.assumeIsolated {
                        store.update { $0 = mergeAdapterMusic($0, np, now: Date()) }
                        // Log once per track / play state change, not per position update.
                        let key = np.map { "\($0.playing ? "playing" : "paused") \"\($0.title)\" — \($0.artist) [\($0.appName)]" }
                        if lastTrack.key != .some(key) {
                            lastTrack.key = .some(key)
                            Log.line("nowplaying: \(key ?? "nothing playing")")
                        }
                    } }
                }
            } else {
                Log.line("nowplaying: adapter not found; Music page stays idle")
            }
        }
        media = MediaSendQueue { [weak self] cmd, done in
            guard let src = self?.nowPlaying else { done(); return }
            Log.line("media: send \(Self.describe(cmd))")
            src.send(cmd) { DispatchQueue.main.async { MainActor.assumeIsolated { done() } } }
        }
        keys = HotKeys(bindings: options.shortcuts) { [weak self] a in self?.perform(a) }
        discovery = PanelDiscovery(onAppear: { [weak self] p in Log.line("panel: appeared \(p)"); self?.link.appeared(p) },
                                   onDisappear: { [weak self] in Log.line("panel: disappeared"); self?.link.disappeared() })
    }

    /// Applies a hot-key action: reducer → store, `.media` effects → MediaSendQueue, then all effects → `onEffects`.
    public func perform(_ a: Action) {
        var effects: [Effect] = []
        store.update { s in (s, effects) = reduce(s, a, now: Date()) }
        Log.line("action: \(a.rawValue) -> page \(store.state.page)\(effects.map { " -> \(Self.describe($0))" }.joined())")
        for case .media(let c) in effects { media.enqueue(c) }
        if !effects.isEmpty { onEffects?(effects) }
        if let until = store.state.musicHold?.until {
            // An unconfirmed optimistic seek / play state falls back to the adapter's state when the hold ends.
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until.timeIntervalSinceNow) + 0.05) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let h = self.store.state.musicHold, h.until <= Date() else { return }
                    self.store.update { $0 = expireMusicHold($0, now: Date()) }
                    Log.line("nowplaying: optimistic \(h.seek.map { String(format: "seek %.1f s", $0) } ?? "")\(h.playing.map { $0 ? "play" : "pause" } ?? "") not confirmed; reverted")
                }
            }
        }
    }

    nonisolated static func describe(_ e: Effect) -> String {
        switch e {
        case .media(let c): return "media \(describe(c))"
        }
    }

    nonisolated static func describe(_ c: MediaCommand) -> String {
        if case .seek(let x) = c { return String(format: "seek %.1f s", x) }
        return "\(c)"
    }

    /// Debug only (LJ_DEBUG_ACTIONS=1): `notifyutil -p vn.kahn.ljdisplay.debug.<action>` performs that action as if
    /// its hot key were pressed, to check the effect path without a keyboard. Call before or after `start()`.
    public func enableDebugActions() {
        guard debugTokens.isEmpty else { return }
        for a in Action.allCases {
            var token: Int32 = 0
            let name = "vn.kahn.ljdisplay.debug.\(a.rawValue)"
            let st = notify_register_dispatch(name, &token, .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.line("debug: \(a.rawValue)")
                    self?.perform(a)
                }
            }
            if st == NOTIFY_STATUS_OK { debugTokens.append(token) }
        }
        Log.line("debug: actions on (\(debugTokens.count) notify names vn.kahn.ljdisplay.debug.<action>)")
    }

    public func start() {
        guard !started else { return }
        started = true
        failedKeys = keys.register()
        let n = keys.bindingCount
        Log.line("keys: registered \(n - failedKeys.count)/\(n)\(failedKeys.isEmpty ? "" : ", failed \(failedKeys)")")
        Log.line("resources: \(LJResources.url?.path ?? "MISSING"); fonts \(Fonts.register().count) (display → \(CTFontCopyPostScriptName(Fonts.ctFont(.display, 24)))), monkey \(Decor.monkeyLoaded ? "ok" : "MISSING")")
        audio.start()
        bluetooth.start()
        if options.systemStats { system.start() }
        nowPlaying?.start()
        discovery.start()
        observeSleep()

        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.everySecond() } }
        tick = t
        t.resume()
    }

    /// Stops everything. With `clearPanel`, writes the CLEAR sequence before closing the port.
    /// Returns true iff a CLEAR was written.
    @discardableResult
    public func stop(clearPanel: Bool) -> Bool {
        tick?.cancel(); tick = nil
        loop.stop()
        keys.unregister()
        discovery.stop(); audio.stop(); bluetooth.stop(); system.stop()
        media.cancelAll()
        nowPlaying?.stop()
        for t in debugTokens { notify_cancel(t) }
        debugTokens = []
        for o in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        sleepObservers = []
        let cleared = link.close(sendingClear: clearPanel)
        if clearPanel { Log.line(cleared ? "panel: CLEAR sent on quit" : "panel: no session to clear on quit") }
        started = false
        return cleared
    }

    public func setPaused(_ p: Bool) {
        guard p != paused else { return }
        paused = p
        Log.line(p ? "stream: paused" : "stream: resumed")
        if !p { loop.panelConnected() } // redraw at once: state may have changed while paused
        updateLoop()
    }

    public func setTheme(_ t: Theme) { store.update { $0.theme = t } }

    private func updateLoop() {
        if link.isConnected && !paused && !asleep { loop.start() } else { loop.stop() }
        onStatus?()
    }

    private func observeSleep() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willSleep() }
            },
            nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didWake() }
            },
        ]
    }

    private func willSleep() {
        Log.line("system: will sleep")
        asleep = true
        loop.stop()
        discovery.stop()
        link.suspend()
        updateLoop()
    }

    private func didWake() {
        Log.line("system: did wake, rediscovering panel")
        asleep = false
        discovery.start() // reports the present panel → appeared → connect → loop starts
        updateLoop()
    }

    private var gapMax = 0.0
    private var gapLate = 0

    private func everySecond() {
        ticks += 1
        let f = loop.takeStats()
        framesPushed += f.frames
        gapMax = max(gapMax, f.maxGapMs)
        gapLate += f.lateFrames
        if options.statsLogInterval > 0 && ticks % options.statsLogInterval == 0 {
            Log.line(String(format: "fps %2.0f  frames %d  cpu %4.1f%%  rss %@  footprint %@  render %.2f ms  encode %.2f ms  %.0f KB q %.2f  gap max %.0f ms late %d  panel %@  page %@%@",
                            loop.fps, framesPushed, meter.cpuPercent(), mb(ProcMeter.residentBytes()), mb(ProcMeter.footprintBytes()),
                            f.renderMs, f.encodeMs, f.avgKB, f.quality, gapMax, gapLate,
                            link.isConnected ? "up" : "down", "\(store.state.page)", paused ? "  paused" : ""))
            gapMax = 0; gapLate = 0
        }
        onStatus?()
    }
}
