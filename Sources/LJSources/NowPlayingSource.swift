import Foundation
import AppKit
import LJCore

/// Now playing + media control through the vendored `ungive/mediaremote-adapter`.
///
/// macOS 15.4+ refuses MediaRemote to unentitled processes; `/usr/bin/perl` is entitled, so the adapter's Perl
/// script loads `MediaRemoteAdapter.framework` and talks to MediaRemote on our behalf. `adapterDir` must contain
///   bin/mediaremote-adapter.pl
///   MediaRemoteAdapter.framework       (built by scripts/build-adapter.sh)
/// Use `NowPlayingSource.locateAdapter()` to find it in the .app (Contents/Resources/mediaremote-adapter) or the repo.
///
/// - `start()` runs `/usr/bin/perl <dir>/bin/mediaremote-adapter.pl <framework> stream --micros` and parses its
///   line-delimited JSON with `applyAdapterEvent`. The stream runs under a small `/usr/bin/perl -e` watchdog
///   (`watchdogScript`) that TERMs it when this process dies, so a crash / kill -9 / exit() leaves no orphan.
///   If the stream exits it is restarted after 1 s, backing off ×2 up to 30 s while it keeps failing; the delay
///   resets to 1 s once an event is received. `stop()` ends it for good.
/// - `onChange` runs on a private serial queue whenever the state differs from the last one emitted (nil = nothing
///   playing). `appName` is filled from the bundle id via NSWorkspace (cached).
/// - `send(_:done:)` runs the script's one-shot `send` / `seek` commands; the stream reports the effect.
public final class NowPlayingSource: @unchecked Sendable {
    public static let frameworkName = "MediaRemoteAdapter.framework"
    public static let scriptPath = "bin/mediaremote-adapter.pl"

