import SwiftUI
import LJCore

/// Music page (content area 1196 × 462), v3 mockup "Màn 1 · Music": artwork | meta (source line with EQ
/// bars, title, artist, album, seek bar, times, ⏮ ⏯ ⏭ controls). `music == nil` → "Nothing playing".
/// Right of the artist / album lines: the output's sample-rate badge (`RateBadge`), hidden when the rate is unknown.
///
/// Pure function of its inputs (`t` drives EQ bars / beat pulse / art sway while playing; `now` drives the
/// seek position via `elapsedNow`). Paused draws nothing that depends on `t`. Artwork bytes are decoded
/// through `ArtworkCache` (memoised, never per frame).
struct MusicPage: View {
    let music: NowPlaying?
    /// Current output device; only its sample rate / bit depth are read (badge).
    let audio: AudioOutput?
    let focus: MusicFocus
    let t: TimeInterval
    let now: Date
    let artwork: ArtworkCache

    init(music: NowPlaying?, audio: AudioOutput? = nil, focus: MusicFocus, t: TimeInterval, now: Date) {
        self.init(music: music, audio: audio, focus: focus, t: t, now: now, artwork: .shared)
    }

    init(music: NowPlaying?, audio: AudioOutput? = nil, focus: MusicFocus, t: TimeInterval, now: Date, artwork: ArtworkCache) {
        self.music = music; self.audio = audio; self.focus = focus; self.t = t; self.now = now; self.artwork = artwork
    }

    static let artSize: CGFloat = 340

    var body: some View {
        Group {
            if let music { playing(music) } else { idle }
        }
        .padding(EdgeInsets(top: 30, leading: 38, bottom: 30, trailing: 38))
        .frame(width: Screen.content, height: Screen.height, alignment: .leading)
    }

    // MARK: - Layout

