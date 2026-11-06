import Foundation

/// A playback command for the now-playing app (sent by `NowPlayingSource`).
public enum MediaCommand: Equatable, Sendable {
    case toggle, next, prev
    /// Absolute position in seconds.
    case seek(Double)
}

/// Applies one `mediaremote-adapter stream` event (`{"type":"data","diff":Bool,"payload":{…}}`) to the previous state.
///
/// - `diff == false`: the payload is the whole state; nothing carries over from `prev`. An empty payload → nil
///   (nothing is playing).
/// - `diff == true`: the payload's keys are merged onto `prev`; a key with a `null` value is removed. A diff with
///   no `prev` to merge onto → nil.
/// - Mandatory: `title` and `bundleIdentifier` (the adapter never emits media without them) → otherwise nil.
/// - Times: `duration` / `elapsedTime` (seconds) and `timestamp` (ISO-8601, whole seconds), or their `--micros`
///   variants `durationMicros` / `elapsedTimeMicros` / `timestampEpochMicros` (preferred when present).
///   `elapsedTime` is the position at `timestamp`; a missing timestamp on a full event means `now`. A diff that
///   flips `playing` without a new anchor re-anchors at `now` (position frozen on pause / resumed on play).
/// - `artworkData` is base64; `appName` is kept from `prev` when the bundle id is unchanged, else "" — the source
///   resolves it from the bundle id.
public func applyAdapterEvent(_ json: [String: Any], to prev: NowPlaying?, now: Date) -> NowPlaying? {
    guard let payload = json["payload"] as? [String: Any] else { return prev }
    let isDiff = json["diff"] as? Bool ?? false
    if !isDiff && payload.isEmpty { return nil }

    var base: NowPlaying
    if isDiff {
        guard let prev else { return nil }
        base = prev
    } else {
        base = NowPlaying(title: "", artist: "", album: "", appName: "", bundleID: "",
                          duration: 0, elapsed: 0, elapsedAt: now, playing: false)
    }

    // nil → key absent (keep); .some(nil) → key is null (remove).
    func value(_ key: String) -> Any?? {
        guard let v = payload[key] else { return nil }
        return .some(v is NSNull ? nil : v)
    }
    // Precomposed (NFC): players send decomposed text (Music.app: "Ổ" = O + U+0302 + U+0309), and the display
    // font has the precomposed Vietnamese glyphs but no combining marks.
    func string(_ key: String) -> String?? { value(key).map { ($0 as? String)?.precomposedStringWithCanonicalMapping } }
    func number(_ key: String) -> Double?? { value(key).map { ($0 as? NSNumber)?.doubleValue } }

    if let v = string("title") { base.title = v ?? "" }
    if let v = string("artist") { base.artist = v ?? "" }
    if let v = string("album") { base.album = v ?? "" }
    if let v = string("bundleIdentifier") {
        let id = v ?? ""
        if id != base.bundleID { base.appName = "" }
        base.bundleID = id
    }
    if let v = value("playing") { base.playing = (v as? Bool) ?? false }

    if let v = number("durationMicros") { base.duration = (v ?? 0) / 1e6 }
    else if let v = number("duration") { base.duration = v ?? 0 }
    if let v = number("elapsedTimeMicros") { base.elapsed = (v ?? 0) / 1e6 }
    else if let v = number("elapsedTime") { base.elapsed = v ?? 0 }
    if let v = number("timestampEpochMicros") {
        base.elapsedAt = v.map { Date(timeIntervalSince1970: $0 / 1e6) } ?? now
    } else if let v = string("timestamp") {
        base.elapsedAt = v.flatMap { isoFormatter.date(from: $0) } ?? now
    }

    // A play/pause flip arrives before the diff with the new anchor: freeze / restart the clock at `now` so the
    // position doesn't jump (the adapter's next elapsed/timestamp diff then corrects it).
    let anchorKeys = ["elapsedTime", "elapsedTimeMicros", "timestamp", "timestampEpochMicros"]
    if isDiff, let prev, prev.playing != base.playing, !anchorKeys.contains(where: { payload[$0] != nil }) {
        base.elapsed = elapsedNow(prev, at: now)
        base.elapsedAt = now
    }

    if let v = string("artworkData") { base.artwork = v.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) } }

    guard !base.title.isEmpty, !base.bundleID.isEmpty else { return nil }
    return base
}

/// Current playback position: advances with wall time while playing, clamped to 0 … duration (when known).
public func elapsedNow(_ np: NowPlaying, at now: Date) -> Double {
    guard np.playing else { return max(0, np.elapsed) }
    let e = max(0, np.elapsed + now.timeIntervalSince(np.elapsedAt))
    return np.duration > 0 ? min(np.duration, e) : e
}

nonisolated(unsafe) private let isoFormatter = ISO8601DateFormatter()
