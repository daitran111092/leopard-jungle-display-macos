import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LJCore
import LJSources
import LJUI
import LJApp
import AppKit

// ljprobe — hardware probes.
//   ljprobe panel           find the panel, print its info, show a solid pink frame for 3 s
//   ljprobe panel --watch   print `appeared <path>` / `disappeared` as the panel is plugged/unplugged
//   ljprobe panel --soak N  push alternating pink/blue frames at ~30 fps for N seconds, then report
//   ljprobe audio           print the default audio output now and on every change
//   ljprobe audio --list    evaluate every output device (incl. isBuiltInSpeaker) and exit
//   ljprobe bt              print connected Bluetooth devices with battery (refresh 30 s, or --interval S)
//   ljprobe sys             print CPU / RAM / top 3 apps every second
//   ljprobe np              print the now-playing track (mediaremote-adapter stream) now and on every change
//   ljprobe np next|prev|toggle|seek S
//                           wait for the current track, send the command, print the resulting state and exit
//                           (0 when the change is observed within 8 s)
//   ljprobe keys            register the default global hot keys and print each Action as it fires (--seconds N)
//   ljprobe fixtures DIR    render every UI fixture to DIR/<name>.png (1920x462) and print render times
//   ljprobe stream          phase-1 demo: live dashboard on the panel (discovery + reconnect, audio/bt/sys,
//                           hot keys, 60 Hz frame loop); logs fps/CPU/RSS each second.
//                           --demo: next page every 3 s; --warn: force the speaker warning (60 fps load test);
//                           --no-sys: no SystemSource (truly static rail);
//                           --seconds N: exit after N s (--clear: send CLEAR before exiting)
//                           Wiring lives in LJApp (LJRuntime), shared with LJ Display.app.
//   audio/bt/sys run until Ctrl-C, or exit after `--seconds N`.

func usage() -> Never {
    print("usage: ljprobe panel [--watch | --soak SECONDS]")
    print("       ljprobe audio|bt|sys [--seconds N]   (audio also: --list; bt also: --interval S)")
    print("       ljprobe np [next | prev | toggle | seek SECONDS] [--seconds N] [--adapter DIR]")
    print("       ljprobe keys [--seconds N]")
    print("       ljprobe fixtures DIR")
    print("       ljprobe stream [--demo] [--warn] [--no-sys] [--seconds N [--clear]]")
    exit(2)
}

/// Solid Jinx pink (#ff2eaa), panel-native 462×1920 portrait.
func pinkJPEG() -> Data { solidJPEG(r: 1, g: 0x2e / 255.0, b: 0xaa / 255.0) }

func solidJPEG(r: CGFloat, g: CGFloat, b: CGFloat, width: Int = 462, height: Int = 1920) -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, ctx.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    CGImageDestinationFinalize(dst)
    return out as Data
}

func showPink(path: String) {
    let panel = Panel(open: { try SerialPort(path: path) })
    panel.onDisconnect = { err in print("panel lost: \(err.map { "\($0)" } ?? "nil")") }
    do {
        let info = try panel.connect()
        print(info)
        let jpeg = pinkJPEG()
        print("pushing pink 462x1920 JPEG (\(jpeg.count) bytes), holding 3 s")
        panel.pushFrame(jpeg)
        Thread.sleep(forTimeInterval: 3)
        let s = panel.stats
        print("framesSent \(s.framesSent), bytesSent \(s.bytesSent), connected \(panel.isConnected)")
        panel.disconnect()
        exit(s.framesSent == 1 ? 0 : 1)
    } catch {
        print("panel error: \(error)")
        exit(1)
    }
}

/// Pushes ~30 fps for `seconds`; exits 0 only if the session stayed up with no errors.
func soak(path: String, seconds: Double) {
    let panel = Panel(open: { try SerialPort(path: path) })
    let errors = ErrorLog()
    panel.onDisconnect = { err in errors.add("\(err.map { "\($0)" } ?? "nil")") }
    do {
        print(try panel.connect())
        let frames = [pinkJPEG(), solidJPEG(r: 0x4f / 255.0, g: 0xb6 / 255.0, b: 1)]
        let t0 = ProcessInfo.processInfo.systemUptime
        var n = 0
        while ProcessInfo.processInfo.systemUptime - t0 < seconds && panel.isConnected {
            panel.pushFrame(frames[n % 2])
            n += 1
            let next = t0 + Double(n) / 30
            let wait = next - ProcessInfo.processInfo.systemUptime
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
        Thread.sleep(forTimeInterval: 0.2)
        let el = ProcessInfo.processInfo.systemUptime - t0
        let s = panel.stats
        print(String(format: "soak %.1fs: pushed %d, framesSent %d (%.1f fps), bytesSent %d, connected %@, errors %d %@",
                     el, n, s.framesSent, Double(s.framesSent) / el, s.bytesSent,
                     panel.isConnected ? "true" : "false", errors.all.count, errors.all.description))
        let ok = panel.isConnected && errors.all.isEmpty
        panel.disconnect()
        exit(ok ? 0 : 1)
    } catch {
        print("panel error: \(error)")
        exit(1)
    }
}

final class ErrorLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var all: [String] { lock.withLock { items } }
}

