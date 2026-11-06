import Foundation

/// A byte pipe to the panel (a serial port in production, a fake in tests).
public protocol PortIO: AnyObject, Sendable {
    func write(_ d: Data) throws
    /// Returns whatever bytes arrive within `timeout`; empty `Data` on timeout.
    func read(timeout: TimeInterval) throws -> Data
    func close()
}

// MARK: - Clock

/// Time source for `Panel`: monotonic `now`, blocking `sleep`, and a cancellable repeating timer.
public struct PanelClock: Sendable {
    public let now: @Sendable () -> TimeInterval
    public let sleep: @Sendable (TimeInterval) -> Void
    /// Schedules `fire` every `interval` (first fire after one interval); returns a cancel closure.
    public let repeating: @Sendable (_ interval: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> @Sendable () -> Void

    public init(now: @escaping @Sendable () -> TimeInterval,
                sleep: @escaping @Sendable (TimeInterval) -> Void,
                repeating: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> @Sendable () -> Void) {
        self.now = now; self.sleep = sleep; self.repeating = repeating
    }

    public static let system = PanelClock(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { Thread.sleep(forTimeInterval: $0) },
        repeating: { interval, fire in
            let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "lj.panel.timer"))
            t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(20))
            t.setEventHandler(handler: fire)
            t.resume()
            return { t.cancel() }
        })
}

/// Deterministic clock for tests: time moves only via `advance(by:)` / `sleep`, and due timers fire
/// synchronously, in time order, on the advancing thread.
public final class ManualClock: @unchecked Sendable {
    private struct Timer { var next: TimeInterval; let interval: TimeInterval; let fire: @Sendable () -> Void }
    private let lock = NSLock()
    private var t: TimeInterval = 0
    private var timers: [Int: Timer] = [:]
    private var nextID = 0

    public init() {}

    public var now: TimeInterval { lock.withLock { t } }

    public func advance(by d: TimeInterval) {
        let target = lock.withLock { t + d }
        while true {
            let fire: (@Sendable () -> Void)? = lock.withLock {
                guard let (id, timer) = timers.filter({ $0.value.next <= target })
                    .min(by: { $0.value.next < $1.value.next }) else {
                    t = max(t, target)
                    return nil
                }
                t = max(t, timer.next)
                timers[id]?.next += timer.interval
                return timer.fire
            }
            guard let fire else { return }
            fire()
        }
    }

    public var panelClock: PanelClock {
        PanelClock(
            now: { self.now },
            sleep: { self.advance(by: $0) },
            repeating: { interval, fire in
                let id: Int = self.lock.withLock {
                    self.nextID += 1
                    self.timers[self.nextID] = Timer(next: self.t + interval, interval: interval, fire: fire)
                    return self.nextID
                }
                return { [weak self] in _ = self?.lock.withLock { self?.timers.removeValue(forKey: id) } }
            })
    }
}

// MARK: - Panel

/// Drives the LCD panel: handshake, keepalive, and a non-blocking "latest frame wins" writer.
///
/// All mutable state is guarded by `lock`; port writes happen on the private serial `writer` queue
/// (outside the lock), except the synchronous handshake in `connect()`. While live, the `reader` queue
/// reads and discards incoming bytes (the panel answers every 0x11 / 0x03), so input never piles up;
/// a read error tears the session down like a write error.
public final class Panel: @unchecked Sendable {
    private let open: @Sendable () throws -> PortIO
    private let keepaliveInterval: TimeInterval
    private let clock: PanelClock
    private let writer = DispatchQueue(label: "lj.panel.writer")
    private let reader = DispatchQueue(label: "lj.panel.reader")
    private let lock = NSLock()

    // Guarded by `lock`.
    private var port: PortIO?
    private var session = 0
    private var _info: PanelInfo?
    private var pendingControl: [Data] = []
    private var pendingFrame: Data?
    private var pendingBrightness: UInt8?
    /// Last image written this session; repainted after a brightness change blanks the panel.
    private var lastFrame: Data?
    private var draining = false
    private var cancelKeepalive: (@Sendable () -> Void)?
    private var _onDisconnect: (@Sendable (Error?) -> Void)?
    private var framesSent = 0
    private var bytesSent = 0

