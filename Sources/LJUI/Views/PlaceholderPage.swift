import SwiftUI
import LJCore

/// Phase-1 page: Jinx section title (`.ttl`) + a big SVN-Road Rage headline + "coming soon".
/// Used by the Notifications and AI pages until their real pages land (Music has `MusicPage`).
struct PlaceholderPage: View {
    let title: String
    let eyebrow: String?
    let headline: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: title, small: "coming soon")
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 6) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.chakra(18, 600)).tracking(3)
                        .foregroundStyle(Palette.teal)
                        .lineLimit(1)
                }
                Text(headline)
                    .font(.display(64))
                    .foregroundStyle(Palette.white)
                    .lineLimit(1).truncationMode(.tail)
                    .shadow(color: Palette.pink.opacity(0.7), radius: 7)
                    .shadow(color: Palette.blue.opacity(0.35), radius: 15)
                if let detail {
                    Text(detail)
                        .font(.chakra(28, 600))
                        .foregroundStyle(Palette.blue)
                        .lineLimit(1).truncationMode(.tail)
                }
                Text("coming soon")
                    .font(.salt(26))
                    .foregroundStyle(Palette.pink)
                    .rotationEffect(.degrees(-3), anchor: .leading)
                    .padding(.top, 18)
            }
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 28, leading: 38, bottom: 28, trailing: 38))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Mockup `.ttl`: pink "✕" mark, blue SVN-Road Rage title with glow, muted small text.
struct SectionTitle: View {
    let title: String
    var small: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("✕")
                .font(.chakra(22, 700))
                .foregroundStyle(Palette.pink)
                .shadow(color: Palette.pink, radius: 4)
            Text(title)
                .font(.display(26))
                .foregroundStyle(Palette.blue)
                .shadow(color: Palette.blue.opacity(0.5), radius: 5)
            if let small {
                Text(small).font(.chakra(18, 500)).foregroundStyle(Palette.muted)
            }
        }
        .lineLimit(1)
    }
}