let args = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> Double? {
    args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
}

func line(_ s: String) { fflush(stdout); Log.line(s) }

func pct(_ v: Int?) -> String { v.map { "\($0)%" } ?? "—" }

func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }

/// Runs a streaming probe until Ctrl-C or `--seconds N`.
func runStream(_ start: () -> Void) -> Never {
    start()
    if let s = option("--seconds") { DispatchQueue.main.asyncAfter(deadline: .now() + s) { exit(0) } }
    dispatchMain()
}

/// Renders every `Fixture` to `<dir>/<name>.png` and reports the warm render time per fixture.
@MainActor func renderFixtures(to dir: String) -> Never {
    let url = URL(fileURLWithPath: dir, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let renderer = ViewRenderer(size: Screen.size, initial: Fixture.railNormal.view)
    // ImageRenderer's CGImage is lazy: time render + rasterise into a bitmap, as the encoder does.
    let sink = CGContext(data: nil, width: 1920, height: 462, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let full = CGRect(x: 0, y: 0, width: 1920, height: 462)
    for f in Fixture.allCases {
        for i in 0..<5 { sink.draw(renderer.render(RootView(state: f.state, t: f.t + Double(i) / 60, now: Fixture.now)), in: full) }
        let n = 30
        let t0 = DispatchTime.now().uptimeNanoseconds
        for i in 0..<n { sink.draw(renderer.render(RootView(state: f.state, t: f.t + Double(i) / 60, now: Fixture.now)), in: full) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(n)
        let img = renderer.render(f.view)
        let out = url.appendingPathComponent("\(f.rawValue).png")
        guard let dst = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("cannot write \(out.path)"); exit(1)
        }
        CGImageDestinationAddImage(dst, img, nil)
        guard CGImageDestinationFinalize(dst) else { print("cannot write \(out.path)"); exit(1) }
        print(String(format: "%@  %dx%d  render %.2f ms", out.path, img.width, img.height, ms))
    }
    exit(0)
}

let defaultKeys = AppConfig.defaultShortcuts

@MainActor func runKeys() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let keys = HotKeys(bindings: defaultKeys) { a in line("key: \(a.rawValue)") }
    let failed = keys.register()
    line("keys: registered \(keys.bindingCount - failed.count)/\(keys.bindingCount), failed \(failed)")
    if let s = option("--seconds") { DispatchQueue.main.asyncAfter(deadline: .now() + s) { keys.unregister(); exit(failed.isEmpty ? 0 : 1) } }
    app.run()
    exit(0)
}

/// Phase-1 demo on top of the shared app wiring (`LJRuntime`, same code as LJ Display.app).
@MainActor func runStreamDemo() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    var opts = LJRuntime.Options(config: AppConfig())
    opts.forceWarn = args.contains("--warn")
    opts.systemStats = !args.contains("--no-sys")
    let rt = LJRuntime(options: opts)
    rt.start()

    var demoTimer: DispatchSourceTimer?
    if args.contains("--demo") {
        line("stream: demo on (next page every 3 s)")
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 3, repeating: 3)
        t.setEventHandler { MainActor.assumeIsolated { rt.perform(.nextPage) } }
        t.resume()
        demoTimer = t
    }
    if let s = option("--seconds") {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) {
            demoTimer?.cancel()
            rt.stop(clearPanel: args.contains("--clear"))
            exit(0)
        }
    }
    withExtendedLifetime(rt) { app.run() }
    exit(0)
}

func describe(_ np: NowPlaying?) -> String {
    guard let np else { return "nothing playing" }
    let art = np.artwork.map { "\($0.count) B" } ?? "none"
    return "\(np.playing ? "▶" : "❚❚") \"\(np.title)\" — \(np.artist) · \(np.album) [\(np.appName) \(np.bundleID)] "
        + "\(fmtTime(elapsedNow(np, at: Date())))/\(fmtTime(np.duration)) artwork \(art)"
}

final class NPBox: @unchecked Sendable {
    let lock = NSLock()
    var first: NowPlaying??
    var sent = false
}

