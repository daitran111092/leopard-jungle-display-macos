import Foundation

public enum Transport: String, Codable, Sendable { case bluetooth, builtin, usb, hdmi, airplay, other }

public struct AudioOutput: Equatable, Sendable {
    public var name: String
    public var transport: Transport
    public var volume: Double?
    public var isBuiltInSpeaker: Bool
    /// Device nominal sample rate (Hz), nil when unknown.
    public var sampleRate: Double?
    /// Bits per channel of the first output stream (physical, else virtual format), nil when unknown.
    public var bitDepth: Int?
    public init(name: String, transport: Transport, volume: Double? = nil, isBuiltInSpeaker: Bool,
                sampleRate: Double? = nil, bitDepth: Int? = nil) {
        self.name = name; self.transport = transport; self.volume = volume; self.isBuiltInSpeaker = isBuiltInSpeaker
        self.sampleRate = sampleRate; self.bitDepth = bitDepth
    }
}

public enum BtKind: String, Codable, Sendable { case headphones, keyboard, mouse, controller, other }

public struct BtDevice: Equatable, Sendable {
    public var name: String
    public var kind: BtKind
    public var battery: Int?
    public var batteryL: Int?
    public var batteryR: Int?
    public var batteryCase: Int?
    public init(name: String, kind: BtKind, battery: Int? = nil, batteryL: Int? = nil, batteryR: Int? = nil, batteryCase: Int? = nil) {
        self.name = name; self.kind = kind; self.battery = battery
        self.batteryL = batteryL; self.batteryR = batteryR; self.batteryCase = batteryCase
    }
}

public struct ProcSample: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var appPath: String?
    public var cpu: Double
    public var rssBytes: UInt64
    public init(pid: Int32, name: String, appPath: String? = nil, cpu: Double, rssBytes: UInt64) {
        self.pid = pid; self.name = name; self.appPath = appPath; self.cpu = cpu; self.rssBytes = rssBytes
    }
}

public struct AppUsage: Equatable, Sendable {
    public var name: String
    public var cpu: Double
    public var rssBytes: UInt64
    public init(name: String, cpu: Double, rssBytes: UInt64) {
        self.name = name; self.cpu = cpu; self.rssBytes = rssBytes
    }
}

public struct SystemStats: Equatable, Sendable {
    public var cpu: Double
    public var memUsedBytes: UInt64
    public var memTotalBytes: UInt64
    public var topApps: [AppUsage]
    public init(cpu: Double, memUsedBytes: UInt64, memTotalBytes: UInt64, topApps: [AppUsage] = []) {
        self.cpu = cpu; self.memUsedBytes = memUsedBytes; self.memTotalBytes = memTotalBytes; self.topApps = topApps
    }
}

public struct NowPlaying: Equatable, Sendable {
    public var title: String
    public var artist: String
    public var album: String
    public var appName: String
    public var bundleID: String
    public var duration: Double
    public var elapsed: Double
    public var elapsedAt: Date
    public var playing: Bool
    public var artwork: Data?
    public init(title: String, artist: String, album: String, appName: String, bundleID: String,
                duration: Double, elapsed: Double, elapsedAt: Date, playing: Bool, artwork: Data? = nil) {
        self.title = title; self.artist = artist; self.album = album; self.appName = appName; self.bundleID = bundleID
        self.duration = duration; self.elapsed = elapsed; self.elapsedAt = elapsedAt
        self.playing = playing; self.artwork = artwork
    }
}

public struct NotificationItem: Equatable, Sendable {
    public var id: String
    public var bundleID: String
    public var appName: String
    public var title: String
    public var subtitle: String
    public var body: String
    public var date: Date
    public init(id: String, bundleID: String, appName: String, title: String, subtitle: String, body: String, date: Date) {
        self.id = id; self.bundleID = bundleID; self.appName = appName
        self.title = title; self.subtitle = subtitle; self.body = body; self.date = date
    }
}

public struct UsageWindow: Equatable, Sendable {
    public var pct: Double
    public var resetsAt: Date?
    public init(pct: Double, resetsAt: Date? = nil) { self.pct = pct; self.resetsAt = resetsAt }
}

public enum UsageProvider: String, Codable, Sendable { case claudeOAuth = "claude-oauth", codex }

public struct AccountUsage: Equatable, Sendable {
    public var id: String
    public var label: String
    public var plan: String
    public var provider: UsageProvider
    public var session: UsageWindow?
    public var weekly: UsageWindow?
    public var updatedAt: Date?
    public var stale: Bool
    public var error: String?
    public init(id: String, label: String, plan: String, provider: UsageProvider,
                session: UsageWindow? = nil, weekly: UsageWindow? = nil,
                updatedAt: Date? = nil, stale: Bool = false, error: String? = nil) {
        self.id = id; self.label = label; self.plan = plan; self.provider = provider
        self.session = session; self.weekly = weekly; self.updatedAt = updatedAt
        self.stale = stale; self.error = error
    }
}

public enum PageID: Int, CaseIterable, Sendable { case music, notifications, ai }

public enum Action: String, Codable, CaseIterable, Sendable {
    case turnLeft, turnRight, press, k1, k2, k3, k3Hold, nextPage, prevPage
}

/// Which Music page control the knob has selected (dashed outline). Default `.play`.
public enum MusicFocus: Int, CaseIterable, Sendable { case prev, play, next }

/// Optimistic music values set by the knob (seek target / play state) that adapter events must not undo until they
/// confirm them or `until` passes. See `mergeAdapterMusic` / `expireMusicHold`.
public struct MusicHold: Equatable, Sendable {
    /// Pending seek target (position at the time of the seek).
    public var seek: Double?
    /// Pending play state.
    public var playing: Bool?
    public var until: Date
    /// The adapter's latest state, restored when the hold expires unconfirmed.
    public var adapter: NowPlaying?
    public init(seek: Double? = nil, playing: Bool? = nil, until: Date, adapter: NowPlaying?) {
        self.seek = seek; self.playing = playing; self.until = until; self.adapter = adapter
    }
}

public enum Theme: String, Codable, Sendable { case jinx, jinxBlue = "jinx-blue" }

public enum Access: Equatable, Sendable { case ok, denied }

public struct UiState: Equatable, Sendable {
    public var page: PageID = .music
    public var theme: Theme = .jinx
    public var pageChangedAt: Date? = nil
    /// Page shown before the last page change; the page strip slides from it. nil → the page before `page` in cycle order.
    public var previousPage: PageID? = nil
    public var music: NowPlaying? = nil
    public var musicFocus: MusicFocus = .play
    public var musicHold: MusicHold? = nil
    public var notifications: [NotificationItem] = []
    public var notifSel = 0
    public var notifAccess: Access = .ok
    public var dismissedIDs: Set<String> = []
    public var newestNotifAt: Date? = nil
    public var accounts: [AccountUsage] = []
    public var accountSel = 0
    public var audio: AudioOutput? = nil
    public var bluetooth: [BtDevice] = []
    public var system: SystemStats? = nil

    public init() {}

    public var visibleNotifications: [NotificationItem] { notifications.filter { !dismissedIDs.contains($0.id) } }
}
