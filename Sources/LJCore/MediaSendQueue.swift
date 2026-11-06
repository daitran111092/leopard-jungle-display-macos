import Foundation

/// Coalesces and serializes media commands for `NowPlayingSource.send` (each send spawns a perl process).
///
/// - Seeks: the first seek opens a `window` (250 ms); seeks inside it only replace the target; when it closes the
///   last target is queued at the back. A seek still waiting in the queue is dropped for the newer one.
/// - toggle / next / prev are queued at once. next / prev drop any pending seek (it was aimed at the old track).
/// - At most one send is in flight: the next queued command goes out when `send`'s `done` is called, or after
///   `sendTimeout` (3 s) if it never is (a hung send must not block the queue). `done` must be called on the main
///   actor; a second or late `done` is ignored.
/// - `cancelAll()` drops everything pending (stop / shutdown); the queue stays usable.
@MainActor public final class MediaSendQueue {
    public typealias Schedule = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
    public typealias Send = @MainActor (MediaCommand, @escaping @MainActor @Sendable () -> Void) -> Void

    private let window: TimeInterval
    private let sendTimeout: TimeInterval
    private let schedule: Schedule
    private let sendCommand: Send
    private var queued: [MediaCommand] = []
    private var windowTarget: Double?
    private var windowID = 0
    private var inFlight = 0 // id of the send in flight; 0 = idle
    private var lastSendID = 0

    public init(window: TimeInterval = 0.25, sendTimeout: TimeInterval = 3,
                schedule: @escaping Schedule, send: @escaping Send) {
        self.window = window
        self.sendTimeout = sendTimeout
        self.schedule = schedule
        self.sendCommand = send
    }

    /// Main-queue timers + the given send.
    public convenience init(window: TimeInterval = 0.25, sendTimeout: TimeInterval = 3, send: @escaping Send) {
        self.init(window: window, sendTimeout: sendTimeout, schedule: { delay, fire in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { fire() } }
        }, send: send)
    }

    public func enqueue(_ c: MediaCommand) {
        switch c {
        case .seek(let x):
            if windowTarget == nil {
                windowID += 1
                let id = windowID
                schedule(window) { [weak self] in self?.closeWindow(id) }
            }
            windowTarget = x
        case .next, .prev:
            windowTarget = nil
            windowID += 1 // the open window's timer becomes a no-op
            queued.removeAll { if case .seek = $0 { return true } else { return false } }
            queued.append(c)
        case .toggle:
            queued.append(c)
        }
        pump()
    }

    private func closeWindow(_ id: Int) {
        guard id == windowID, let x = windowTarget else { return }
        windowTarget = nil
        queued.removeAll { if case .seek = $0 { return true } else { return false } }
        queued.append(.seek(x))
        pump()
    }

    /// Drops queued commands and the open seek window; a send in flight is forgotten (its `done` is ignored).
    public func cancelAll() {
        queued.removeAll()
        windowTarget = nil
        windowID += 1
        inFlight = 0
    }

    /// Ends the send `id` (completion or timeout) and sends the next command.
    private func finish(_ id: Int) {
        guard inFlight == id else { return }
        inFlight = 0
        pump()
    }

    private func pump() {
        guard inFlight == 0, !queued.isEmpty else { return }
        let c = queued.removeFirst()
        lastSendID += 1
        let id = lastSendID
        inFlight = id
        schedule(sendTimeout) { [weak self] in self?.finish(id) }
        sendCommand(c) { [weak self] in self?.finish(id) }
    }
}