    private func playing(_ m: NowPlaying) -> some View {
        let beat = m.playing ? Self.beat(t) : 0
        return HStack(alignment: .center, spacing: 40) {
            ArtBox(image: m.artwork.flatMap { artwork.image(for: $0) }, title: m.title, app: m.appName)
                .rotationEffect(.degrees(Self.artTilt(t: t, playing: m.playing)))
                .scaleEffect(Self.artScale(t: t, playing: m.playing))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .bottom, spacing: 10) {
                    EqBars(heights: Self.eqHeights(t: t, playing: m.playing))
                    Text("\(m.playing ? "Now playing" : "Paused") · \(m.appName)".uppercased())
                        .font(.chakra(18, 600)).tracking(3)
                        .foregroundStyle(Palette.teal)
                        .lineLimit(1)
                }
                Text(m.title)
                    .font(.display(62))
                    .foregroundStyle(Palette.white)
                    .lineLimit(1).truncationMode(.tail)
                    .shadow(color: Palette.pink.opacity(0.7), radius: 7)
                    .shadow(color: Palette.blue.opacity(0.35), radius: 15)
                    .padding(.top, 6).padding(.bottom, 2)
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !m.artist.isEmpty {
                            Text(m.artist)
                                .font(.chakra(28, 600))
                                .foregroundStyle(Palette.blue)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        if !m.album.isEmpty {
                            Text(m.album)
                                .font(.chakra(20, 500))
                                .foregroundStyle(Palette.muted)
                                .lineLimit(1).truncationMode(.tail)
                                .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let rate = audio?.sampleRate {
                        RateBadge(sampleRate: rate, bitDepth: audio?.bitDepth)
                    }
                }
                SeekBar(progress: Self.progress(m, now: now))
                    .padding(.top, 26).padding(.bottom, 8)
                HStack {
                    Text(fmtTime(elapsedNow(m, at: now))).foregroundStyle(Palette.white)
                    Spacer()
                    Text(m.duration > 0 ? fmtTime(m.duration) : "--:--").foregroundStyle(Palette.muted)
                }
                .font(.chakra(20, 600)).monospacedDigit()
                Controls(playing: m.playing, focus: focus, beat: beat)
                    .padding(.top, 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var idle: some View {
        HStack(alignment: .center, spacing: 40) {
            ArtBox(image: nil, title: "", app: nil)
                .compositingGroup()
                .opacity(0.4)
                .rotationEffect(.degrees(-2))
            VStack(alignment: .leading, spacing: 10) {
                Text("Nothing playing")
                    .font(.display(64))
                    .foregroundStyle(Palette.white)
                    .lineLimit(1)
                    .shadow(color: Palette.pink.opacity(0.7), radius: 7)
                    .shadow(color: Palette.blue.opacity(0.35), radius: 15)
                Text("Play something in Music or Spotify")
                    .font(.chakra(24, 500))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Motion (pure)

    /// Beat, 0…1: the mockup's tempo (`|sin(t·π·1.33)|`, 80 bpm) with a softer curve (`^3`, the mockup's `^6`
    /// looked snappy once the panel got every frame at 60 fps).
    nonisolated static func beat(_ t: TimeInterval) -> Double { pow(abs(sin(t * .pi * 1.33)), 3) }

    /// EQ bar speed relative to the mockup (slowed: at a true 60 fps the mockup's speed read as hurried).
    nonisolated static let eqSpeed = 0.7

    /// Art scale: `1 + beat·1.5 %` while playing, 1 when paused.
    nonisolated static func artScale(t: TimeInterval, playing: Bool) -> Double { playing ? 1 + beat(t) * 0.015 : 1 }

    /// Art tilt (degrees): −2° with a slow ±0.8° sway while playing; fixed −2° when paused.
    nonisolated static func artTilt(t: TimeInterval, playing: Bool) -> Double { playing ? -2 + sin(t * 0.9) * 0.8 : -2 }

    /// The five EQ bar heights (px, 5…20): mockup `5 + 15·|sin(t·eqSpeed·(3.1 + 1.3i) + 1.7i)|` while playing,
    /// frozen low when paused.
    nonisolated static func eqHeights(t: TimeInterval, playing: Bool) -> [CGFloat] {
        guard playing else { return [6, 9, 5, 8, 6] }
        return (0..<5).map { i in
            let d = Double(i)
            return CGFloat(5 + 15 * abs(sin(t * eqSpeed * (3.1 + d * 1.3) + d * 1.7)))
        }
    }

    /// Seek fraction 0…1 from `elapsedNow`; 0 when the duration is unknown.
    nonisolated static func progress(_ m: NowPlaying, now: Date) -> Double {
        guard m.duration > 0 else { return 0 }
        return min(1, max(0, elapsedNow(m, at: now) / m.duration))
    }

    /// Big word on the fallback art: the title without a trailing "(…)" / " - …" part, uppercased.
    nonisolated static func artTitle(_ title: String) -> String {
        var s = title
        if let r = s.range(of: " ("), r.lowerBound > s.startIndex { s = String(s[..<r.lowerBound]) }
        if let r = s.range(of: " - ") ?? s.range(of: " — "), r.lowerBound > s.startIndex { s = String(s[..<r.lowerBound]) }
        return s.trimmingCharacters(in: .whitespaces).uppercased()
    }
}

// MARK: - Pieces

/// `.art`: 3 px pink border, pink glow, 8 px blue offset shadow; artwork or the gradient + title fallback.
private struct ArtBox: View {
    let image: CGImage?
    let title: String
    let app: String?

    var body: some View {
        let side = MusicPage.artSize
        ZStack {
            Palette.blue.offset(x: 8, y: 8)
            Palette.pink.shadow(color: Palette.pink.opacity(0.55), radius: 12)
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().interpolation(.medium)
                        .scaledToFill()
                } else {
                    fallback
                }
            }
            .frame(width: side - 6, height: side - 6)
            .clipped()
        }
        .frame(width: side, height: side)
    }

    private var fallback: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hex: 0x2a0b4a), Color(hex: 0x0b1a4a)], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(hex: 0xff6ac9), Color(hex: 0xff6ac9, alpha: 0)],
                           center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 0.45 * 334 * 1.2)
            RadialGradient(colors: [Palette.blue, Palette.blue.opacity(0)],
                           center: UnitPoint(x: 0.75, y: 0.7), startRadius: 0, endRadius: 0.5 * 334 * 1.2)
            if !title.isEmpty {
                Text(MusicPage.artTitle(title))
                    .font(.display(96))
                    .foregroundStyle(Palette.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(3).minimumScaleFactor(0.35)
                    .shadow(color: Palette.ink, radius: 0, x: 4, y: 4)
                    .shadow(color: Palette.pink, radius: 9)
                    .frame(width: 300, height: 260)
                    .rotationEffect(.degrees(-8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let app, !app.isEmpty {
                Text(app.uppercased())
                    .font(.chakra(18, 600))
                    .foregroundStyle(Palette.white)
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.black.opacity(0.45))
                    .padding(.leading, 12).padding(.top, 10)
            }
        }
    }
}

/// Sample-rate / bit-depth badge in the FiiO K7 LED colour (`RateBadge.color`), Audio output block style, 34 px.
struct RateBadge: View {
    let sampleRate: Double
    let bitDepth: Int?
    var isDSD = false

