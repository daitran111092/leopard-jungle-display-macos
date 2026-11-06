import SwiftUI
import LJCore

/// Left nav (104 px): rotated date, three page tabs, clock. Mockup `.nav`.
struct NavView: View {
    let page: PageID
    let theme: Theme
    let now: Date

    private static let icons: [PageID: String] = [.music: "music.note", .notifications: "bell.fill", .ai: "bolt.fill"]

    var body: some View {
        let style = ThemeStyle.of(theme)
        ZStack {
            VStack(spacing: 22) {
                ForEach(PageID.allCases, id: \.self) { p in
                    tab(p, on: p == page, style: style)
                }
            }
            VStack {
                Text(Self.date(now))
                    .font(.display(18))
                    .foregroundStyle(Palette.pink)
                    .rotationEffect(.degrees(-4))
                    .padding(.top, 18)
                Spacer()
                Text(Self.clock(now))
                    .font(.chakra(22, 600))
                    .tracking(1)
                    .foregroundStyle(Palette.blue)
                    .padding(.bottom, 18)
            }
        }
        .frame(width: Screen.nav, height: Screen.height)
        .overlay(alignment: .trailing) {
            // border-right: 2px dotted rgba(79,182,255,.35)
            Path { p in p.move(to: CGPoint(x: 1, y: 0)); p.addLine(to: CGPoint(x: 1, y: Screen.height)) }
                .stroke(Palette.blue.opacity(0.35), style: StrokeStyle(lineWidth: 2, dash: [2, 2]))
                .frame(width: 2)
        }
    }

    @ViewBuilder private func tab(_ p: PageID, on: Bool, style: ThemeStyle) -> some View {
        let icon = Image(systemName: Self.icons[p]!).font(.system(size: 28, weight: .semibold))
        if on {
            icon.foregroundStyle(Palette.ink)
                .frame(width: 64, height: 64)
                .background(ClippedCorners(cut: 8).fill(style.hot))
                .background(ClippedCorners(cut: 8).fill(style.hot.opacity(0.8)).blur(radius: 9))
        } else {
            icon.foregroundStyle(Palette.muted).frame(width: 64, height: 64)
        }
    }

    private static let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]

    /// "NOV 4" in the local time zone.
    static func date(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(months[(c.month ?? 1) - 1]) \(c.day ?? 1)"
    }

    /// "09:12" (24 h) in the local time zone.
    static func clock(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
