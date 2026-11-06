import AppKit
import LJApp
import LJCore
import ServiceManagement

/// The status-bar item and its menu: status line, Brightness, Theme, Pause streaming, Open Config,
/// Launch at Login, Quit. ("Open Privacy Settings" arrives with the notifications source, Task 6.)
@MainActor final class MenuBar: NSObject, NSMenuDelegate {
    static let brightnessSteps = [20, 40, 60, 80, 100]
    static let themes: [(Theme, String)] = [(.jinx, "Jinx 50/50"), (.jinxBlue, "Jinx 70% blue")]

    private unowned let app: AppDelegate
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let status = NSMenuItem(title: "Panel not found", action: nil, keyEquivalent: "")
    private let brightnessMenu = NSMenu()
    private let themeMenu = NSMenu()
    private let pause = NSMenuItem(title: "Pause streaming", action: #selector(togglePause), keyEquivalent: "")
    private let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    /// Last Launch-at-Login error, shown in the menu until the next successful toggle.
    private var loginError: String?

    init(app: AppDelegate) {
        self.app = app
        super.init()
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "LJ Display")
            b.image?.isTemplate = true
            b.toolTip = "LJ Display"
        }
        build()
        item.menu = menu
        menu.delegate = self
        app.runtime.onStatus = { [weak self] in self?.refreshStatus() }
        app.runtime.store.observe { [weak self] in self?.refreshTheme() }
        refreshAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            let f = item.button?.window?.frame
            Log.line("menu: launch at login status \(Self.describe(SMAppService.mainApp.status))")
            Log.line("menu: status item \(item.isVisible ? "visible" : "hidden") at \(f.map { "\($0)" } ?? "no window")")
        }
    }

    private func build() {
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        for pct in Self.brightnessSteps {
            let i = NSMenuItem(title: "\(pct)%", action: #selector(pickBrightness(_:)), keyEquivalent: "")
            i.target = self
            i.tag = pct
            brightnessMenu.addItem(i)
        }
        let b = NSMenuItem(title: "Brightness", action: nil, keyEquivalent: "")
        b.submenu = brightnessMenu
        menu.addItem(b)

        for (idx, (_, title)) in Self.themes.enumerated() {
            let i = NSMenuItem(title: title, action: #selector(pickTheme(_:)), keyEquivalent: "")
            i.target = self
            i.tag = idx
            themeMenu.addItem(i)
        }
        let t = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        t.submenu = themeMenu
        menu.addItem(t)

        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Config", action: #selector(openConfig), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit LJ Display", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: refresh

    func menuNeedsUpdate(_ menu: NSMenu) { refreshAll() }

    private func refreshAll() {
        refreshStatus()
        refreshTheme()
        for i in brightnessMenu.items { i.state = i.tag == app.runtime.brightness ? .on : .off }
        pause.state = app.runtime.paused ? .on : .off
        refreshLogin()
    }

    private func refreshStatus() {
        let s = app.runtime.statusLine
        if status.title != s { status.title = s }
    }

    private func refreshTheme() {
        let current = app.runtime.store.state.theme
        for i in themeMenu.items {
            let on: NSControl.StateValue = Self.themes[i.tag].0 == current ? .on : .off
            if i.state != on { i.state = on }
        }
    }

    private func refreshLogin() {
        let s = SMAppService.mainApp.status
        login.state = s == .enabled ? .on : .off
        login.title = switch (loginError, s) {
        case (let e?, _): "Launch at Login (failed: \(e))"
        case (nil, .requiresApproval): "Launch at Login (approve in System Settings › Login Items)"
        default: "Launch at Login"
        }
    }

    // MARK: actions

    @objc private func pickBrightness(_ sender: NSMenuItem) {
        app.runtime.brightness = sender.tag
        app.save { $0.brightness = sender.tag }
        Log.line("menu: brightness \(sender.tag)%")
        refreshAll()
    }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        let theme = Self.themes[sender.tag].0
        app.runtime.setTheme(theme)
        app.save { $0.theme = theme }
        Log.line("menu: theme \(theme.rawValue)")
    }

    @objc private func togglePause() {
        app.runtime.setPaused(!app.runtime.paused)
        refreshAll()
    }

    @objc private func openConfig() {
        let url = app.configURL
        if !FileManager.default.fileExists(atPath: url.path) { app.save { _ in } }
        // .json may have no default app; fall back to TextEdit.
        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// `SMAppService.mainApp` needs a signed app bundle; an ad-hoc-signed copy outside /Applications may be
    /// refused. Errors are logged and shown in the menu item instead of crashing.
    @objc private func toggleLogin() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
            } else {
                try svc.register()
            }
            loginError = nil
            Log.line("menu: launch at login → \(Self.describe(svc.status))")
        } catch {
            loginError = (error as NSError).localizedDescription
            Log.line("menu: launch at login failed: \(error) (status \(Self.describe(svc.status)))")
        }
        refreshLogin()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown(\(s.rawValue))"
        }
    }
}
