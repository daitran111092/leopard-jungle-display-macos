import Testing
import Foundation
import CoreGraphics
import CoreText
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

@MainActor
@Suite struct FixtureRenderTests {
    private func renderer() -> ViewRenderer<RootView> {
        ViewRenderer(size: Screen.size, initial: Fixture.railNormal.view)
    }

    @Test func phase1FixtureList() {
        #expect(Fixture.allCases.map(\.rawValue) == ["railNormal", "warnSpeakers", "btLowBattery", "pageNotifications", "pageAI",
                                                  "musicPlaying", "musicPaused", "musicVietnameseLong", "musicIdle", "musicNoArtwork", "musicHiRes192"])
    }

    @Test(arguments: Fixture.allCases)
    func rendersEveryFixture(_ f: Fixture) {
        let img = renderer().render(f.view)
        #expect(img.width == 1920 && img.height == 462)
    }

    /// Average ms per frame for render + rasterising into a bitmap (ImageRenderer's CGImage is lazy),
    /// after 5 warm-up frames.
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

    /// Phase-1 stand-in for the brief's `musicVietnameseLong` budget check (Vietnamese title in the display font).
    @Test func railNormalRendersUnder16msAfterWarmUp() {
        let s = Fixture.railNormal.state
        let ms = measure(renderer()) { i in RootView(state: s, t: Double(i) / 60, now: Fixture.now) }
        print("railNormal render+draw: avg \(ms) ms/frame")
        #expect(ms < 16)
    }

    @Test func warnRendersUnder16msAfterWarmUp() {
        let s = Fixture.warnSpeakers.state
        let ms = measure(renderer()) { i in RootView(state: s, t: Double(i) / 60, now: Fixture.now) }
        print("warnSpeakers render+draw: avg \(ms) ms/frame")
        #expect(ms < 16)
    }

    @Test func pageSlideRendersUnder16ms() {
        let r = renderer()
        var s = Fixture.pageNotifications.state
        s.previousPage = .music
        s.pageChangedAt = Fixture.now
        let ms = measure(r) { i in RootView(state: s, t: 0, now: Fixture.now.addingTimeInterval(Double(i % 30) / 60)) }
        print("page slide render+draw: avg \(ms) ms/frame")
        #expect(ms < 16)
        // Frames really differ along the slide (no cached image).
        let a = r.render(RootView(state: s, t: 0, now: Fixture.now.addingTimeInterval(0.05)))
        let b = r.render(RootView(state: s, t: 0, now: Fixture.now.addingTimeInterval(0.15)))
        #expect(diff(a, b, CGRect(x: 104, y: 0, width: 1196, height: 462)) > 10_000)
    }

    @Test func warningStripesMoveWithT() {
        let r = renderer()
        let s = Fixture.warnSpeakers.state
        let a = r.render(RootView(state: s, t: 0.9, now: Fixture.now))
        let b = r.render(RootView(state: s, t: 1.05, now: Fixture.now))
        // Output block area in the rail (left part, away from the tag).
        let block = CGRect(x: 1340, y: 62, width: 300, height: 70)
        #expect(diff(a, b, block) > 1000)
        // Stripe colour is pink-dominant.
        let p = rgb(a, 1600, 120)
        #expect(p.0 > p.1 + 30)
    }

    @Test func normalRailIsStaticInT() {
        let r = renderer()
        let s = Fixture.railNormal.state
        let a = r.render(RootView(state: s, t: 1, now: Fixture.now))
        let b = r.render(RootView(state: s, t: 7.3, now: Fixture.now))
        #expect(diff(a, b, CGRect(x: 0, y: 0, width: 1920, height: 462)) == 0)
    }
}

@Suite struct FontTests {
    @Test func bundledFontsRegister() {
        let names = Fonts.register()
        #expect(names.count == 8)
        for f in Fonts.Face.allCases {
            let ct = Fonts.ctFont(f, 20)
            #expect(CTFontCopyPostScriptName(ct) as String == f.rawValue)
        }
    }

    @Test func displayFontCoversVietnamese() {
        let font = Fonts.ctFont(.display, 40)
        #expect(CTFontCopyPostScriptName(font) as String == "SVN-RoadRage-Regular")
        let lower = "ăâđêôơưàảãáạằẳẵắặầẩẫấậèẻẽéẹềểễếệìỉĩíịòỏõóọồổỗốộờởỡớợùủũúụừửữứựỳỷỹýỵ"
        for s in [lower, lower.uppercased()] {
            for ch in s {
                let u = Array(String(ch).utf16)
                var g = [CGGlyph](repeating: 0, count: u.count)
                #expect(CTFontGetGlyphsForCharacters(font, u, &g, u.count), "missing \(ch)")
            }
        }
    }

    @Test func saltFallsBackToBeVietnamProForVietnamese() {
        let salt = CTFontCreateForString(Fonts.ctFont(.salt, 40), "ệ" as CFString, CFRange(location: 0, length: 1))
        #expect((CTFontCopyPostScriptName(salt) as String).hasPrefix("BeVietnamPro"))
    }
}

@Suite struct DecorTests {
    @Test func graffitiIsDeterministic() {
        let a = Decor.graffiti(W: 1920, H: 462, seed: 7)
        #expect(a.count == 42)
        #expect(a == Decor.graffiti(W: 1920, H: 462, seed: 7))
        #expect(a != Decor.graffiti(W: 1920, H: 462, seed: 8))
        for m in a {
            switch m {
            case let .word(_, _, _, _, _, op, size, _): #expect(op >= 0.10 && op <= 0.22); #expect(size >= 20 && size <= 38)
            case let .doodle(i, _, _, _, _, op, size): #expect(op >= 0.10 && op <= 0.22); #expect(i < 12); #expect(size >= 40 && size <= 90)
            }
        }
    }

