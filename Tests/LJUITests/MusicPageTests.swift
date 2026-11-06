import Testing
import SwiftUI
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import LJCore
@testable import LJUI

private func rgb(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}

/// Sum of absolute RGB differences over a sampled rect (top-left origin).
private func diff(_ a: CGImage, _ b: CGImage, _ r: CGRect) -> Int {
    var total = 0
    for y in stride(from: Int(r.minY), to: Int(r.maxY), by: 3) {
        for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 3) {
            let p = rgb(a, x, y), q = rgb(b, x, y)
            total += abs(p.0 - q.0) + abs(p.1 - q.1) + abs(p.2 - q.2)
        }
    }
    return total
}

/// A small solid-colour PNG (distinct bytes per `seed`).
private func png(_ seed: Int) -> Data {
    let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(CGColor(red: CGFloat(seed % 7) / 7, green: 0.3, blue: 0.6, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let out = NSMutableData()
    let dst = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dst)
    return out as Data
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func track(playing: Bool, artwork: Data? = nil) -> NowPlaying {
    NowPlaying(title: "Enemy (from Arcane)", artist: "Imagine Dragons, JID", album: "Arcane",
               appName: "Spotify", bundleID: "com.spotify.client", duration: 173, elapsed: 84,
               elapsedAt: t0, playing: playing, artwork: artwork)
}

@Suite struct MusicRateTests {
    @Test func rateOrdering() {
        #expect(AnimationRate.none < .ambient)
        #expect(AnimationRate.ambient < .music)
        #expect(AnimationRate.music < .full)
        #expect(Anim.musicFPS == 60)
    }

    @Test func musicRateWhenPlayingOnMusicPage() {
        var s = UiState()
        s.page = .music
        s.music = track(playing: true)
        #expect(animationRate(s, now: t0) == .music)
        // A warning (ambient) does not lower it; a page slide raises it to full.
        s.audio = AudioOutput(name: "MacBook Pro Speakers", transport: .builtin, isBuiltInSpeaker: true)
        #expect(animationRate(s, now: t0) == .music)
        #expect(animationRate(s, now: t0, glideConverging: true) == .music)
        s.pageChangedAt = t0
        #expect(animationRate(s, now: t0.addingTimeInterval(0.1)) == .full)
    }

    @Test func noMusicRateWhenPausedOrOtherPage() {
        var s = UiState()
        s.music = track(playing: false)
        #expect(animationRate(s, now: t0) == .none)
        #expect(animationRate(s, now: t0, glideConverging: true) == .ambient)
        s.music = track(playing: true)
        s.page = .notifications
        #expect(animationRate(s, now: t0) == .none)
        s.page = .ai
        #expect(animationRate(s, now: t0, glideConverging: true) == .ambient)
        s.page = .music
        s.music = nil
        #expect(animationRate(s, now: t0) == .none)
    }

    @Test func musicFocusDefaultsToPlay() {
        #expect(UiState().musicFocus == .play)
    }
}

@Suite struct MusicMotionTests {
    @Test func eqMovesWhilePlayingAndFreezesWhenPaused() {
        let a = MusicPage.eqHeights(t: 1, playing: true), b = MusicPage.eqHeights(t: 1.2, playing: true)
        #expect(a.count == 5 && a != b)
        for h in a + b { #expect(h >= 5 && h <= 20) }
        #expect(MusicPage.eqHeights(t: 1, playing: false) == MusicPage.eqHeights(t: 9, playing: false))
        for h in MusicPage.eqHeights(t: 1, playing: false) { #expect(h <= 10) }
    }

    @Test func beatPulseIsSubtleAndOnlyWhilePlaying() {
        var maxScale = 1.0
        for i in 0..<600 {
            let s = MusicPage.artScale(t: Double(i) / 60, playing: true)
            #expect(s >= 1 && s <= 1.015 + 1e-9)
            maxScale = max(maxScale, s)
        }
        #expect(maxScale > 1.01)
        #expect(MusicPage.artScale(t: 0.37, playing: false) == 1)
        #expect(MusicPage.artTilt(t: 0.37, playing: false) == -2)
    }

    @Test func progressFromElapsedNow() {
        let np = track(playing: true)
        #expect(abs(MusicPage.progress(np, now: t0) - 84.0 / 173) < 1e-9)
        #expect(abs(MusicPage.progress(np, now: t0.addingTimeInterval(10)) - 94.0 / 173) < 1e-9)
        #expect(MusicPage.progress(np, now: t0.addingTimeInterval(1000)) == 1)
        var live = np; live.duration = 0
        #expect(MusicPage.progress(live, now: t0) == 0)
    }

    @Test func fallbackArtTitle() {
        #expect(MusicPage.artTitle("Enemy (from Arcane)") == "ENEMY")
        #expect(MusicPage.artTitle("Blinding Lights - Remastered") == "BLINDING LIGHTS")
        #expect(MusicPage.artTitle("(Intro)") == "(INTRO)")
    }
}

@MainActor
@Suite struct ArtworkCacheTests {
    @Test func artworkDecodedOncePerTrack() {
        var calls = 0
        let cache = ArtworkCache { data in calls += 1; return ArtworkCache.decode(data) }
        let art = png(1)
        var s = UiState()
        s.music = track(playing: true, artwork: art)
        let r = ViewRenderer(size: Screen.size, initial: RootView(state: s, t: 0, now: t0, artwork: cache))
        for i in 0..<120 { _ = r.render(RootView(state: s, t: Double(i) / 60, now: t0, artwork: cache)) }
        #expect(calls == 1)
        #expect(cache.image(for: art) != nil)
        #expect(calls == 1)
        // Same bytes in a different Data instance hit the cache too.
        _ = cache.image(for: Data(art))
        #expect(calls == 1)
        _ = cache.image(for: png(2))
        #expect(calls == 2)
    }

    @Test func smallLRUOfFour() {
        var calls = 0
        let cache = ArtworkCache { data in calls += 1; return ArtworkCache.decode(data) }
        let arts = (0..<5).map { png($0) }
        for a in arts.prefix(4) { _ = cache.image(for: a) }
        _ = cache.image(for: arts[0])           // refresh 0: 1 is now least recent
        #expect(calls == 4)
        _ = cache.image(for: arts[4])           // evicts 1
        #expect(calls == 5)
        _ = cache.image(for: arts[0])
        #expect(calls == 5)
        _ = cache.image(for: arts[1])
        #expect(calls == 6)
    }

    @Test func undecodableArtworkIsRememberedAsNil() {
        var calls = 0
        let cache = ArtworkCache { data in calls += 1; return ArtworkCache.decode(data) }
        let junk = Data([1, 2, 3, 4])
        #expect(cache.image(for: junk) == nil)
        #expect(cache.image(for: junk) == nil)
        #expect(calls == 1)
    }
}

@MainActor
@Suite struct MusicFixtureTests {
    nonisolated static let music: [Fixture] = [.musicPlaying, .musicPaused, .musicVietnameseLong, .musicIdle, .musicNoArtwork, .musicHiRes192]

    private func measure(_ r: ViewRenderer<RootView>, _ frame: (Int) -> RootView) -> Double {
        let sink = CGContext(data: nil, width: 1920, height: 462, bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        for i in 0..<5 { sink.draw(r.render(frame(i)), in: CGRect(x: 0, y: 0, width: 1920, height: 462)) }
        let n = 30
        let t0 = DispatchTime.now().uptimeNanoseconds
        for i in 0..<n { sink.draw(r.render(frame(5 + i)), in: CGRect(x: 0, y: 0, width: 1920, height: 462)) }
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(n)
    }

    @Test(arguments: MusicFixtureTests.music)
    func everyMusicFixtureRenders(_ f: Fixture) {
        let r = ViewRenderer(size: Screen.size, initial: f.view)
        let img = r.render(f.view)
        #expect(img.width == 1920 && img.height == 462)
        #expect(f.state.page == .music)
        let s = f.state
        let ms = measure(r) { i in RootView(state: s, t: f.t + Double(i) / 60, now: Fixture.now) }
        print("\(f.rawValue) render+draw: avg \(ms) ms/frame")
        #expect(ms < 25)
    }

    @Test func vietnameseFixtureRendersTitle() {
        let r = ViewRenderer(size: Screen.size, initial: Fixture.musicVietnameseLong.view)
        let viet = r.render(Fixture.musicVietnameseLong.view)
        let idle = r.render(Fixture.musicIdle.view)
        #expect(Fixture.musicVietnameseLong.state.music?.title.contains("ươ") == true)
        // Title row (meta column) differs from the idle page.
        #expect(diff(viet, idle, CGRect(x: 560, y: 60, width: 600, height: 90)) > 10_000)
    }

    @Test func playingFrameMovesWithTPausedDoesNot() {
        let r = ViewRenderer(size: Screen.size, initial: Fixture.musicPlaying.view)
        let content = CGRect(x: 104, y: 0, width: 1196, height: 462)
        let p = Fixture.musicPlaying.state
        #expect(diff(r.render(RootView(state: p, t: 1, now: Fixture.now)),
                     r.render(RootView(state: p, t: 1.3, now: Fixture.now)), content) > 1000)
        let q = Fixture.musicPaused.state
        #expect(diff(r.render(RootView(state: q, t: 1, now: Fixture.now)),
                     r.render(RootView(state: q, t: 7.3, now: Fixture.now)), content) == 0)
    }

    @Test func seekFollowsNow() {
        let r = ViewRenderer(size: Screen.size, initial: Fixture.musicPaused.view)
        var s = Fixture.musicPaused.state
        s.music?.playing = true
        let a = r.render(RootView(state: s, t: 1, now: Fixture.now))
        let b = r.render(RootView(state: s, t: 1, now: Fixture.now.addingTimeInterval(20)))
        // Seek bar + times row.
        #expect(diff(a, b, CGRect(x: 560, y: 250, width: 700, height: 70)) > 1000)
    }
}

/// Pixels in `r` within ±`tol` per channel of `hex` (sampled every 2 px).
private func count(_ img: CGImage, _ r: CGRect, _ hex: UInt32, tol: Int = 14) -> Int {
    let want = (Int(hex >> 16 & 0xff), Int(hex >> 8 & 0xff), Int(hex & 0xff))
    var n = 0
    for y in stride(from: Int(r.minY), to: Int(r.maxY), by: 2) {
        for x in stride(from: Int(r.minX), to: Int(r.maxX), by: 2) {
            let p = rgb(img, x, y)
            if abs(p.0 - want.0) <= tol && abs(p.1 - want.1) <= tol && abs(p.2 - want.2) <= tol { n += 1 }
        }
    }
    return n
}

@MainActor
@Suite struct RateBadgeTests {
    /// Right end of the meta column, artist / album rows (where the badge sits).
    let badgeArea = CGRect(x: 1040, y: 190, width: 230, height: 60)
    let teal: UInt32 = 0x3ee6c9, gold: UInt32 = 0xffc93c, green: UInt32 = 0x5ef27a

    @Test func standardRateBadgeIsTeal() {
        let r = ViewRenderer(size: Screen.size, initial: Fixture.musicPlaying.view)
        let img = r.render(Fixture.musicPlaying.view)
        #expect(count(img, badgeArea, teal) > 40)
        #expect(count(img, badgeArea, gold) == 0)
    }

    @Test(arguments: [Fixture.musicHiRes192, .musicVietnameseLong])
    func hiResBadgeIsGold(_ f: Fixture) {
        let r = ViewRenderer(size: Screen.size, initial: f.view)
        let img = r.render(f.view)
        #expect(count(img, badgeArea, gold) > 40)
        #expect(count(img, badgeArea, teal) == 0)
    }

    @Test func hiddenWhenRateUnknownOrNothingPlaying() {
        var s = Fixture.musicHiRes192.state
        let r = ViewRenderer(size: Screen.size, initial: RootView(state: s, t: 12.3, now: Fixture.now))
        s.audio?.sampleRate = nil
        #expect(count(r.render(RootView(state: s, t: 12.3, now: Fixture.now)), badgeArea, gold) == 0)
        s = Fixture.musicHiRes192.state
        s.music = nil
        #expect(count(r.render(RootView(state: s, t: 12.3, now: Fixture.now)), badgeArea, gold) == 0)
    }

    @Test func badgeColoursFollowK7Leds() {
        #expect(RateBadge.color(.standard) == Palette.teal)
        #expect(RateBadge.color(.hiRes) == Palette.gold)
        #expect(RateBadge.color(.dsd) == Palette.green)
        #expect(Palette.green == Color(hex: green))
    }
}
