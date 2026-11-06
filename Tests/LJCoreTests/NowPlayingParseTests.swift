import Testing
import Foundation
@testable import LJCore

/// Fixtures are real `mediaremote-adapter stream` lines captured on macOS 26.6 while Music.app played:
/// np-full.json / np-diff.json (default keys), np-micros-*.json (`--micros`; artwork stripped from the full one).
@Suite struct NowPlayingParseTests {
    private let now = Date(timeIntervalSince1970: 1_793_778_300)

    private func fixture(_ name: String) throws -> [String: Any] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func event(_ line: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }

    private func iso(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    /// Music.app sends decomposed (NFD) text — "Ổ" as O + U+0302 + U+0309. The display font has the precomposed
    /// glyphs but no combining marks, so the marks fell back to another font. Text must arrive precomposed (NFC).
    /// (Swift `==` compares canonically, so compare unicode scalars.)
    @Test func textIsPrecomposed() throws {
        let nfd = "Cuộc Sống Em Ổn Không".decomposedStringWithCanonicalMapping
        let line = #"{"type":"data","diff":false,"payload":{"title":"\#(nfd)","artist":"\#(nfd)","album":"\#(nfd)","bundleIdentifier":"com.apple.Music","playing":true,"duration":343,"elapsedTime":1,"timestamp":"2026-11-04T07:43:22Z"}}"#
        let np = try #require(applyAdapterEvent(try event(line), to: nil, now: now))
        let nfc = Array("Cuộc Sống Em Ổn Không".precomposedStringWithCanonicalMapping.unicodeScalars)
        #expect(Array(np.title.unicodeScalars) == nfc)
        #expect(Array(np.artist.unicodeScalars) == nfc)
        #expect(Array(np.album.unicodeScalars) == nfc)
    }

    @Test func mapsFullEvent() throws {
        let np = try #require(applyAdapterEvent(try fixture("np-full"), to: nil, now: now))
        #expect(np.title == "Lặng Thầm Một Tình Yêu (Live Concert SKYNote - Hà Nội) [feat. Phương Linh]")
        #expect(np.artist == "Quốc Thiên")
        #expect(np.album == "Live Concert SKYNote")
        #expect(np.bundleID == "com.apple.Music")
        #expect(np.appName == "")
        #expect(abs(np.duration - 266.043) < 0.001)
        #expect(np.elapsed == 0)
        #expect(np.elapsedAt == iso("2026-11-04T07:43:22Z"))
        #expect(np.playing)
    }

    @Test func mergesDiff() throws {
        let full = try #require(applyAdapterEvent(try fixture("np-full"), to: nil, now: now))
        // Real pause sequence: {"playing":false} then the elapsed/timestamp diff.
        let paused = try #require(applyAdapterEvent(
            try event(#"{"type":"data","diff":true,"payload":{"playing":false}}"#), to: full, now: now))
        #expect(!paused.playing)
        #expect(paused.title == full.title)
        #expect(paused.artwork == full.artwork)
        #expect(paused.elapsedAt == now)  // re-anchored until the adapter's elapsed/timestamp diff
        #expect(paused.elapsed == elapsedNow(full, at: now))

        let np = try #require(applyAdapterEvent(try fixture("np-diff"), to: paused, now: now))
        #expect(abs(np.elapsed - 14.493778674) < 1e-9)
        #expect(np.elapsedAt == iso("2026-11-04T07:43:36Z"))
        #expect(!np.playing)
        #expect(np.title == full.title)
        #expect(np.artist == full.artist)
        #expect(np.album == full.album)
        #expect(np.duration == full.duration)
        #expect(np.artwork == full.artwork)
        #expect(np.bundleID == full.bundleID)

        // A diff key set to null removes the value.
        let noArt = try #require(applyAdapterEvent(
            try event(#"{"type":"data","diff":true,"payload":{"artworkData":null,"artworkMimeType":null}}"#),
            to: np, now: now))
        #expect(noArt.artwork == nil)
        #expect(noArt.title == np.title)

        // A full event replaces: nothing carries over from prev (new track arrives without artwork).
        let next = try #require(applyAdapterEvent(try event(
            #"{"type":"data","diff":false,"payload":{"title":"Em Trong Mắt Tôi","artist":"Phương Linh","album":"Pha Lê","bundleIdentifier":"com.apple.Music","playing":true,"duration":270,"elapsedTime":0,"timestamp":"2026-11-04T07:43:42Z"}}"#),
            to: np, now: now))
        #expect(next.title == "Em Trong Mắt Tôi")
        #expect(next.artwork == nil)
        #expect(next.playing)
    }

    @Test func mapsMicrosKeys() throws {
        let full = try #require(applyAdapterEvent(try fixture("np-micros-full"), to: nil, now: now))
        #expect(full.title == "Em Trong Mắt Tôi")
        #expect(abs(full.duration - 270.479) < 1e-9)
        #expect(full.elapsed == 60)
        #expect(abs(full.elapsedAt.timeIntervalSince1970 - 1_793_778_230.366203) < 1e-5)
        let np = try #require(applyAdapterEvent(try fixture("np-micros-diff"), to: full, now: now))
        #expect(abs(np.elapsed - 103.746247) < 1e-9)
        #expect(abs(np.elapsedAt.timeIntervalSince1970 - 1_793_778_274.123567) < 1e-5)
    }

    /// The adapter reports a play/pause flip (`{"playing":…}`) before the diff with the new elapsed/timestamp anchor
    /// (see the captured sequence in `mergesDiff`). Until that arrives the position must not jump.
    @Test func playStateFlipKeepsPosition() throws {
        let t0 = Date(timeIntervalSince1970: 1000)
        let playing = NowPlaying(title: "T", artist: "", album: "", appName: "", bundleID: "com.apple.Music",
                                 duration: 200, elapsed: 30, elapsedAt: t0, playing: true)
        let tPause = t0.addingTimeInterval(10)
        let paused = try #require(applyAdapterEvent(
            try event(#"{"type":"data","diff":true,"payload":{"playing":false}}"#), to: playing, now: tPause))
        #expect(elapsedNow(paused, at: tPause.addingTimeInterval(5)) == 40)

        let tResume = tPause.addingTimeInterval(20)
        let resumed = try #require(applyAdapterEvent(
            try event(#"{"type":"data","diff":true,"payload":{"playing":true}}"#), to: paused, now: tResume))
        #expect(elapsedNow(resumed, at: tResume) == 40)
        #expect(elapsedNow(resumed, at: tResume.addingTimeInterval(2)) == 42)

        // When the same payload carries the anchor, the adapter's values win.
        let explicit = try #require(applyAdapterEvent(try event(
            #"{"type":"data","diff":true,"payload":{"playing":false,"elapsedTimeMicros":41000000,"timestampEpochMicros":1009000000}}"#),
            to: playing, now: tPause))
        #expect(explicit.elapsed == 41)
        #expect(explicit.elapsedAt == Date(timeIntervalSince1970: 1009))
    }

    @Test func emptyPayloadIsNil() throws {
        let full = try #require(applyAdapterEvent(try fixture("np-full"), to: nil, now: now))
        #expect(applyAdapterEvent(try event(#"{"type":"data","diff":false,"payload":{}}"#), to: full, now: now) == nil)
        #expect(applyAdapterEvent(try event(#"{"type":"data","diff":false,"payload":{}}"#), to: nil, now: now) == nil)
        // A diff with nothing to merge onto, or one that removes the title, has no valid state.
        #expect(applyAdapterEvent(try fixture("np-diff"), to: nil, now: now) == nil)
        #expect(applyAdapterEvent(try event(#"{"type":"data","diff":true,"payload":{"title":null}}"#), to: full, now: now) == nil)
    }

    @Test func missingTimestampUsesNow() throws {
        let np = try #require(applyAdapterEvent(try event(
            #"{"type":"data","diff":false,"payload":{"title":"T","bundleIdentifier":"com.spotify.client","playing":false}}"#),
            to: nil, now: now))
        #expect(np.elapsedAt == now)
        #expect(np.elapsed == 0)
        #expect(np.duration == 0)
        #expect(np.artist == "")
        #expect(np.album == "")
    }

    @Test func elapsedAdvancesOnlyWhilePlaying() {
        let t0 = Date(timeIntervalSince1970: 1000)
        var np = NowPlaying(title: "T", artist: "A", album: "", appName: "Music", bundleID: "com.apple.Music",
                            duration: 200, elapsed: 30, elapsedAt: t0, playing: true)
        #expect(elapsedNow(np, at: t0.addingTimeInterval(12.5)) == 42.5)
        #expect(elapsedNow(np, at: t0.addingTimeInterval(500)) == 200)  // clamped to duration
        np.playing = false
        #expect(elapsedNow(np, at: t0.addingTimeInterval(12.5)) == 30)
    }

    /// An anchor slightly ahead of `now` (clock skew, adapter timestamp vs line-consume time) must not go negative.
    @Test func elapsedClampsAtZero() {
        let t0 = Date(timeIntervalSince1970: 1000)
        let np = NowPlaying(title: "T", artist: "", album: "", appName: "", bundleID: "com.apple.Music",
                            duration: 200, elapsed: 0, elapsedAt: t0, playing: true)
        #expect(elapsedNow(np, at: t0.addingTimeInterval(-0.8)) == 0)
        var unknown = np
        unknown.duration = 0
        #expect(elapsedNow(unknown, at: t0.addingTimeInterval(-0.8)) == 0)
    }

    @Test func artworkDecoded() throws {
        let np = try #require(applyAdapterEvent(try fixture("np-full"), to: nil, now: now))
        let art = try #require(np.artwork)
        #expect(art.count == 93_318)
        #expect(Array(art.prefix(3)) == [0xFF, 0xD8, 0xFF])  // JPEG
    }
}
