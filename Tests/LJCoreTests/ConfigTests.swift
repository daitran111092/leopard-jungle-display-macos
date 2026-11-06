import Testing
import Foundation
@testable import LJCore

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("ljcfg-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func read(_ url: URL) -> [String: Any]? {
    (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

@Test func missingConfigWritesDefaults() throws {
    let dir = tempDir().appendingPathComponent("LJ Display", isDirectory: true) // parent dir does not exist yet
    let url = dir.appendingPathComponent("config.json")
    let cfg = loadConfig(at: url, defaults: AppConfig())
    #expect(cfg == AppConfig())
    #expect(FileManager.default.fileExists(atPath: url.path))
    let back = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
    #expect(back == AppConfig())
}

@Test func invalidJSONKeepsBackup() throws {
    let dir = tempDir()
    let url = dir.appendingPathComponent("config.json")
    let junk = Data("{ \"brightness\": 40, oops".utf8)
    try junk.write(to: url)
    let cfg = loadConfig(at: url, defaults: AppConfig())
    #expect(cfg == AppConfig())
    let bak = dir.appendingPathComponent("config.json.bak")
    #expect(try Data(contentsOf: bak) == junk)
}

@Test func wrongTypeIsTreatedAsInvalid() throws {
    let dir = tempDir()
    let url = dir.appendingPathComponent("config.json")
    try Data(#"{"brightness":"bright"}"#.utf8).write(to: url)
    #expect(loadConfig(at: url, defaults: AppConfig()) == AppConfig())
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json.bak").path))
}

@Test func partialConfigMerges() throws {
    let dir = tempDir()
    let url = dir.appendingPathComponent("config.json")
    try Data(#"{"brightness":40,"theme":"jinx-blue","shortcuts":{"nextPage":["F18"]}}"#.utf8).write(to: url)
    let cfg = loadConfig(at: url, defaults: AppConfig())
    var want = AppConfig()
    want.brightness = 40
    want.theme = .jinxBlue
    want.shortcuts[.nextPage] = ["F18"] // an array replaces that action's bindings; other actions keep their defaults
    #expect(cfg == want)
    #expect(cfg.shortcuts[.prevPage] == ["Shift+F19", "Ctrl+Option+Up"])
    #expect(cfg.maxFps == 60)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json.bak").path))
}

@Test func defaultsMatchSpec() {
    let c = AppConfig()
    #expect(c.theme == .jinx)
    #expect(c.brightness == 80)
    #expect(c.maxFps == 60)
    #expect(c.accounts.isEmpty)
    #expect(c.shortcuts == [
        .turnLeft: ["F13", "Ctrl+Option+Left"], .turnRight: ["F14", "Ctrl+Option+Right"],
        .press: ["F15", "Ctrl+Option+Return"], .k1: ["F16", "Ctrl+Option+["], .k2: ["F17", "Ctrl+Option+]"],
        .k3: ["F18"], .k3Hold: ["Shift+F18"],
        .nextPage: ["F19", "Ctrl+Option+Down"], .prevPage: ["Shift+F19", "Ctrl+Option+Up"],
    ])
}

@Test func defaultsIncludeFallbacks() {
    let sc = AppConfig().shortcuts
    let want: [Action: String] = [
        .turnLeft: "Ctrl+Option+Left", .turnRight: "Ctrl+Option+Right", .press: "Ctrl+Option+Return",
        .k1: "Ctrl+Option+[", .k2: "Ctrl+Option+]", .nextPage: "Ctrl+Option+Down", .prevPage: "Ctrl+Option+Up",
    ]
    #expect(AppConfig.fallbackShortcuts == want)
    for (a, combo) in want { #expect(sc[a]?.contains(combo) == true, "\(a)") }
    // F-keys stay first: the knob board's bindings are the primary ones.
    #expect(sc[.turnLeft]?.first == "F13")
    #expect(sc[.prevPage]?.first == "Shift+F19")
}

@Test func legacyStringShortcutsMigrate() throws {
    let dir = tempDir()
    let url = dir.appendingPathComponent("config.json")
    let legacy = #"{"brightness":30,"shortcuts":{"turnLeft":"Shift+F13","k3":"F16","nextPage":["F19"]}}"#
    try Data(legacy.utf8).write(to: url)
    let cfg = loadConfig(at: url, defaults: AppConfig())
    #expect(cfg.brightness == 30)
    // A legacy string → [value] plus that action's Ctrl+Option fallback (the old format could not list it).
    #expect(cfg.shortcuts[.turnLeft] == ["Shift+F13", "Ctrl+Option+Left"])
    #expect(cfg.shortcuts[.k3] == ["F16"])                       // no fallback for k3
    #expect(cfg.shortcuts[.nextPage] == ["F19"])                 // the new array format is taken as written
    #expect(cfg.shortcuts[.press] == ["F15", "Ctrl+Option+Return"]) // absent → default
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json.bak").path))
    #expect(try Data(contentsOf: url) == Data(legacy.utf8))      // loading never rewrites the file
}

@Test func realTask11ConfigLoads() throws {
    // Copied verbatim from ~/Library/Application Support/LJ Display/config.json as written by Task 11.
    let fixture = try #require(Bundle.module.url(forResource: "config-task11", withExtension: "json", subdirectory: "Fixtures"))
    let dir = tempDir()
    let url = dir.appendingPathComponent("config.json")
    try FileManager.default.copyItem(at: fixture, to: url)
    let cfg = loadConfig(at: url, defaults: AppConfig())
    var want = AppConfig()
    want.brightness = 100 // the user's setting survives the migration
    #expect(cfg == want)  // every legacy F-key → [F-key, fallback] == the new defaults
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json.bak").path))
}

@Test func shortcutsEncodeAsObject() throws {
    let url = tempDir().appendingPathComponent("config.json")
    try saveConfig(AppConfig(), at: url)
    let json = try #require(read(url))
    let sc = try #require(json["shortcuts"] as? [String: [String]])
    #expect(sc["nextPage"] == ["F19", "Ctrl+Option+Down"])
    #expect(sc["k3Hold"] == ["Shift+F18"])
    #expect(json["accounts"] as? [Any] != nil)
}

@Test func saveThenLoadRoundTrips() throws {
    let url = tempDir().appendingPathComponent("config.json")
    var c = AppConfig()
    c.brightness = 20
    c.theme = .jinxBlue
    c.accounts = [AccountConfig(provider: .claudeOAuth, configDir: "~/.claude-work", label: "Work")]
    c.shortcuts[.k1] = ["F16"] // a saved array (no fallback) stays as saved
    try saveConfig(c, at: url)
    #expect(loadConfig(at: url, defaults: AppConfig()) == c)
}

@Test func clampedValues() {
    var c = AppConfig()
    c.brightness = 250
    c.maxFps = 0
    #expect(c.clampedBrightness == 100)
    #expect(c.clampedMaxFps == 1)
    c.brightness = -3
    c.maxFps = 500
    #expect(c.clampedBrightness == 0)
    #expect(c.clampedMaxFps == 60)
}

@Test func pressSpaceFallbackMigratesToReturn() throws {
    // Ctrl+Option+Space is macOS "Select next input source"; an M3-era config holding it gets Return instead.
    let dir = tempDir()
    let url = dir.appendingPathComponent("config.json")
    let json = #"{"shortcuts":{"press":["F15","ctrl + opt + space"],"k1":["Ctrl+Option+Space"]}}"#
    try Data(json.utf8).write(to: url)
    let cfg = loadConfig(at: url, defaults: AppConfig())
    #expect(cfg.shortcuts[.press] == ["F15", "Ctrl+Option+Return"])
    #expect(cfg.shortcuts[.k1] == ["Ctrl+Option+Space"])          // only the press fallback is rewritten
    try Data(#"{"shortcuts":{"press":"Ctrl+Option+Space"}}"#.utf8).write(to: url)
    #expect(loadConfig(at: url, defaults: AppConfig()).shortcuts[.press] == ["Ctrl+Option+Return"])
    try Data(#"{"shortcuts":{"press":["Ctrl+Option+Space","Ctrl+Option+Return"]}}"#.utf8).write(to: url)
    #expect(loadConfig(at: url, defaults: AppConfig()).shortcuts[.press] == ["Ctrl+Option+Return"]) // no duplicate
}