    private let adapterDir: URL
    private let onChange: @Sendable (NowPlaying?) -> Void
    private let log: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "vn.kahn.ljdisplay.nowplaying")
    private let queueKey = DispatchSpecificKey<Bool>()

    // Confined to `queue`.
    private var running = false
    private var process: Process?
    private var generation = 0
    private var buffer = Data()
    private var state: NowPlaying?
    private var emitted: NowPlaying??
    private var appNames: [String: String] = [:]
    private var nilPending = false
    private var restartDelay = NowPlayingSource.minRestartDelay
    static let nilDelay: TimeInterval = 0.5
    static let minRestartDelay: TimeInterval = 1
    static let maxRestartDelay: TimeInterval = 30

    /// Next restart delay after `delay` failed: doubles, capped at `maxRestartDelay`.
    static func nextRestartDelay(after delay: TimeInterval) -> TimeInterval { min(maxRestartDelay, delay * 2) }

    /// Runs as `/usr/bin/perl -e watchdogScript -- <script> <framework> stream …`: forks + execs `/usr/bin/perl`
    /// with the remaining args (stdout is inherited; the exec'd perl keeps MediaRemote access), then every 0.25 s
    /// checks the child and its own parent. Parent gone (re-parented) or TERM/INT/HUP → TERM the child (KILL
    /// after 2 s), exit. Child exited → exit with its status, so the source sees the termination and restarts.
    static let watchdogScript = #"""
    use strict; use POSIX ();
    my $pp = getppid();
    my $pid = fork(); defined $pid or POSIX::_exit(126);
    if ($pid == 0) { exec('/usr/bin/perl', @ARGV); POSIX::_exit(127); }
    sub reap { kill('TERM', $pid); for (1..20) { return if waitpid($pid, POSIX::WNOHANG()) == $pid; select(undef, undef, undef, 0.1) } kill('KILL', $pid); waitpid($pid, 0) }
    $SIG{$_} = sub { reap(); POSIX::_exit(0) } for qw(TERM INT HUP);
    $SIG{PIPE} = 'IGNORE';
    while (1) {
        if (waitpid($pid, POSIX::WNOHANG()) == $pid) { POSIX::_exit($? & 127 ? 1 : $? >> 8) }
        if (getppid() != $pp) { reap(); POSIX::_exit(0) }
        select(undef, undef, undef, 0.25);
    }
    """#

    /// `log` receives adapter lifecycle lines (exit/restart, launch and send failures); default: dropped.
    public init(adapterDir: URL, log: @escaping @Sendable (String) -> Void = { _ in },
                onChange: @escaping @Sendable (NowPlaying?) -> Void) {
        self.adapterDir = adapterDir
        self.log = log
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit { process?.terminate() }

    /// The adapter directory: the app bundle's `Resources/mediaremote-adapter` first, then the repo's
    /// `vendor/mediaremote-adapter` (for `swift run ljprobe`). nil when neither has the script and a built framework.
    /// `filePath` is a test seam; by default this source file's own path is used.
    public static func locateAdapter(bundle: Bundle = .main, filePath: String? = nil) -> URL? {
        var candidates: [URL] = []
        if let res = bundle.resourceURL { candidates.append(res.appendingPathComponent("mediaremote-adapter")) }
        // <repo>/Sources/LJSources/NowPlayingSource.swift → <repo>/vendor/mediaremote-adapter
        let repo = URL(fileURLWithPath: filePath ?? sourceFilePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        candidates.append(repo.appendingPathComponent("vendor/mediaremote-adapter"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("vendor/mediaremote-adapter"))
        return candidates.first(where: isAdapterDir)
    }

    static func isAdapterDir(_ dir: URL) -> Bool {
        let fm = FileManager.default
        return fm.isReadableFile(atPath: dir.appendingPathComponent(scriptPath).path)
            && fm.fileExists(atPath: dir.appendingPathComponent("\(frameworkName)/MediaRemoteAdapter").path)
    }

    public func start() {
        queue.async { [self] in
            guard !running else { return }
            running = true
            launch()
        }
    }

    /// Stops the stream (no restart). Safe to call from `onChange`.
    public func stop() {
        onQueue {
            guard running else { return }
            running = false
            generation += 1
            let p = process
            process = nil
            (p?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p?.isRunning == true { p?.terminate() }
            buffer.removeAll()
            state = nil
            emitted = nil
            nilPending = false
            restartDelay = Self.minRestartDelay
        }
    }

    /// Runs the one-shot command. `done` (if any) is called on an arbitrary thread when the command's process has
    /// exited, or at once when it could not be started. A process still running after `timeout` is terminated.
    public func send(_ c: MediaCommand, timeout: TimeInterval = 3, done: (@Sendable () -> Void)? = nil) {
        let args: [String]
        switch c {
        case .toggle: args = ["send", "2"]   // kMRTogglePlayPause
        case .next: args = ["send", "4"]     // kMRNextTrack
        case .prev: args = ["send", "5"]     // kMRPreviousTrack
        case .seek(let s): args = ["seek", String(Int64((max(0, s.isFinite ? s : 0) * 1e6).rounded()))]  // µs
        }
        let p = makeProcess(args)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if let done { p.terminationHandler = { _ in done() } }
        do { try p.run() } catch { log("nowplaying: send \(args) failed: \(error)"); done?(); return }
        let log = self.log
        queue.asyncAfter(deadline: .now() + timeout) {
            guard p.isRunning else { return }
            log("nowplaying: send \(args) still running after \(timeout) s; terminating")
            p.terminate()
        }
    }

    /// Runs `body` synchronously on `queue`, also when already on it.
    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { body() } else { queue.sync(execute: body) }
    }

    // MARK: - Stream (on `queue`)

    private func adapterArgs(_ args: [String]) -> [String] {
        [adapterDir.appendingPathComponent(Self.scriptPath).path,
         adapterDir.appendingPathComponent(Self.frameworkName).path] + args
    }

    /// One-shot commands (`send` / `seek`) exit on their own; no watchdog.
    private func makeProcess(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = adapterArgs(args)
        return p
    }

    private func launch() {
        guard running else { return }
        generation += 1
        let gen = generation
        buffer.removeAll()
        nilPending = false  // a pending nil of the previous stream was dropped with its generation
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["-e", Self.watchdogScript, "--"] + adapterArgs(["stream", "--micros"])
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            if chunk.isEmpty { h.readabilityHandler = nil; return }  // EOF
            guard let self else { return }
            self.queue.async { if gen == self.generation { self.consume(chunk) } }
        }
        p.terminationHandler = { [weak self] proc in
            out.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.queue.async {
                guard gen == self.generation, self.running else { return }
                self.process = nil
                self.scheduleRestart(gen, "adapter exited (\(proc.terminationStatus))")
            }
        }
        do {
            try p.run()
            process = p
        } catch {
            scheduleRestart(gen, "cannot start adapter: \(error)")
        }
    }

    private func scheduleRestart(_ gen: Int, _ why: String) {
        let delay = restartDelay
        restartDelay = Self.nextRestartDelay(after: delay)
        log("nowplaying: \(why); restarting in \(Int(delay)) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation else { return }
            self.launch()
        }
    }

    private func consume(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard !line.isEmpty,
                  let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            restartDelay = Self.minRestartDelay  // the adapter works: next failure restarts after 1 s again
            state = applyAdapterEvent(json, to: state, now: Date())
            if var s = state, s.appName.isEmpty {
                s.appName = appName(for: s.bundleID)
                state = s
            }
            emit()
        }
    }

    /// Emits `state` when it differs from the last emission. nil is held back for `nilDelay`: the adapter opens
    /// every (re)started stream with an empty payload before the real state, which would flash "nothing playing".
    private func emit() {
        if state == nil {
            guard emitted != .some(nil), !nilPending else { return }
            nilPending = true
            let gen = generation
            queue.asyncAfter(deadline: .now() + Self.nilDelay) { [weak self] in
                guard let self, gen == self.generation, self.nilPending else { return }
                self.nilPending = false
                if self.state == nil, self.emitted != .some(nil) { self.emitted = .some(nil); self.onChange(nil) }
            }
            return
        }
        nilPending = false
        if emitted != .some(state) {
            emitted = .some(state)
            onChange(state)
        }
    }

    private func appName(for bundleID: String) -> String {
        if let n = appNames[bundleID] { return n }
        var name = bundleID
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let info = Bundle(url: url)?.localizedInfoDictionary ?? [:]
            let plist = Bundle(url: url)?.infoDictionary ?? [:]
            name = (info["CFBundleDisplayName"] ?? plist["CFBundleDisplayName"] ?? info["CFBundleName"]
                    ?? plist["CFBundleName"]) as? String
                ?? url.deletingPathExtension().lastPathComponent
        }
        appNames[bundleID] = name
        return name
    }
}

private let sourceFilePath = #filePath
