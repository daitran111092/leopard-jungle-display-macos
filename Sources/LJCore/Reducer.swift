import Foundation

/// Side effects requested by the reducer, run by the app (LJRuntime / Effects).
public enum Effect: Equatable, Sendable {
    /// A playback command for the now-playing app.
    case media(MediaCommand)
}

/// Knob seek step, seconds.
public let seekStep: Double = 5
/// How long an optimistic seek / play state wins over unconfirmed adapter events.
public let musicHoldDuration: TimeInterval = 1.5
/// An adapter position within this of the pending target confirms a seek.
public let seekConfirmTolerance: Double = 1.5

/// Pure state transition.
/// - nextPage / prevPage: cycle pages.
/// - Music page with a track (`music != nil`): turnLeft / turnRight seek ∓/± `seekStep` (clamped to 0…duration),
///   press toggles play/pause, k1 = previous track, k2 = next track. Seek and toggle update `music`
///   optimistically and open a `MusicHold` (see `mergeAdapterMusic`), so successive turns build on the pending target
///   even when a stale adapter event arrives in between. No track or another page → no-op.
public func reduce(_ s: UiState, _ a: Action, now: Date) -> (UiState, [Effect]) {
    var s = s
    let n = PageID.allCases.count
    switch a {
    case .nextPage, .prevPage:
        let step = a == .nextPage ? 1 : n - 1
        s.previousPage = s.page
        s.page = PageID(rawValue: (s.page.rawValue + step) % n)!
        s.pageChangedAt = now
        return (s, [])
    case .turnLeft, .turnRight, .press, .k1, .k2:
        guard s.page == .music, s.music != nil else { return (s, []) }
        s = expireMusicHold(s, now: now)
        guard var m = s.music else { return (s, []) }
        var hold = s.musicHold ?? MusicHold(until: now, adapter: s.music)
        let effect: Effect
        switch a {
        case .turnLeft, .turnRight:
            let target = elapsedNow(m, at: now) + (a == .turnLeft ? -seekStep : seekStep)
            let x = max(0, m.duration > 0 ? min(m.duration, target) : target)
            m.elapsed = x
            m.elapsedAt = now
            hold.seek = x
            effect = .media(.seek(x))
        case .press:
            m.elapsed = elapsedNow(m, at: now) // freeze / restart the clock here so the bar doesn't jump
            m.elapsedAt = now
            m.playing.toggle()
            hold.playing = m.playing
            effect = .media(.toggle)
        case .k1: return (s, [.media(.prev)])
        case .k2: return (s, [.media(.next)])
        case .k3, .k3Hold, .nextPage, .prevPage: return (s, [])
        }
        hold.until = now.addingTimeInterval(musicHoldDuration)
        s.music = m
        s.musicHold = hold
        return (s, [effect])
    case .k3, .k3Hold:
        return (s, [])
    }
}

/// Applies an adapter update (`NowPlayingSource.onChange`) to the state, respecting `musicHold`:
/// - no live hold, nothing playing, or a different track → `music = np`, hold dropped;
/// - a pending seek is confirmed when the adapter's position is within `seekConfirmTolerance` of the optimistic one,
///   a pending play state when the adapter's `playing` matches;
/// - while anything is still pending, the optimistic position (and play state, if pending) is kept; the rest
///   (title, artwork, duration…) comes from the adapter, and `np` is remembered for expiry.
public func mergeAdapterMusic(_ s: UiState, _ np: NowPlaying?, now: Date) -> UiState {
    var s = s
    guard var hold = s.musicHold, now < hold.until, let np, let cur = s.music,
          np.bundleID == cur.bundleID, np.title == cur.title else {
        s.music = np
        s.musicHold = nil
        return s
    }
    hold.adapter = np
    if hold.seek != nil, abs(elapsedNow(np, at: now) - elapsedNow(cur, at: now)) < seekConfirmTolerance { hold.seek = nil }
    if let p = hold.playing, np.playing == p { hold.playing = nil }
    guard hold.seek != nil || hold.playing != nil else {
        s.music = np
        s.musicHold = nil
        return s
    }
    var m = np
    m.elapsed = cur.elapsed
    m.elapsedAt = cur.elapsedAt
    if hold.playing != nil { m.playing = cur.playing }
    s.music = m
    s.musicHold = hold
    return s
}

/// Ends an unconfirmed hold once `until` has passed: `music` goes back to the adapter's latest state.
public func expireMusicHold(_ s: UiState, now: Date) -> UiState {
    guard let hold = s.musicHold, now >= hold.until else { return s }
    var s = s
    s.music = hold.adapter
    s.musicHold = nil
    return s
}