    @Test func firstMarkMatchesMockupGenerator() {
        // Mockup JS, seed 7: first rnd() = 7*16807/2147483647 → x = (0 + .15 + rnd*.7) * W/14.
        let r1 = Double(7 * 16807) / 2147483647
        let x: Double = switch Decor.graffiti(W: 1920, H: 462, seed: 7)[0] {
        case let .word(_, x, _, _, _, _, _, _): x
        case let .doodle(_, x, _, _, _, _, _): x
        }
        #expect(abs(x - (0.15 + r1 * 0.7) * 1920 / 14) < 1e-9)
    }

    @Test func imageIsCachedPerTheme() {
        let a = Decor.image(.jinx), b = Decor.image(.jinx), c = Decor.image(.jinxBlue)
        #expect(a === b)
        #expect(a !== c)
        #expect(a.width == 1920 && a.height == 462)
    }

    @Test func svgArcSwirlHasExtent() {
        let p = SVGPath.parse("M50 50 m-5 0 a5 5 0 1 1 10 0 a10 10 0 1 1 -20 0")
        let b = p.boundingBoxOfPath
        #expect(b.width > 19 && b.width < 21)
    }
}

@Suite struct MotionTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test func pageStripPosition() {
        var s = UiState()
        #expect(PageStrip.position(s, now: t0) == 0)
        s.page = .notifications; s.previousPage = .music; s.pageChangedAt = t0
        #expect(PageStrip.position(s, now: t0) == 0)
        #expect(PageStrip.position(s, now: t0.addingTimeInterval(0.25)) > 0.8)  // ease-out: 87.5 %
        #expect(PageStrip.position(s, now: t0.addingTimeInterval(0.5)) == 1)
        #expect(PageStrip.position(s, now: t0.addingTimeInterval(-60)) == 1)   // clock stepped back: settled
        s.page = .notifications; s.previousPage = .ai
        #expect(PageStrip.position(s, now: t0) == 2)
        s.previousPage = nil; s.page = .music  // default: from the page before in cycle order (ai)
        #expect(PageStrip.position(s, now: t0) == 2)
    }

    @Test func needsAnimationPhase1() {
        var s = UiState()
        #expect(!needsAnimation(s, now: t0))
        s.pageChangedAt = t0
        #expect(needsAnimation(s, now: t0.addingTimeInterval(0.49)))
        #expect(!needsAnimation(s, now: t0.addingTimeInterval(0.5)))
        s.audio = AudioOutput(name: "MacBook Pro Speakers", transport: .builtin, isBuiltInSpeaker: true)
        #expect(needsAnimation(s, now: t0.addingTimeInterval(10)))
        s.audio = AudioOutput(name: "AirPods", transport: .bluetooth, isBuiltInSpeaker: false)
        #expect(!needsAnimation(s, now: t0.addingTimeInterval(10)))
        #expect(needsAnimation(s, now: t0.addingTimeInterval(10), glideConverging: true))
    }

    @Test func animationRatePhase1() {
        var s = UiState()
        #expect(animationRate(s, now: t0) == .none)
        #expect(animationRate(s, now: t0, glideConverging: true) == .ambient)
        s.audio = AudioOutput(name: "MacBook Pro Speakers", transport: .builtin, isBuiltInSpeaker: true)
        #expect(animationRate(s, now: t0) == .ambient)
        s.pageChangedAt = t0
        #expect(animationRate(s, now: t0.addingTimeInterval(0.2)) == .full)
        #expect(Anim.ambientFPS == 20)
    }

    @MainActor @Test func glideEpsilonIsAboutOnePixel() {
        #expect(RailGlide.epsilon > 0.003 && RailGlide.epsilon < 0.005) // ~1 px of a ~270 px bar
    }

    @MainActor @Test func glideEasesAfterIdleGap() {
        let g = RailGlide()
        var s = UiState()
        s.system = SystemStats(cpu: 20, memUsedBytes: 50, memTotalBytes: 100)
        g.step(s, t: 0)
        s.system = SystemStats(cpu: 80, memUsedBytes: 50, memTotalBytes: 100)
        let first = g.step(s, t: 5)!.cpuBar                  // idle gap: must not snap
        #expect(first > 0.2 && first < 0.5)
        #expect(g.isConverging(s))
        var prev = first
        for i in 1...6 {
            let v = g.step(s, t: 5 + Double(i) / 60)!.cpuBar
            #expect(v > prev && v < 0.8)
            prev = v
        }
    }

    @MainActor @Test func glideEasesAndLatchesReadoutAt2Hz() {
        let g = RailGlide()
        var s = UiState()
        #expect(g.step(s, t: 0) == nil)
        s.system = SystemStats(cpu: 20, memUsedBytes: 50, memTotalBytes: 100)
        let m0 = g.step(s, t: 0.1)!
        #expect(m0.cpuBar == 0.2 && m0.memBar == 0.5)       // first sample snaps
        #expect(!g.isConverging(s))
        s.system = SystemStats(cpu: 80, memUsedBytes: 50, memTotalBytes: 100)
        let m1 = g.step(s, t: 0.2)!                          // same 2 Hz tick: readout held
        #expect(m1.cpuBar > 0.2 && m1.cpuBar < 0.8)
        #expect(m1.readout.cpu == 20)
        #expect(g.isConverging(s))
        let m2 = g.step(s, t: 0.5)!                          // next tick: readout updates
        #expect(m2.readout.cpu == 80)
        var t = 0.5
        while g.isConverging(s) && t < 5 { t += 1.0 / 60; g.step(s, t: t) }
        #expect(!g.isConverging(s))
        #expect(t < 2)                                       // converges in well under 2 s
        #expect(g.motion?.cpuBar == 0.8)
    }
}
