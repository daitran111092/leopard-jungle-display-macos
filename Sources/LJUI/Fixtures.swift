import CoreGraphics
import Foundation
import ImageIO
import LJCore
import UniformTypeIdentifiers

/// Phase-1 visual fixtures (`ljprobe fixtures <dir>` → `<dir>/<name>.png`).
public enum Fixture: String, CaseIterable, Sendable {
    case railNormal, warnSpeakers, btLowBattery, pageNotifications, pageAI
    case musicPlaying, musicPaused, musicVietnameseLong, musicIdle, musicNoArtwork, musicHiRes192

    /// Fixed frame date: 2026-11-04 09:12 local time.
    public static let now: Date = {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 4, hour: 9, minute: 12)) ?? Date(timeIntervalSince1970: 0)
    }()

    /// Animation clock for the fixture frame.
    public var t: TimeInterval {
        switch self {
        case .warnSpeakers: 0.9   // pink border phase, tag mid-wobble
        case .musicPlaying, .musicVietnameseLong, .musicNoArtwork, .musicHiRes192: 12.3   // EQ bars spread, beat near its peak
        default: 12
        }
    }

    @MainActor public var view: RootView { RootView(state: state, t: t, now: Self.now) }

    public var state: UiState {
        var s = UiState()
        s.audio = AudioOutput(name: "AirPods Pro", transport: .bluetooth, volume: 0.45, isBuiltInSpeaker: false)
        s.bluetooth = [
            BtDevice(name: "AirPods Pro", kind: .headphones, batteryL: 82, batteryR: 84, batteryCase: 60),
            BtDevice(name: "Magic Keyboard", kind: .keyboard, battery: 64),
            BtDevice(name: "MX Master 3S", kind: .mouse, battery: 71),
            BtDevice(name: "Kahn Knob", kind: .controller, battery: 91),
        ]
        s.system = Self.system
        switch self {
        case .railNormal:
            s.music = NowPlaying(title: "Chúng Ta Của Hiện Tại", artist: "Sơn Tùng M-TP", album: "Chúng Ta Của Hiện Tại",
                                 appName: "Spotify", bundleID: "com.spotify.client", duration: 301, elapsed: 84,
                                 elapsedAt: Self.now, playing: false)
        case .warnSpeakers:
            s.audio = AudioOutput(name: "MacBook Pro Speakers", transport: .builtin, volume: 0.62, isBuiltInSpeaker: true)
            s.bluetooth = [s.bluetooth[1], s.bluetooth[2], s.bluetooth[3]]
        case .btLowBattery:
            s.bluetooth = [
                BtDevice(name: "AirPods Pro", kind: .headphones, batteryL: 12, batteryR: 40, batteryCase: 5),
                BtDevice(name: "Magic Keyboard", kind: .keyboard, battery: 64),
                BtDevice(name: "MX Master 3S", kind: .mouse, battery: 18),
                BtDevice(name: "Bàn phím cơ Chúng Ta Của Hiện Tại Extended", kind: .other),
                BtDevice(name: "Xbox Wireless Controller", kind: .controller, battery: 50),
            ]
        case .pageNotifications:
            s.page = .notifications
        case .pageAI:
            s.page = .ai
            s.theme = .jinxBlue
        case .musicPlaying:
            s.music = Self.enemy
            s.audio = Self.k7(44_100, 16)
        case .musicPaused:
            s.music = Self.enemy
            s.music?.playing = false
            s.musicFocus = .next
        case .musicVietnameseLong:
            s.music = NowPlaying(title: "Chúng Ta Của Tương Lai (Bản Phối Đặc Biệt Kéo Dài Nhất Từ Trước Đến Nay)",
                                 artist: "Sơn Tùng M-TP, Hoàng Thùy Linh, Đen Vâu, Phương Mỹ Chi",
                                 album: "Những Bài Hát Hay Nhất Mọi Thời Đại · Tuyển Tập Đặc Biệt",
                                 appName: "Music", bundleID: "com.apple.Music", duration: 3725, elapsed: 2468,
                                 elapsedAt: Self.now, playing: true, artwork: Self.artwork)
            s.audio = Self.k7(96_000, 24)
        case .musicHiRes192:
            s.music = Self.enemy
            s.audio = Self.k7(192_000, 24)
        case .musicIdle:
            s.music = nil
        case .musicNoArtwork:
            s.music = Self.enemy
            s.music?.artwork = nil
            s.musicFocus = .prev
        }
        return s
    }

    /// The FiiO K7 USB DAC at a given output format.
    static func k7(_ rate: Double, _ bits: Int) -> AudioOutput {
        AudioOutput(name: "FiiO K7", transport: .usb, isBuiltInSpeaker: false, sampleRate: rate, bitDepth: bits)
    }

    static let enemy = NowPlaying(title: "Enemy (from Arcane)", artist: "Imagine Dragons, JID",
                                  album: "Arcane League of Legends · Season 1", appName: "Spotify",
                                  bundleID: "com.spotify.client", duration: 173, elapsed: 84, elapsedAt: now,
                                  playing: true, artwork: artwork)

    /// Synthetic 600×600 JPEG cover (deterministic): violet → teal gradient, striped sun, grid floor.
    static let artwork: Data = {
        let n = 600
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return Data() }
        let bg = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.08, green: 0.05, blue: 0.25, alpha: 1),
                                                          CGColor(srgbRed: 0.10, green: 0.55, blue: 0.62, alpha: 1)] as CFArray,
                            locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: .zero, end: CGPoint(x: n, y: n), options: [])
        let sun = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 1, green: 0.82, blue: 0.35, alpha: 1),
                                                           CGColor(srgbRed: 1, green: 0.18, blue: 0.55, alpha: 1)] as CFArray,
                             locations: [0, 1])!
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: 150, y: 210, width: 300, height: 300))
        ctx.clip()
        ctx.drawLinearGradient(sun, start: CGPoint(x: 300, y: 510), end: CGPoint(x: 300, y: 210), options: [])
        ctx.restoreGState()
        ctx.setFillColor(CGColor(srgbRed: 0.08, green: 0.05, blue: 0.25, alpha: 1))
        for i in 0..<6 { ctx.fill(CGRect(x: 0, y: 220 + i * 26, width: n, height: 4 + i * 2)) }
        ctx.setFillColor(CGColor(srgbRed: 0.03, green: 0.02, blue: 0.08, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: n, height: 200))
        // Synthwave floor: lines from the horizon's vanishing point plus receding cross lines.
        ctx.setStrokeColor(CGColor(srgbRed: 0.31, green: 0.71, blue: 1, alpha: 0.8))
        ctx.setLineWidth(3)
        for i in -6...12 {
            ctx.move(to: CGPoint(x: 300, y: 200)); ctx.addLine(to: CGPoint(x: 300 + (i - 3) * 110, y: 0))
        }
        for y in [12, 34, 64, 104, 150] { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: n, y: y)) }
        ctx.strokePath()
        guard let img = ctx.makeImage() else { return Data() }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return Data() }
        return out as Data
    }()

    static let system = SystemStats(cpu: 37, memUsedBytes: UInt64(18.4 * 1_073_741_824), memTotalBytes: 24 * 1_073_741_824, topApps: [
        AppUsage(name: "Google Chrome", cpu: 22, rssBytes: UInt64(4.2 * 1_073_741_824)),
        AppUsage(name: "Xcode", cpu: 14, rssBytes: UInt64(3.1 * 1_073_741_824)),
        AppUsage(name: "Claude", cpu: 6, rssBytes: UInt64(1.9 * 1_073_741_824)),
    ])
}