    static let height: CGFloat = 34

    /// K7 LED: ≤ 48 kHz cyan → teal, hi-res yellow → gold, DSD green.
    static func color(_ c: RateClass) -> Color {
        switch c {
        case .standard: Palette.teal
        case .hiRes: Palette.gold
        case .dsd: Palette.green
        }
    }

    var body: some View {
        let color = Self.color(rateClass(sampleRate: sampleRate, isDSD: isDSD))
        Text(fmtAudioFormat(sampleRate: sampleRate, bitDepth: bitDepth))
            .font(.chakra(20, 700))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: Self.height)
            .outBlockStyle(color)
            .fixedSize()
    }
}

/// `.eq`: five 5 px teal bars with a teal glow, bottom-aligned in a 20 px box.
private struct EqBars: View {
    let heights: [CGFloat]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(heights.indices, id: \.self) { i in
                Palette.teal.frame(width: 5, height: heights[i])
            }
        }
        .frame(height: 20, alignment: .bottom)
        .shadow(color: Palette.teal, radius: 3)
    }
}

/// `.seek`: 16 px track, blue → pink fill with a pink glow, white diamond knob with a 4 px pink border.
private struct SeekBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { g in
            let x = g.size.width * CGFloat(progress)
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.1))
                Rectangle()
                    .fill(LinearGradient(colors: [Palette.blue, Palette.pink], startPoint: .leading, endPoint: .trailing))
                    .frame(width: x)
                    .shadow(color: Palette.pink.opacity(0.6), radius: 7)
                Rectangle()
                    .fill(Palette.white)
                    .overlay(Rectangle().strokeBorder(Palette.pink, lineWidth: 4))
                    .frame(width: 30, height: 30)
                    .rotationEffect(.degrees(45))
                    .shadow(color: Palette.pink, radius: 7)
                    .position(x: x, y: g.size.height / 2)
            }
        }
        .frame(height: 16)
    }
}

/// `.ctl`: clipped-corner buttons; play is pink filled (glow pulses with the beat while playing);
/// the focused control gets a 3 px dashed blue outline 4 px outside.
private struct Controls: View {
    let playing: Bool
    let focus: MusicFocus
    let beat: Double

    var body: some View {
        HStack(spacing: 22) {
            button("backward.end.fill", width: 76, size: 26, hot: false, focused: focus == .prev)
            button(playing ? "pause.fill" : "play.fill", width: 110, size: 32, hot: true, focused: focus == .play)
            button("forward.end.fill", width: 76, size: 26, hot: false, focused: focus == .next)
        }
    }

    private func button(_ symbol: String, width: CGFloat, size: CGFloat, hot: Bool, focused: Bool) -> some View {
        let shape = ClippedCorners(cut: 10)
        return Image(systemName: symbol)
            .font(.system(size: size, weight: .bold))
            .foregroundStyle(hot ? Palette.ink : Palette.text)
            .frame(width: width, height: 64)
            .background {
                if hot {
                    shape.fill(Palette.pink)
                        .shadow(color: Palette.pink.opacity(0.55 + beat * 0.4), radius: (14 + beat * 22) / 2)
                }
            }
            .overlay { shape.strokeBorder(hot ? Palette.pink : Palette.line, lineWidth: 2) }
            .overlay {
                if focused {
                    ClippedCorners(cut: 12)
                        .stroke(Palette.blue, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                        .padding(-5.5)
                }
            }
    }
}
