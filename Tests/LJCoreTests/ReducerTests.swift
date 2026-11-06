import Testing
import Foundation
@testable import LJCore

@Suite struct ReducerTests {
    let now = Date(timeIntervalSince1970: 1000)

    @Test func pageCycleWrapsBothWays() {
        var s = UiState()
        var seen: [PageID] = []
        for _ in 0..<3 {
            let (n, fx) = reduce(s, .nextPage, now: now)
            #expect(fx.isEmpty)
            #expect(n.previousPage == s.page)
            #expect(n.pageChangedAt == now)
            s = n; seen.append(s.page)
        }
        #expect(seen == [.notifications, .ai, .music])
        seen = []
        for _ in 0..<3 { s = reduce(s, .prevPage, now: now).0; seen.append(s.page) }
        #expect(seen == [.ai, .notifications, .music])
        #expect(s.previousPage == .notifications)
    }

    @Test func otherActionsAreNoOps() {
        let s = UiState()
        for a in Action.allCases where a != .nextPage && a != .prevPage {
            let (n, fx) = reduce(s, a, now: now)
            #expect(n == s)
            #expect(fx.isEmpty)
        }
    }
}

@Suite struct ReducerMusicTests {
    let now = Date(timeIntervalSince1970: 1000)

    /// Music page with a track 100 s long, playing, at 40 s anchored 2 s ago (→ 42 s now).
    func state(playing: Bool = true, elapsed: Double = 40, page: PageID = .music) -> UiState {
        var s = UiState()
        s.page = page
        s.music = NowPlaying(title: "Get Jinxed", artist: "Jinx", album: "Arcane", appName: "Music",
                             bundleID: "com.apple.Music", duration: 100, elapsed: elapsed,
                             elapsedAt: now.addingTimeInterval(-2), playing: playing)
        return s
    }

    @Test func turnLeftSeeksBackFiveSeconds() {
        let (n, fx) = reduce(state(), .turnLeft, now: now)
        #expect(fx == [.media(.seek(37))])
        #expect(n.music?.elapsed == 37)
        #expect(n.music?.elapsedAt == now)
        #expect(n.music?.playing == true)
        #expect(n.musicFocus == .play)
    }

    @Test func turnRightSeeksForwardFiveSeconds() {
        let (n, fx) = reduce(state(), .turnRight, now: now)
        #expect(fx == [.media(.seek(47))])
        #expect(n.music?.elapsed == 47)
        #expect(n.music?.elapsedAt == now)
    }

    @Test func seekClamps() {
        let (a, fa) = reduce(state(elapsed: 1), .turnLeft, now: now)     // 3 s − 5 → 0
        #expect(fa == [.media(.seek(0))])
        #expect(a.music?.elapsed == 0)
        let (b, fb) = reduce(state(elapsed: 96), .turnRight, now: now)  // 98 s + 5 → 100
        #expect(fb == [.media(.seek(100))])
        #expect(b.music?.elapsed == 100)
    }

    @Test func pressTogglesAndFlipsPlayingOptimistically() {
        let (p, fp) = reduce(state(playing: true), .press, now: now)
        #expect(fp == [.media(.toggle)])
        #expect(p.music?.playing == false)
        #expect(p.music?.elapsed == 42)          // re-anchored: the bar does not jump
        #expect(p.music?.elapsedAt == now)
        let (r, fr) = reduce(state(playing: false), .press, now: now)
        #expect(fr == [.media(.toggle)])
        #expect(r.music?.playing == true)
        #expect(r.music?.elapsed == 40)          // paused position kept
        #expect(r.music?.elapsedAt == now)
    }

    @Test func k1IsPrevK2IsNext() {
        let s = state()
        let (a, fa) = reduce(s, .k1, now: now)
        #expect(fa == [.media(.prev)])
        #expect(a == s)
        let (b, fb) = reduce(s, .k2, now: now)
        #expect(fb == [.media(.next)])
        #expect(b == s)
    }

    @Test func noMusicIsNoOp() {
        var s = UiState()
        s.page = .music
        for a in [Action.turnLeft, .turnRight, .press, .k1, .k2] {
            let (n, fx) = reduce(s, a, now: now)
            #expect(n == s)
            #expect(fx.isEmpty)
        }
    }

    @Test func nonMusicPageIgnoresMusicKeys() {
        for page in [PageID.notifications, .ai] {
            let s = state(page: page)
            for a in [Action.turnLeft, .turnRight, .press, .k1, .k2] {
                let (n, fx) = reduce(s, a, now: now)
                #expect(n == s)
                #expect(fx.isEmpty)
            }
        }
    }

