import Foundation

/// One AI-usage account (filled by Task 7). Only `provider` + `configDir` are user-facing; no tokens, ever.
public struct AccountConfig: Codable, Equatable, Sendable {
    public var provider: UsageProvider
    /// Directory holding the provider's own credentials (e.g. `~/.claude`), read at runtime, never copied here.
    public var configDir: String
    public var label: String?
    public init(provider: UsageProvider, configDir: String, label: String? = nil) {
        self.provider = provider; self.configDir = configDir; self.label = label
    }
}

/// `Action` keys encode as a JSON object (`{"nextPage": ["F19"]}`), not Swift's default key/value array.
extension Action: CodingKeyRepresentable {}

/// `~/Library/Application Support/LJ Display/config.json`.
public struct AppConfig: Codable, Equatable, Sendable {
    /// The knob board's keys (one per action).
    public static let fKeyShortcuts: [Action: String] = [
        .turnLeft: "F13", .turnRight: "F14", .press: "F15", .k1: "F16", .k2: "F17",
        .k3: "F18", .k3Hold: "Shift+F18", .nextPage: "F19", .prevPage: "Shift+F19",
    ]
    /// Second bindings for keyboards without F13…F19 (k3 / k3Hold have none).
    public static let fallbackShortcuts: [Action: String] = [
        .turnLeft: "Ctrl+Option+Left", .turnRight: "Ctrl+Option+Right", .press: "Ctrl+Option+Return",
        .k1: "Ctrl+Option+[", .k2: "Ctrl+Option+]", .nextPage: "Ctrl+Option+Down", .prevPage: "Ctrl+Option+Up",
    ]
    /// F-key first, then the fallback.
    public static let defaultShortcuts: [Action: [String]] = Dictionary(uniqueKeysWithValues: fKeyShortcuts.map { a, f in
        (a, [f] + (fallbackShortcuts[a].map { [$0] } ?? []))
    })

    public var theme: Theme = .jinx
    /// Panel backlight, percent.
    public var brightness = 80
    /// Frame-loop timer rate (frames per second, 1…60).
    public var maxFps = 60
    public var accounts: [AccountConfig] = []
    /// Every binding of each action fires it.
    public var shortcuts: [Action: [String]] = AppConfig.defaultShortcuts

    public init() {}

    public var clampedBrightness: Int { min(max(brightness, 0), 100) }
    public var clampedMaxFps: Int { min(max(maxFps, 1), 60) }

    /// The default config file location.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LJ Display", isDirectory: true)
            .appendingPathComponent("config.json")
    }
}

/// Loads the config at `url`:
/// - missing → writes `defaults` there (creating the directory) and returns them;
/// - unreadable, not a JSON object, or a value of the wrong type → copies the file to `config.json.bak`
///   and returns `defaults` (the original file is left in place);
/// - partial → every key absent from the file takes its value from `defaults` (objects such as
///   `shortcuts` merge per key; arrays such as `accounts` replace);
/// - legacy (Task 11) shortcuts: a string value `"F13"` becomes `["F13", <that action's fallback>]`, since the old
///   format could not list the fallback. The file itself is not rewritten.
public func loadConfig(at url: URL, defaults: AppConfig) -> AppConfig {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else {
        try? saveConfig(defaults, at: url)
        return defaults
    }
    if let data = try? Data(contentsOf: url),
       let user = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).map(migrateLegacyShortcuts),
       let base = (try? JSONEncoder().encode(defaults)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }),
       let merged = try? JSONSerialization.data(withJSONObject: deepMerge(base, user)),
       let cfg = try? JSONDecoder().decode(AppConfig.self, from: merged) {
        return cfg
    }
    let bak = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".bak")
    try? fm.removeItem(at: bak)
    try? fm.copyItem(at: url, to: bak)
    return defaults
}

/// Writes `config` atomically as pretty-printed JSON with sorted keys, creating the directory if needed.
public func saveConfig(_ config: AppConfig, at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    try enc.encode(config).write(to: url, options: .atomic)
}

/// `"shortcuts": {"turnLeft": "F13"}` → `{"turnLeft": ["F13", "Ctrl+Option+Left"]}`. Arrays and other values
/// pass through unchanged (a wrong type still fails decoding), except that a `press` binding of Ctrl+Option+Space
/// (the first M3 fallback; macOS uses it for "Select next input source") becomes Ctrl+Option+Return.
func migrateLegacyShortcuts(_ json: [String: Any]) -> [String: Any] {
    guard let sc = json["shortcuts"] as? [String: Any] else { return json }
    var out = json
    out["shortcuts"] = sc.reduce(into: [String: Any]()) { acc, kv in
        var list: [String]
        if let s = kv.value as? String {
            let fallback = Action(rawValue: kv.key).flatMap { AppConfig.fallbackShortcuts[$0] }
            list = [s] + (fallback.map { $0.caseInsensitiveCompare(s) == .orderedSame ? [] : [$0] } ?? [])
        } else if let a = kv.value as? [String] {
            list = a
        } else {
            acc[kv.key] = kv.value; return
        }
        if kv.key == Action.press.rawValue {
            let space = normalizedBinding("Ctrl+Option+Space"), ret = "Ctrl+Option+Return"
            list = list.map { normalizedBinding($0) == space ? ret : $0 }
            var seen = Set<String>()
            list = list.filter { seen.insert(normalizedBinding($0)).inserted }
        }
        acc[kv.key] = list
    }
    return out
}

/// Case-, space-, alias- and order-insensitive form of a binding (`ctrl + opt + space` == `Option+Control+Space`).
func normalizedBinding(_ s: String) -> String {
    let parts = s.split(separator: "+", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard let key = parts.last else { return "" }
    let alias = ["control": "ctrl", "opt": "option", "alt": "option"]
    return (parts.dropLast().map { alias[$0] ?? $0 }.sorted() + [key]).joined(separator: "+")
}

private func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
    var out = base
    for (k, v) in over {
        if let b = base[k] as? [String: Any], let o = v as? [String: Any] {
            out[k] = deepMerge(b, o)
        } else {
            out[k] = v
        }
    }
    return out
}
