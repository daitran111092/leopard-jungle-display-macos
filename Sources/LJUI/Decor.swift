import CoreGraphics
import CoreText
import Foundation
import ImageIO
import LJCore

/// Static background: radial gradients + seeded graffiti wall + "JINX" word + monkey.
/// Ported from the v3 mockup (`.lj` background, `graffiti(W, H, seed)`, `.jx-word`, `.monkey`).
/// Drawn once per theme into a cached opaque `CGImage`; views draw it as a single `Image`.
/// (The mockup's `feTurbulence` roughening filter is not reproduced.)
public enum Decor {
    public static let seed = 7

    /// Cached decor for `theme` at the canvas size.
    public static func image(_ theme: Theme) -> CGImage { cache.get(theme) }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [Theme: CGImage] = [:]
        func get(_ t: Theme) -> CGImage {
            lock.withLock {
                if let i = images[t] { return i }
                let i = Decor.render(theme: t, width: Int(Screen.width), height: Int(Screen.height), seed: Decor.seed)
                images[t] = i
                return i
            }
        }
    }

    // MARK: - Rendering

    static func render(theme: Theme, width: Int, height: Int, seed: Int) -> CGImage {
        let W = CGFloat(width), H = CGFloat(height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        // Work in CSS coordinates: origin top-left, y down.
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high

        drawBackground(ctx, theme: theme, W: W, H: H, space: space)
        drawWall(ctx, W: W, H: H, seed: seed)
        drawWord(ctx, W: W, H: H, space: space)
        drawMonkey(ctx, H: H)
        return ctx.makeImage()!
    }

    private struct Radial { let rx, ry, cx, cy: CGFloat; let stops: [(UInt32, CGFloat, CGFloat)] } // (rgb, alpha, location)

    private static func radials(_ theme: Theme) -> [Radial] {
        switch theme {
        case .jinx:
            [Radial(rx: 0.70, ry: 0.90, cx: 0.50, cy: 0.42, stops: [(0x1c0c3a, 1, 0), (0x0b0620, 1, 0.5), (0x06040d, 1, 0.85)]),
             Radial(rx: 0.40, ry: 0.70, cx: 0.72, cy: 0.45, stops: [(0xc81e8c, 0.26, 0), (0xc81e8c, 0, 0.7)]),
             Radial(rx: 0.40, ry: 0.70, cx: 0.30, cy: 0.45, stops: [(0x285ac8, 0.32, 0), (0x285ac8, 0, 0.7)])]
        case .jinxBlue:
            [Radial(rx: 0.70, ry: 0.90, cx: 0.50, cy: 0.42, stops: [(0x0f1238, 1, 0), (0x080a22, 1, 0.5), (0x05040d, 1, 0.85)]),
             Radial(rx: 0.28, ry: 0.50, cx: 0.78, cy: 0.40, stops: [(0xc81e8c, 0.18, 0), (0xc81e8c, 0, 0.7)]),
             Radial(rx: 0.55, ry: 0.70, cx: 0.38, cy: 0.45, stops: [(0x285ad2, 0.38, 0), (0x285ad2, 0, 0.7)])]
        }
    }

    private static func cg(_ rgb: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255, alpha: a)
    }

    private static func drawBackground(_ ctx: CGContext, theme: Theme, W: CGFloat, H: CGFloat, space: CGColorSpace) {
        for (i, r) in radials(theme).enumerated() {
            let g = CGGradient(colorsSpace: space, colors: r.stops.map { cg($0.0, $0.1) } as CFArray,
                               locations: r.stops.map(\.2))!
            ctx.saveGState()
            ctx.translateBy(x: r.cx * W, y: r.cy * H)
            ctx.scaleBy(x: r.rx * W, y: r.ry * H)
            ctx.drawRadialGradient(g, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 1,
                                   options: i == 0 ? [.drawsAfterEndLocation] : [])
            ctx.restoreGState()
        }
    }

    // MARK: graffiti wall

    /// The 12 doodles from the mockup, in `Object.keys` order (the seeded `pick` depends on it).
    /// Each: SVG path strings + circles (cx, cy, r) in a 100×100 box.
    static let doodles: [(name: String, paths: [String], circles: [(CGFloat, CGFloat, CGFloat)])] = [
        ("skull", ["M30 30 L24 9 M42 26 L40 5 M58 26 L61 5 M70 30 L77 9",
                   "M22 55 C18 24 82 24 78 55 C78 66 71 70 66 72 L66 83 L34 83 L34 72 C29 70 22 66 22 55 Z"], []),
        ("monkey", ["M42 28 L39 15 M50 27 V12 M58 28 L62 15 M39 42 l8 8 m0 -8 l-8 8 M54 42 l8 8 m0 -8 l-8 8"],
         [(22, 48, 10), (78, 48, 10), (50, 52, 25)]),
        ("bolt", ["M58 4 L34 52 L54 52 L38 96 L76 38 L54 38 L70 4 Z"], []),
        ("star", ["M50 8 L74 90 L10 38 L90 38 L26 90 Z"], []),
        ("x", ["M22 22 L78 78 M78 22 L22 78"], []),
        ("arrow", ["M5 75 L30 40 L50 66 L84 18 M84 18 L68 22 M84 18 L82 34"], []),
        ("chev", ["M8 30 L28 50 L8 70 M34 30 L54 50 L34 70 M60 30 L80 50 L60 70"], []),
        ("grin", ["M8 42 Q50 86 92 42 Q50 64 8 42 Z M26 50 L28 62 M40 55 L41 68 M55 56 L55 68 M70 52 L68 62 M30 20 l8 8 m0 -8 l-8 8 M62 20 l8 8 m0 -8 l-8 8"], []),
        ("bunny", ["M40 46 L30 4 L47 42 M60 46 L70 4 L53 42", "M40 57 l6 6 m0 -6 l-6 6 M54 57 l6 6 m0 -6 l-6 6 M44 74 Q50 79 56 74"],
         [(50, 64, 20)]),
        ("heart", ["M50 86 C10 56 14 18 50 40 C86 18 90 56 50 86 Z"], []),
        ("swirl", ["M50 50 m-5 0 a5 5 0 1 1 10 0 a10 10 0 1 1 -20 0 a16 16 0 1 1 32 0 a22 22 0 1 1 -44 0"], []),
        ("burst", ["M50 10 L57 38 L84 22 L64 46 L92 56 L62 60 L72 88 L50 66 L28 88 L38 60 L8 56 L36 46 L16 22 L43 38 Z"], []),
    ]
    static let words = ["HA HA!", "BOOM!", "JINX", "POW POW", "GET JINXED", "KA-BOOM", "ZAP!", "BLA BLA"]
    static let colors: [(UInt32, Double)] = [(0x4fb6ff, 9), (0xff2eaa, 5), (0x3ee6c9, 2), (0xffc93c, 1.5), (0xa45cff, 2)]

    /// One placed element of the wall (exposed for tests).
    enum Mark: Equatable {
        case word(text: String, x: Double, y: Double, rot: Double, color: UInt32, opacity: Double, size: Double, salt: Bool)
        case doodle(index: Int, x: Double, y: Double, rot: Double, color: UInt32, opacity: Double, size: Double)
    }

    /// Port of the mockup's `graffiti(W, H, s)` placement (Park–Miller LCG, 14×3 cells).
    static func graffiti(W: Double, H: Double, seed s: Int) -> [Mark] {
        var seed = Int64(s)
        func rnd() -> Double { seed = (seed * 16807) % 2147483647; return Double(seed) / 2147483647 }
        let total = colors.reduce(0) { $0 + $1.1 }
        func color() -> UInt32 {
            var r = rnd() * total
            for (c, w) in colors { r -= w; if r < 0 { return c } }
            return colors[0].0
        }
        let cols = 14, rows = 3
        var out: [Mark] = []
        for r in 0..<rows {
            for c in 0..<cols {
                let x = (Double(c) + 0.15 + rnd() * 0.7) * W / Double(cols)
                let y = (Double(r) + 0.15 + rnd() * 0.7) * H / Double(rows)
                let rot = (rnd() - 0.5) * 50
                let col = color()
                let op = ((0.10 + rnd() * 0.12) * 100).rounded() / 100
                if rnd() < 0.3 {
                    let size = 20 + rnd() * 18
                    let salt = rnd() < 0.5
                    let w = words[Int(rnd() * Double(words.count))]
                    out.append(.word(text: w, x: x, y: y, rot: rot, color: col, opacity: op, size: size, salt: salt))
                } else {
                    let sz = 40 + rnd() * 50
                    let i = Int(rnd() * Double(doodles.count))
                    out.append(.doodle(index: i, x: x, y: y, rot: rot, color: col, opacity: op, size: sz))
                }
            }
        }
        return out
    }

    private static func drawWall(_ ctx: CGContext, W: CGFloat, H: CGFloat, seed: Int) {
        let paths = doodles.map { d -> CGPath in
            let p = CGMutablePath()
            for s in d.paths { p.addPath(SVGPath.parse(s)) }
            for (cx, cy, r) in d.circles { p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)) }
            return p
        }
        for m in graffiti(W: Double(W), H: Double(H), seed: seed) {
            switch m {
            case let .word(text, x, y, rot, color, opacity, size, salt):
                ctx.saveGState()
                ctx.setAlpha(opacity)
                ctx.translateBy(x: x, y: y)
                ctx.rotate(by: rot * .pi / 180)
                let font = Fonts.ctFont(salt ? .salt : .display, size)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key: cg(color),
                ]))
                ctx.textPosition = .zero
                CTLineDraw(line, ctx)
                ctx.restoreGState()
            case let .doodle(index, x, y, rot, color, opacity, sz):
                let k = sz / 100
                ctx.saveGState()
                ctx.setAlpha(opacity)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.translateBy(x: x - sz / 2, y: y - sz / 2)
                ctx.translateBy(x: sz / 2, y: sz / 2)
                ctx.rotate(by: rot * .pi / 180)
                ctx.translateBy(x: -sz / 2, y: -sz / 2)
                ctx.scaleBy(x: k, y: k)
                ctx.addPath(paths[index])
                ctx.setStrokeColor(cg(color))
                ctx.setLineWidth(4)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.strokePath()
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }
    }

    // MARK: JINX word + monkey

    private static func drawWord(_ ctx: CGContext, W: CGFloat, H: CGFloat, space: CGColorSpace) {
        let font = Fonts.ctFont(.display, 300)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "JINX", attributes: [
            kCTFontAttributeName as NSAttributedString.Key: font,
        ]))
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        let asc = CTFontGetAscent(font), desc = CTFontGetDescent(font)
        ctx.saveGState()
        ctx.setAlpha(0.06)
        ctx.translateBy(x: 0.46 * W, y: 0.5 * H)
        ctx.rotate(by: -6 * .pi / 180)
        // Line box of height 300 (line-height 1) centred on the origin; baseline inside it.
        let baseline = (asc - desc) / 2
        // Clip to the glyph outlines (text drawing mode .clip is not honoured by CTLineDraw).
        let glyphs = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            var gs = [CGGlyph](repeating: 0, count: n), ps = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &gs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &ps)
            let runFont = (CTRunGetAttributes(run) as Dictionary)[kCTFontAttributeName] as! CTFont
            for i in 0..<n {
                guard let g = CTFontCreatePathForGlyph(runFont, gs[i], nil) else { continue }
                // Glyph outlines are y-up; flip into our y-down space at the baseline.
                let tf = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: -w / 2 + ps[i].x, ty: baseline)
                glyphs.addPath(g, transform: tf)
            }
        }
        ctx.addPath(glyphs)
        ctx.clip()
        let g = CGGradient(colorsSpace: space, colors: [cg(0x4fb6ff), cg(0xff2eaa)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: -w / 2, y: 0), end: CGPoint(x: w / 2, y: 0), options: [])
        ctx.restoreGState()
    }

    /// monkey.png was found and decodes (for the launch log).
    public static var monkeyLoaded: Bool { monkey() != nil }

    static func monkey() -> CGImage? {
        guard let url = LJResources.url?.appendingPathComponent("monkey.png"),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    private static func drawMonkey(_ ctx: CGContext, H: CGFloat) {
        guard let img = monkey() else { return }
        let h = 440 * H / 480
        let w = h * CGFloat(img.width) / CGFloat(img.height)
        ctx.saveGState()
        ctx.setAlpha(0.13)
        ctx.translateBy(x: 640, y: H / 2)
        ctx.rotate(by: -6 * .pi / 180)
        ctx.scaleBy(x: 1, y: -1) // images draw y-up
        ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        ctx.restoreGState()
    }
}