    @Test func pageKeysStillWorkOnMusicPage() {
        let (n, fx) = reduce(state(), .nextPage, now: now)
        #expect(n.page == .notifications)
        #expect(fx.isEmpty)
    }
}

/// Optimistic hold: adapter events that predate a seek / toggle must not undo it.
@Suite struct MusicHoldTests {
    let t0 = Date(timeIntervalSince1970: 1000)

    func track(elapsed: Double, at: Date, playing: Bool = true, title: String = "Get Jinxed") -> NowPlaying {
        NowPlaying(title: title, artist: "Jinx", album: "Arcane", appName: "Music", bundleID: "com.apple.Music",
                   duration: 200, elapsed: elapsed, elapsedAt: at, playing: playing)
    }

    func start() -> UiState {
        var s = UiState()
        s.page = .music
        s.music = track(elapsed: 60, at: t0)
        return s
    }

    func lastSeek(_ fx: [Effect]) -> Double? {
        if case .media(.seek(let x))? = fx.last { return x } else { return nil }
    }

    @Test func spinBuildsOnPendingTargetDespiteStaleEvent() {
        var s = start()
        var fx: [Effect] = []
        (s, fx) = reduce(s, .turnRight, now: t0)
        (s, fx) = reduce(s, .turnRight, now: t0)
        // The adapter reports the pre-seek position (stale) while the knob still turns.
        s = mergeAdapterMusic(s, track(elapsed: 60, at: t0), now: t0)
        #expect(s.music.map { elapsedNow($0, at: t0) } == 70)
        for _ in 0..<3 { (s, fx) = reduce(s, .turnRight, now: t0) }
        #expect(lastSeek(fx) == 85)          // start + 5 × 5
        #expect(s.music?.elapsed == 85)
    }

    @Test func seekConfirmedByAdapterClearsHold() {
        var s = reduce(start(), .turnRight, now: t0).0            // target 65
        #expect(s.musicHold?.seek == 65)
        let t1 = t0.addingTimeInterval(0.5)
        s = mergeAdapterMusic(s, track(elapsed: 65.3, at: t1), now: t1) // |65.3 − 65.5| < 1.5
        #expect(s.musicHold == nil)
        #expect(s.music?.elapsed == 65.3)
    }

    @Test func toggleSurvivesStaleEventUntilConfirmed() {
        var s = reduce(start(), .press, now: t0).0
        #expect(s.music?.playing == false)
        let t1 = t0.addingTimeInterval(0.2)
        s = mergeAdapterMusic(s, track(elapsed: 60.2, at: t1, playing: true), now: t1)  // stale: still playing
        #expect(s.music?.playing == false)
        #expect(s.music?.elapsed == 60)                          // frozen where the press happened
        let t2 = t0.addingTimeInterval(0.4)
        s = mergeAdapterMusic(s, track(elapsed: 60.1, at: t2, playing: false), now: t2) // confirmed
        #expect(s.musicHold == nil)
        #expect(s.music == track(elapsed: 60.1, at: t2, playing: false))
    }

    @Test func holdExpiresBackToAdapterState() {
        var s = reduce(start(), .press, now: t0).0
        let stale = track(elapsed: 60.2, at: t0.addingTimeInterval(0.2), playing: true)
        s = mergeAdapterMusic(s, stale, now: t0.addingTimeInterval(0.2))
        #expect(s.music?.playing == false)
        #expect(expireMusicHold(s, now: t0.addingTimeInterval(1.0)) == s)  // still live
        let late = t0.addingTimeInterval(musicHoldDuration + 0.01)
        let e = expireMusicHold(s, now: late)                              // never confirmed → adapter wins
        #expect(e.musicHold == nil)
        #expect(e.music == stale)
        // An event after expiry is taken as is.
        var s2 = reduce(start(), .press, now: t0).0
        s2 = mergeAdapterMusic(s2, stale, now: late)
        #expect(s2.musicHold == nil)
        #expect(s2.music == stale)
    }

    @Test func trackChangeOrNothingPlayingDropsHold() {
        var s = reduce(start(), .turnRight, now: t0).0
        let other = track(elapsed: 0, at: t0, title: "Enemy")
        s = mergeAdapterMusic(s, other, now: t0)
        #expect(s.musicHold == nil)
        #expect(s.music == other)
        s = reduce(start(), .press, now: t0).0
        s = mergeAdapterMusic(s, nil, now: t0)
        #expect(s.musicHold == nil)
        #expect(s.music == nil)
    }

    @Test func noHoldMergeIsPlainReplace() {
        let s = start()
        let np = track(elapsed: 10, at: t0, playing: false)
        #expect(mergeAdapterMusic(s, np, now: t0).music == np)
        #expect(mergeAdapterMusic(s, np, now: t0).musicHold == nil)
    }
}