    public static let getInfoTimeout: TimeInterval = 3
    public static let clearSettle: TimeInterval = 0.3
    /// Poll interval of the input drain; bounds how long a stale drain outlives its session.
    public static let drainPoll: TimeInterval = 0.25

    public init(open: @escaping @Sendable () throws -> PortIO, keepalive: TimeInterval = 1.5, clock: PanelClock = .system) {
        self.open = open
        self.keepaliveInterval = keepalive
        self.clock = clock
    }

    deinit { disconnect() }

    public var info: PanelInfo? { lock.withLock { _info } }
    public var isConnected: Bool { lock.withLock { port != nil } }
    /// A frame is queued behind the one being written (the frame loop waits instead of replacing it).
    public var hasPendingFrame: Bool { lock.withLock { pendingFrame != nil } }
    public var stats: (framesSent: Int, bytesSent: Int) { lock.withLock { (framesSent, bytesSent) } }
    /// Fired once (on the writer queue) when a write error tears the session down. Not fired by `disconnect()`.
    public var onDisconnect: (@Sendable (Error?) -> Void)? {
        get { lock.withLock { _onDisconnect } }
        set { lock.withLock { _onDisconnect = newValue } }
    }

    /// Opens the port and runs the handshake: CLEAR, settle 0.3 s, getInfo (3 s deadline), live; then starts keepalive.
    /// Blocks the caller for the handshake. Any existing session is closed first.
    @discardableResult
    public func connect() throws -> PanelInfo {
        disconnect()
        let p = try open()
        let info: PanelInfo
        do {
            try p.write(clearSequence)
            clock.sleep(Self.clearSettle)
            try p.write(controlFrame(.getInfo))
            info = try readInfo(p)
            try p.write(controlFrame(.live))
        } catch {
            p.close()
            throw error
        }
        let cancel = clock.repeating(keepaliveInterval) { [weak self] in
            self?.enqueueControl(controlFrame(.live))
        }
        let s: Int = lock.withLock {
            port = p
            session += 1
            _info = info
            pendingControl = []
            pendingFrame = nil
            pendingBrightness = nil
            lastFrame = nil
            cancelKeepalive = cancel
            return session
        }
        startDrainingInput(p, session: s)
        return info
    }

    /// Ends the session (stops keepalive, drops queued output, closes the port). Does not fire `onDisconnect`.
    public func disconnect() {
        teardown()?.close()
    }

    /// Ends the session like `disconnect()`, but first writes `clearSequence` (on the writer queue, after any
    /// in-flight write, so it never splits a frame) so the panel drops the last image. Blocks until written.
    /// Returns true iff the CLEAR was written. Use on app quit.
    @discardableResult
    public func disconnect(sendingClear: Bool) -> Bool {
        guard let p = teardown() else { return false }
        guard sendingClear else { p.close(); return false }
        return writer.sync {
            defer { p.close() }
            do { try p.write(clearSequence); return true } catch { return false }
        }
    }

    /// Queues `jpeg` for display, replacing any frame not yet written. Never blocks; ignored when disconnected.
    public func pushFrame(_ jpeg: Data) {
        let kick: Bool = lock.withLock {
            guard port != nil else { return false }
            pendingFrame = jpeg
            return startDrainIfIdle()
        }
        if kick { writer.async { self.drain() } }
    }

    /// Sets the backlight (0–100, clamped). The firmware ignores 0x03 while live, so the writer leaves live
    /// mode (CLEAR + settle), sends 0x03, re-enters live and repaints the last frame. A newer call replaces
    /// a pending one.
    public func setBrightness(_ pct: Int) {
        let kick: Bool = lock.withLock {
            guard port != nil else { return false }
            pendingBrightness = UInt8(min(max(pct, 0), 100))
            return startDrainIfIdle()
        }
        if kick { writer.async { self.drain() } }
    }

    /// Test hook: returns once every write queued so far has been attempted.
    func waitForWriter() { writer.sync {} }

    // MARK: private