func runNowPlaying() -> Never {
    let explicit = args.firstIndex(of: "--adapter").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
    guard let dir = explicit ?? NowPlayingSource.locateAdapter() else {
        print("np: adapter not found (run scripts/build-adapter.sh)"); exit(1)
    }
    line("np: adapter \(dir.path)")
    let cmd: MediaCommand?
    switch args.dropFirst().first {
    case nil, "--seconds"?, "--adapter"?: cmd = nil
    case "next"?: cmd = .next
    case "prev"?: cmd = .prev
    case "toggle"?: cmd = .toggle
    case "seek"?:
        guard args.count >= 3, let s = Double(args[2]) else { usage() }
        cmd = .seek(s)
    default: usage()
    }
    let box = NPBox()
    nonisolated(unsafe) var src: NowPlayingSource!
    src = NowPlayingSource(adapterDir: dir, log: { line($0) }) { np in
        line("np: \(describe(np))")
        guard let cmd else { return }
        box.lock.lock(); defer { box.lock.unlock() }
        guard let first = box.first else {
            // The adapter always opens with an empty payload; wait for the real state.
            guard np != nil else { return }
            box.first = .some(np)
            box.sent = true
            line("np: sending \(cmd)")
            src.send(cmd)
            return
        }
        guard box.sent, let a = first, let b = np else { return }
        let done: Bool
        switch cmd {
        case .next, .prev: done = a.title != b.title || abs(b.elapsed) < 1 && abs(a.elapsed) >= 1
        case .toggle: done = a.playing != b.playing
        case .seek(let s): done = abs(b.elapsed - s) < 2
        }
        if done { line("np: \(cmd) observed"); src.stop(); exit(0) }
    }
    src.start()
    // Ctrl-C / kill: stop the adapter stream before exiting (the watchdog would also catch a missed stop).
    signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
    let sigSources = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
        let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        s.setEventHandler { line("np: signal \(sig), stopping"); src.stop(); exit(130) }
        s.resume()
        return s
    }
    let limit = option("--seconds") ?? (cmd == nil ? nil : 8)
    if let limit {
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
            src.stop()
            if cmd != nil { line("np: \(cmd!) not observed within \(Int(limit)) s"); exit(1) }
            exit(0)
        }
    }
    withExtendedLifetime(sigSources) { dispatchMain() }
}

switch args.first {
case "np":
    runNowPlaying()
case "stream":
    MainActor.assumeIsolated { runStreamDemo() }
case "keys":
    MainActor.assumeIsolated { runKeys() }
case "fixtures":
    guard args.count >= 2 else { usage() }
    MainActor.assumeIsolated { renderFixtures(to: args[1]) }
case "audio" where args.contains("--list"):
    for (uid, o) in AudioSource.allOutputs() {
        print("\"\(o.name)\" uid=\(uid) transport=\(o.transport.rawValue) rate=\(o.sampleRate.map { String(format: "%.0f", $0) } ?? "n/a") bits=\(o.bitDepth.map(String.init) ?? "n/a") isBuiltInSpeaker=\(o.isBuiltInSpeaker)")
    }
    exit(0)
case "audio":
    let src = AudioSource { out in
        guard let o = out else { return line("audio: no default output device") }
        let vol = o.volume.map { String(format: "%.0f%%", $0 * 100) } ?? "n/a"
        let rate = o.sampleRate.map { String(format: "%.0f", $0) } ?? "n/a"
        let bits = o.bitDepth.map(String.init) ?? "n/a"
        let fmt = o.sampleRate.map { "\"\(fmtAudioFormat(sampleRate: $0, bitDepth: o.bitDepth))\" \(rateClass(sampleRate: $0))" } ?? "n/a"
        line("audio: \"\(o.name)\" transport=\(o.transport.rawValue) volume=\(vol) rate=\(rate) bits=\(bits) format=\(fmt) isBuiltInSpeaker=\(o.isBuiltInSpeaker)\(o.isBuiltInSpeaker ? "  <<< OOPS! LOUD!" : "")")
    }
    runStream { src.start() }
case "bt":
    let src = BluetoothSource(interval: option("--interval") ?? 30) { devs in
        line("bt: \(devs.count) connected")
        for d in devs {
            var parts = ["  \(d.name) [\(d.kind.rawValue)]"]
            if d.battery != nil || (d.batteryL == nil && d.batteryR == nil && d.batteryCase == nil) { parts.append("battery \(pct(d.battery))") }
            if d.batteryL != nil || d.batteryR != nil || d.batteryCase != nil {
                parts.append("L \(pct(d.batteryL)) R \(pct(d.batteryR)) case \(pct(d.batteryCase))")
            }
            print(parts.joined(separator: " "))
        }
        fflush(stdout)
    }
    runStream { src.start() }
case "sys":
    let src = SystemSource { s in
        let apps = s.topApps.map { String(format: "%@ %.1f%% %@", $0.name, $0.cpu, mb($0.rssBytes)) }.joined(separator: " | ")
        line(String(format: "sys: cpu %5.1f%%  ram %@ / %@  top: %@", s.cpu, gb(s.memUsedBytes), gb(s.memTotalBytes), apps))
    }
    runStream { src.start() }
case "panel":
    break
default:
    usage()
}

let watch = args.dropFirst().contains("--watch")
let soakSeconds: Double? = args.firstIndex(of: "--soak").map { i in
    i + 1 < args.count ? (Double(args[i + 1]) ?? 60) : 60
}

var handled = false
let discovery = PanelDiscovery(
    onAppear: { path in
        print("appeared \(path)")
        fflush(stdout)
        if watch || handled { return }
        handled = true
        DispatchQueue.global().async {
            if let soakSeconds { soak(path: path, seconds: soakSeconds) } else { showPink(path: path) }
        }
    },
    onDisappear: {
        print("disappeared")
        fflush(stdout)
    })
discovery.start()
if !watch {
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
        if !handled { print("no panel (idVendor 0x33c3) found"); exit(1) }
    }
}
dispatchMain()
