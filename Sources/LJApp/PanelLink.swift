import Foundation
import LJCore
import LJSources

/// Owns the panel session: one connect at a time (off the main thread), reconnect after a write
/// error or replug. All state is main-thread; Panel callbacks hop to main.
@MainActor public final class PanelLink {
    /// What the UI is laid out for; anything else gets a warning in the log.
    public nonisolated static let expected = (width: 1920, height: 462, angle: 270)

    public private(set) var panel: Panel?
    private var path: String?
    private var connecting = false
    private var retryPending = false
    /// Identifies the in-flight connect; a watchdog-abandoned attempt that finishes later is discarded.
    private var attempt = 0
    private let open: @Sendable (String) throws -> PortIO
    private let connectTimeout: TimeInterval
    /// After every successful (re)connect.
    public var onConnected: ((PanelInfo) -> Void)?
    /// After the session ends for any reason other than `close` (lost, unplugged, suspended).
    public var onDisconnected: (() -> Void)?

    /// `connectTimeout`: an attempt that hasn't finished by then (a hung open/handshake/close on a misbehaving
    /// panel or cable) is abandoned and retried, so the link never stays stuck in "connecting".
    /// One IOUSBHost bulk transfer per frame (what the vendor app does on Windows); the macOS CDC tty splits a frame
    /// into ~1 KB transfers, which this panel occasionally corrupts (a tinted band at the end of the image).
    /// Falls back to the tty when the USB interface can't be opened.
    public static let defaultOpen: @Sendable (String) throws -> PortIO = { path in
        do {
            return try USBBulkPort()
        } catch {
            Log.line("panel: USB direct unavailable (\(error)); using \(path)")
            return try SerialPort(path: path)
        }
    }

    public init(open: @escaping @Sendable (String) throws -> PortIO = PanelLink.defaultOpen,
                connectTimeout: TimeInterval = 8) {
        self.open = open
        self.connectTimeout = connectTimeout
    }

    public var isConnected: Bool { panel?.isConnected ?? false }
    /// A frame is already queued for the panel: render the next one only when it clears (no dropped frames).
    public var isBusy: Bool { panel?.hasPendingFrame ?? false }
    /// A panel device is present (connected or being connected).
    public var isPresent: Bool { path != nil }

    public func appeared(_ p: String) {
        path = p
        connectIfNeeded()
    }

    public func disappeared() {
        path = nil
        if let p = panel { p.disconnect(); panel = nil; Log.line("panel: unplugged"); onDisconnected?() }
    }

    /// Ends the session before system sleep; the next `appeared` (rediscovery on wake) reconnects.
    public func suspend() {
        path = nil
        if let p = panel { p.disconnect(); panel = nil; Log.line("panel: closed for sleep"); onDisconnected?() }
    }

    /// Ends the session at exit (no reconnect). With `sendingClear`, writes the CLEAR sequence first so the
    /// panel drops the last frame. Returns true iff the CLEAR was written.
    @discardableResult
    public func close(sendingClear: Bool = false) -> Bool {
        path = nil
        defer { panel = nil }
        guard let p = panel else { return false }
        return p.disconnect(sendingClear: sendingClear)
    }

    public func setBrightness(_ pct: Int) { panel?.setBrightness(pct) }

    public func push(_ jpeg: Data) { panel?.pushFrame(jpeg) }

    /// Warning text when the panel's reported geometry is not the one the UI renders for, else nil.
    public nonisolated static func geometryWarning(_ info: PanelInfo) -> String? {
        guard info.width != expected.width || info.height != expected.height || info.angle != expected.angle else { return nil }
        return "panel: WARNING geometry \(info.width)x\(info.height) angle \(info.angle), expected "
            + "\(expected.width)x\(expected.height) angle \(expected.angle); frames may be distorted"
    }

    private func connectIfNeeded() {
        guard let path, !connecting, !isConnected else { return }
        connecting = true
        attempt += 1
        let id = attempt
        let open = self.open
        let p = Panel(open: { try open(path) })
        p.onDisconnect = { [weak self, weak p] err in // weak p: the panel owns this closure
            DispatchQueue.main.async { MainActor.assumeIsolated { if let p { self?.lost(p, err) } } }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Result { try p.connect() }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.finished(p, path, r, attempt: id) } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + connectTimeout) { [weak self] in
            guard let self, connecting, attempt == id else { return }
            Log.line(String(format: "panel: connect hung for %.1f s, abandoning and retrying", connectTimeout))
            attempt += 1                  // the hung attempt is now stale
            connecting = false
            retry(after: 1)
        }
    }

    private func finished(_ p: Panel, _ attempted: String, _ r: Result<PanelInfo, Error>, attempt id: Int) {
        guard id == attempt else {        // abandoned by the watchdog; a newer attempt owns the link
            if case .success = r { p.disconnect() }
            return
        }
        connecting = false
        switch r {
        case .success where path == attempted && !p.isConnected:
            // The session died (e.g. input drain error) before this hop; its `lost` was ignored.
            Log.line("panel: session ended during connect")
            retry(after: 1)
        case .success(let info) where path == attempted:
            panel = p
            Log.line("panel: connected \(attempted) \(info)")
            if let w = Self.geometryWarning(info) { Log.line(w) }
            onConnected?(info)
        case .success:
            p.disconnect() // unplugged (or moved) mid-handshake
            connectIfNeeded()
        case .failure(let e):
            Log.line("panel: connect failed: \(e)")
            retry(after: 1)
        }
    }

    private func lost(_ p: Panel, _ err: Error?) {
        guard panel === p else { return }
        panel = nil
        Log.line("panel: lost (\(err.map { "\($0)" } ?? "nil"))")
        onDisconnected?()
        retry(after: 0.5)
    }

    private func retry(after s: TimeInterval) {
        guard !retryPending, path != nil else { return }
        retryPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { [weak self] in
            guard let self else { return }
            retryPending = false
            connectIfNeeded()
        }
    }
}