    private func enqueueControl(_ frame: Data) {
        let kick: Bool = lock.withLock {
            guard port != nil else { return false }
            pendingControl.append(frame)
            return startDrainIfIdle()
        }
        if kick { writer.async { self.drain() } }
    }

    /// Reads and discards input (keepalive / brightness acks) until the session ends. Never touches `writer`.
    private func startDrainingInput(_ p: PortIO, session s: Int) {
        reader.async { [weak self] in
            while true {
                guard let me = self, me.lock.withLock({ me.session == s && me.port === p }) else { return }
                do {
                    _ = try p.read(timeout: Self.drainPoll)
                } catch {
                    me.fail(session: s, error: error)
                    return
                }
            }
        }
    }

    /// Call with `lock` held.
    private func startDrainIfIdle() -> Bool {
        if draining { return false }
        draining = true
        return true
    }

    /// Writer loop (on `writer`): brightness, then control frames, then the latest image frame.
    /// Each `write` is one whole frame.
    private func drain() {
        while true {
            let bright: (port: PortIO, session: Int, level: UInt8)? = lock.withLock {
                guard let p = port, let b = pendingBrightness else { return nil }
                pendingBrightness = nil
                return (p, session, b)
            }
            if let bright {
                do {
                    try bright.port.write(clearSequence)
                    clock.sleep(Self.clearSettle)
                    try bright.port.write(controlFrame(.brightness, [bright.level]))
                    try bright.port.write(controlFrame(.live))
                    lock.withLock {
                        if bright.session == session, pendingFrame == nil { pendingFrame = lastFrame }
                    }
                } catch {
                    fail(session: bright.session, error: error)
                }
                continue
            }
            let job: (port: PortIO, session: Int, data: Data, isFrame: Bool, wrapped: Bool)? = lock.withLock {
                guard let p = port else { draining = false; return nil }
                if !pendingControl.isEmpty {
                    return (p, session, pendingControl.removeFirst(), false, false)
                }
                if let f = pendingFrame {
                    pendingFrame = nil
                    return (p, session, f, true, _info?.usesLengthHeader ?? true)
                }
                draining = false
                return nil
            }
            guard let job else { return }
            let bytes = job.isFrame ? imageFrame(job.data, wrapped: job.wrapped) : job.data
            do {
                try job.port.write(bytes)
                if job.isFrame {
                    lock.withLock {
                        if job.session == session { framesSent += 1; bytesSent += bytes.count; lastFrame = job.data }
                    }
                }
            } catch {
                fail(session: job.session, error: error)
            }
        }
    }

    private func fail(session s: Int, error: Error) {
        // Only the first error of the live session tears down and notifies.
        guard let p = teardown(ifSession: s) else { return }
        p.close()
        onDisconnect?(error)
    }

    /// Clears the session under the lock and returns the port to close (outside the lock).
    private func teardown(ifSession s: Int? = nil) -> PortIO? {
        let (p, cancel): (PortIO?, (@Sendable () -> Void)?) = lock.withLock {
            if let s, s != session { return (nil, nil) }
            let p = port, c = cancelKeepalive
            port = nil
            cancelKeepalive = nil
            pendingControl = []
            pendingFrame = nil
            return (p, c)
        }
        cancel?()
        return p
    }

    /// Accumulates reply chunks until a frame parses as `PanelInfo`; skips junk; throws `.timeout` at the deadline.
    private func readInfo(_ p: PortIO) throws -> PanelInfo {
        let deadline = clock.now() + Self.getInfoTimeout
        var buf = Data()
        while true {
            parse: while !buf.isEmpty {
                do {
                    switch try parseReply(buf) {
                    case .incomplete:
                        break parse
                    case let .reply(json, consumed):
                        buf = Data(buf.dropFirst(consumed))
                        if let info = parsePanelInfo(json) { return info }
                    }
                } catch {
                    // Resync: drop the bad leading byte and anything up to the next 0x55.
                    let rest = buf.dropFirst()
                    buf = Data(rest.drop(while: { $0 != 0x55 }))
                }
            }
            let remaining = deadline - clock.now()
            if remaining <= 0 { throw PanelError.timeout }
            buf += try p.read(timeout: min(remaining, 0.5))
        }
    }
}
