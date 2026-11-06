import SwiftUI
import LJCore

/// Canvas geometry (landscape, before the 90° rotation for the panel).
public enum Screen {
    public static let width: CGFloat = 1920
    public static let height: CGFloat = 462
    public static let size = CGSize(width: width, height: height)
    public static let nav: CGFloat = 104
    public static let content: CGFloat = 1196
    public static let rail: CGFloat = 620
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: alpha)
    }
}

/// v3 mockup `:root` palette.
enum Palette {
    static let pink = Color(hex: 0xff2eaa)
    static let blue = Color(hex: 0x4fb6ff)
    static let violet = Color(hex: 0x7b3cff)
    static let teal = Color(hex: 0x3ee6c9)
    static let gold = Color(hex: 0xffc93c)
    /// FiiO K7 DSD LED green (rate badge only).
    static let green = Color(hex: 0x5ef27a)
    static let bad = Color(hex: 0xff3b5c)
    static let text = Color(hex: 0xf1e6ff)
    static let muted = Color(hex: 0x9a86c4)
    static let ink = Color(hex: 0x12041c)
    static let white = Color.white
    static let line = Color(hex: 0x4fb6ff, alpha: 0.3)
}

/// The colours that differ between `jinx` (50/50 pink/blue) and `jinx-blue` (70 % blue).
struct ThemeStyle {
    /// Active nav tab fill and its glow.
    let hot: Color
    /// Section mark / accent used for the "✕" and stamps.
    let accent: Color

    static func of(_ t: Theme) -> ThemeStyle {
        switch t {
        case .jinx: ThemeStyle(hot: Palette.pink, accent: Palette.pink)
        case .jinxBlue: ThemeStyle(hot: Palette.blue, accent: Palette.pink)
        }
    }
}

/// Mockup `clip-path: polygon(c 0, 100% 0, 100% calc(100% - c), calc(100% - c) 100%, 0 100%, 0 c)`:
/// top-left and bottom-right corners cut at 45°.
struct ClippedCorners: InsettableShape {
    var cut: CGFloat
    var inset: CGFloat = 0

    func path(in r: CGRect) -> Path {
        let r = r.insetBy(dx: inset, dy: inset)
        let c = max(0, cut - inset * 0.414)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + c, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + c))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> ClippedCorners { ClippedCorners(cut: cut, inset: inset + amount) }
}

/// CSS `ease-out-cubic` used by the mockup: clamps to 0...1.
func easeOutCubic(_ x: Double) -> Double {
    x <= 0 ? 0 : x >= 1 ? 1 : 1 - pow(1 - x, 3)
}
