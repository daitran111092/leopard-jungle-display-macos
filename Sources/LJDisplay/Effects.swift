import LJCore

/// Runs app-level reducer side effects after LJRuntime has run its own. `.media` is sent by LJRuntime
/// (coalesced + serialized → NowPlayingSource.send); later tasks add `.openApp` → NSWorkspace.openApplication,
/// `.refreshUsage` → UsageSource.refreshNow.
@MainActor enum Effects {
    static func run(_ effects: [Effect]) {
        for e in effects {
            switch e {
            case .media: break // handled by LJRuntime.perform
            }
        }
    }
}
