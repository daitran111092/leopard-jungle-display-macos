import AppKit
import Foundation
import LJApp
import LJCore

// LJ Display: menu-bar app (no Dock icon) streaming the dashboard to the HONGTAI 9.16" USB panel.
// Log: ~/Library/Logs/LJ Display/LJ Display.log (previous run: .log.1). Config: AppConfig.defaultURL.

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let configURL = AppConfig.defaultURL
    var config: AppConfig
    let runtime: LJRuntime
    var menu: MenuBar?
    private var signalSources: [DispatchSourceSignal] = []

    override init() {
        config = loadConfig(at: configURL, defaults: AppConfig())
        var opts = LJRuntime.Options(config: config)
        opts.statsLogInterval = Int(ProcessInfo.processInfo.environment["LJ_STATS_INTERVAL"] ?? "") ?? 10
        runtime = LJRuntime(options: opts)
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        Log.line("LJ Display \(v) starting; config \(configURL.path); theme \(config.theme.rawValue), brightness \(config.clampedBrightness), maxFps \(config.clampedMaxFps)")
        runtime.onEffects = { Effects.run($0) }
        if ProcessInfo.processInfo.environment["LJ_DEBUG_ACTIONS"] == "1" { runtime.enableDebugActions() }
        menu = MenuBar(app: self)
        runtime.start()
        // `kill <pid>` (SIGTERM) and Ctrl-C quit like the menu's Quit, so the panel is cleared.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { Log.line("signal \(sig): quitting"); NSApp.terminate(nil) }
            s.resume()
            signalSources.append(s)
        }
    }

    func applicationWillTerminate(_ note: Notification) {
        runtime.stop(clearPanel: true)
        Log.line("LJ Display quit")
    }

    /// Persists a menu change (brightness / theme) to the config file.
    func save(_ change: (inout AppConfig) -> Void) {
        change(&config)
        do { try saveConfig(config, at: configURL) } catch { Log.line("config: save failed: \(error)") }
    }
}

let logURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Logs/LJ Display/LJ Display.log")
Log.openFile(logURL)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
