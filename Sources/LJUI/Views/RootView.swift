import SwiftUI
import LJCore

/// The whole 1920×462 frame: decor | nav (104) | page strip (1196) | rail (620).
///
/// Pure function of its inputs:
/// - `state`: the app state.
/// - `t`: animation clock, seconds since app start (wall clock) — drives stripes, tag wobble, flash,
///   and the Music page's EQ bars / beat pulse while playing.
/// - `now`: wall-clock date of this frame (= app start + `t`) — page-slide progress vs
///   `state.pageChangedAt`, nav date/clock, music seek position (`elapsedNow`).
/// - `rail`: glided bar fills + 2 Hz readouts from the frame loop's `RailGlide`; nil → state values.
public struct RootView: View {
    public let state: UiState
    public let t: TimeInterval
    public let now: Date
    public let rail: RailMotion?
    /// Decoded-artwork memo (the one non-input the view reads; it never changes what is drawn).
    let artwork: ArtworkCache

    public init(state: UiState, t: TimeInterval, now: Date = Date(), rail: RailMotion? = nil) {
        self.init(state: state, t: t, now: now, rail: rail, artwork: .shared)
    }

    /// Test seam: a private artwork cache.
    init(state: UiState, t: TimeInterval, now: Date = Date(), rail: RailMotion? = nil, artwork: ArtworkCache) {
        Fonts.register()
        self.state = state; self.t = t; self.now = now; self.rail = rail; self.artwork = artwork
    }

    public var body: some View {
        HStack(spacing: 0) {
            NavView(page: state.page, theme: state.theme, now: now)
            PageStrip(state: state, t: t, now: now, artwork: artwork)
            RailView(audio: state.audio, bluetooth: state.bluetooth, system: state.system, motion: rail, t: t)
        }
        .frame(width: Screen.width, height: Screen.height)
        .background(Image(decorative: Decor.image(state.theme), scale: 1))
        .environment(\.colorScheme, .dark)
    }
}

/// Strip of the three pages, 1196 px each; slides from `previousPage` to `page` over 0.5 s
/// (ease-out-cubic) from `pageChangedAt`. Only pages intersecting the viewport are built.
struct PageStrip: View {
    let state: UiState
    var t: TimeInterval = 0
    let now: Date
    var artwork: ArtworkCache = .shared

    /// Strip position in page units (0 = music … 2 = ai).
    static func position(_ s: UiState, now: Date) -> Double {
        let page = Double(s.page.rawValue)
        // A negative age (wall clock stepped back) counts as a finished slide.
        guard let at = s.pageChangedAt, now >= at else { return page }
        let e = easeOutCubic(now.timeIntervalSince(at) / Anim.pageSlide)
        let count = PageID.allCases.count
        let prev = Double((s.previousPage ?? PageID(rawValue: (s.page.rawValue + count - 1) % count)!).rawValue)
        return prev + (page - prev) * e
    }

    var body: some View {
        let pos = Self.position(state, now: now)
        ZStack(alignment: .topLeading) {
            ForEach(PageID.allCases.filter { abs(Double($0.rawValue) - pos) < 1 }, id: \.self) { p in
                page(p)
                    .frame(width: Screen.content, height: Screen.height)
                    .offset(x: (Double(p.rawValue) - pos) * Screen.content)
            }
        }
        .frame(width: Screen.content, height: Screen.height, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder private func page(_ p: PageID) -> some View {
        switch p {
        case .music:
            MusicPage(music: state.music, audio: state.audio, focus: state.musicFocus, t: t, now: now, artwork: artwork)
        case .notifications:
            PlaceholderPage(title: "Notifications", eyebrow: nil, headline: "Notifications", detail: nil)
        case .ai:
            PlaceholderPage(title: "AI usage", eyebrow: nil, headline: "AI usage", detail: nil)
        }
    }
}