/// Minimal SVG path-data parser (M L H V C Q A Z, absolute and relative) for the doodles.
enum SVGPath {
    static func parse(_ d: String) -> CGPath {
        let p = CGMutablePath()
        var tokens: [String] = []
        var num = ""
        func flush() { if !num.isEmpty { tokens.append(num); num = "" } }
        for ch in d {
            if ch.isLetter { flush(); tokens.append(String(ch)) }
            else if ch == " " || ch == "," { flush() }
            else if ch == "-" && !num.isEmpty && !num.hasSuffix("e") { flush(); num = "-" }
            else { num.append(ch) }
        }
        flush()

        var i = 0
        var cmd: Character = "M"
        var cur = CGPoint.zero, start = CGPoint.zero
        func n() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        func hasNum() -> Bool { i < tokens.count && !(tokens[i].first?.isLetter ?? false) }
        while i < tokens.count {
            if let c = tokens[i].first, c.isLetter { cmd = c; i += 1 }
            let rel = cmd.isLowercase
            let o = rel ? cur : .zero
            switch cmd.uppercased().first! {
            case "M":
                cur = CGPoint(x: o.x + n(), y: o.y + n()); start = cur; p.move(to: cur)
                cmd = rel ? "l" : "L" // implicit lineto after the first pair
            case "L":
                cur = CGPoint(x: o.x + n(), y: o.y + n()); p.addLine(to: cur)
            case "H":
                cur = CGPoint(x: o.x + n(), y: cur.y); p.addLine(to: cur)
            case "V":
                cur = CGPoint(x: cur.x, y: o.y + n()); p.addLine(to: cur)
            case "C":
                let c1 = CGPoint(x: o.x + n(), y: o.y + n()), c2 = CGPoint(x: o.x + n(), y: o.y + n())
                cur = CGPoint(x: o.x + n(), y: o.y + n()); p.addCurve(to: cur, control1: c1, control2: c2)
            case "Q":
                let c1 = CGPoint(x: o.x + n(), y: o.y + n())
                cur = CGPoint(x: o.x + n(), y: o.y + n()); p.addQuadCurve(to: cur, control: c1)
            case "A":
                let rx = n(), _ = n(), _ = n(), large = n() != 0, sweep = n() != 0
                let end = CGPoint(x: o.x + n(), y: o.y + n())
                arc(p, from: cur, to: end, r: rx, large: large, sweep: sweep)
                cur = end
            case "Z":
                p.closeSubpath(); cur = start
            default:
                i += 1
            }
            if cmd.uppercased() == "Z" && hasNum() { cmd = "L" }
        }
        return p
    }

    /// Circular SVG arc (rx == ry, no rotation) via the endpoint→centre conversion.
    private static func arc(_ p: CGMutablePath, from a: CGPoint, to b: CGPoint, r rIn: CGFloat, large: Bool, sweep: Bool) {
        let dx = (a.x - b.x) / 2, dy = (a.y - b.y) / 2
        let d2 = dx * dx + dy * dy
        guard d2 > 0 else { return }
        let r = max(rIn, sqrt(d2))
        var k = sqrt(max(0, (r * r - d2) / d2))
        if large == sweep { k = -k }
        let cx = k * dy + (a.x + b.x) / 2, cy = -k * dx + (a.y + b.y) / 2
        let t1 = atan2(a.y - cy, a.x - cx)
        var dt = atan2(b.y - cy, b.x - cx) - t1
        if sweep && dt < 0 { dt += 2 * .pi }
        if !sweep && dt > 0 { dt -= 2 * .pi }
        p.addRelativeArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: t1, delta: dt)
    }
}
