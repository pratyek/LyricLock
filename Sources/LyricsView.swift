import SwiftUI

/// Fully transparent floating lyrics, used on the desktop and on the lock screen.
/// Hover reveals the quiet extras (outline, collapse button, controls chevron, resize grip).
/// Scroll to look back through the lyrics, click a line to jump there, pinch or drag the
/// corner to resize. Collapsed, it shrinks to a single line with just play/pause.
struct LyricsView: View {
    enum Place { case desktop, lockScreen }

    @ObservedObject var player: NowPlaying
    @ObservedObject var lyrics: LyricsController
    @ObservedObject var settings = Settings.shared
    @ObservedObject var hover: HoverState
    @ObservedObject var browse: BrowseState
    let place: Place
    let mover: WindowMover?

    init(player: NowPlaying, lyrics: LyricsController, place: Place, mover: WindowMover?) {
        self.player = player
        self.lyrics = lyrics
        self.place = place
        self.mover = mover
        // Plain ObservableObjects instead of @State: on newer SDKs @State is a macro whose
        // plugin only ships with full Xcode, not the Command Line Tools.
        self.hover = HoverState()
        self.browse = mover?.browse ?? BrowseState()
    }

    private var isDesktop: Bool { place == .desktop }

    var body: some View {
        ZStack(alignment: .top) {
            if let track = player.track {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !player.isPlaying)) { context in
                    card(track, time: player.position(at: context.date))
                }
                .transition(.opacity)
            }
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Tell the window where the card is, so it only takes clicks there.
        .onPreferenceChange(CardFrameKey.self) { [mover] rect in
            Task { @MainActor in mover?.cardRect = rect }
        }
        .animation(.easeInOut(duration: 0.5), value: player.track)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: settings.collapsed)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Card

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 24, style: .continuous) }

    private func card(_ track: NowPlaying.Track, time: Double) -> some View {
        let palette = player.palette
        let m = settings.metrics
        let hovering = hover.card || hover.resizeStart != nil
        let collapsed = settings.collapsed
        let hasLyrics: Bool = {
            switch lyrics.state {
            case .ready, .loading: return true
            case .notFound, .idle: return false
            }
        }()

        return VStack(spacing: 12 * m.scale) {
            header(track, time: time, palette: palette, metrics: m, collapsed: collapsed)

            if hasLyrics && !collapsed {
                Group {
                    switch lyrics.state {
                    case .ready(let l):
                        LyricStack(lyrics: l, time: time + settings.offset, duration: track.duration,
                                   palette: palette, metrics: m, font: settings.font,
                                   glow: settings.glow, romanize: settings.romanize,
                                   showTranslation: settings.translate,
                                   browseOffset: browse.offset,
                                   onTap: { line in
                                       browse.reset()
                                       player.seek(to: max(0, line.time - 0.05))
                                   },
                                   onLive: { browse.setRange(live: $0, count: $1) })
                    default:
                        BreathingDots(time: Date().timeIntervalSinceReferenceDate, color: palette.primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: m.lyricsHeight)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }

            if !collapsed {
                controls(track: track, palette: palette, hovering: hovering, scale: m.scale)
            }
        }
        .padding(.horizontal, collapsed ? 18 : 24)
        .padding(.vertical, collapsed ? 10 : 14)
        .frame(width: collapsed ? nil : m.cardWidth)
        // Transparent. A near-invisible fill keeps the area clickable; on hover a faint
        // outline shows what you're about to drag.
        .background(shape.fill(Color.black.opacity(hovering ? 0.12 : 0.004)))
        .overlay(shape.strokeBorder(Color.white.opacity(hovering ? 0.14 : 0), lineWidth: 0.75))
        .overlay(alignment: .topTrailing) {
            if !collapsed { collapseButton(collapsed: false, visible: hovering).padding(8) }
        }
        .overlay(alignment: .bottomTrailing) {
            if !collapsed { resizeGrip(visible: hovering) }
        }
        .background(aura(palette))
        .background(GeometryReader { g in
            Color.clear.preference(key: CardFrameKey.self, value: g.frame(in: .global))
        })
        .contentShape(shape)
        .onHover { hover.card = $0 }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { _ in mover?.drag() }
                .onEnded { _ in mover?.end() },
            including: .all
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if hover.resizeStart == nil { hover.resizeStart = settings.scale }
                    mover?.isInteracting = true
                    let start = hover.resizeStart ?? settings.scale
                    settings.scale = Metrics.clamp(start * value.magnification)
                }
                .onEnded { _ in hover.resizeStart = nil; mover?.isInteracting = false },
            including: .all
        )
        .opacity(player.isPlaying ? 1 : 0.75)
        .animation(.easeInOut(duration: 0.5), value: player.isPlaying)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: hasLyrics)
        .animation(.easeOut(duration: 0.2), value: hovering)
    }

    /// Hover-only button in the top-right corner: collapse to one line, or expand back.
    private func collapseButton(collapsed: Bool, visible: Bool) -> some View {
        Button {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { settings.collapsed.toggle() }
        } label: {
            Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(visible ? 0.7 : 0))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(visible ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show lyrics" : "Collapse")
        .allowsHitTesting(visible)
    }

    /// Drag the bottom-right corner to resize (pinch on the trackpad works too).
    private func resizeGrip(visible: Bool) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(visible ? 0.65 : 0))
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
            .help("Drag to resize")
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if hover.resizeStart == nil { hover.resizeStart = settings.scale }
                        mover?.isInteracting = true
                        let start = hover.resizeStart ?? settings.scale
                        // The card grows around its centre, so its corner moves half the width change.
                        let delta = (value.translation.width - value.translation.height * 0.5) / 330
                        settings.scale = Metrics.clamp(start + delta)
                    }
                    .onEnded { _ in hover.resizeStart = nil; mover?.isInteracting = false }
            )
    }

    @ViewBuilder
    private func aura(_ palette: Palette) -> some View {
        if place == .lockScreen && settings.lockAura && settings.glow {
            ZStack {
                Circle().fill(palette.primary).frame(width: 300, height: 300).offset(x: -150, y: 10)
                Circle().fill(palette.secondary).frame(width: 260, height: 260).offset(x: 160, y: 40)
            }
            .blur(radius: 100)
            .opacity(0.3)
            .allowsHitTesting(false)
        }
    }

    // MARK: Header

    private func header(_ track: NowPlaying.Track, time: Double, palette: Palette,
                        metrics m: Metrics, collapsed: Bool) -> some View {
        let pt = settings.titleSize.points * max(0.8, m.scale)
        return HStack(spacing: pt * 0.65) {
            if let art = player.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: pt * 1.9, height: pt * 1.9)
                    .clipShape(RoundedRectangle(cornerRadius: pt * 0.42, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
            }
            Text(LyricsService.cleanTitle(track.title))
                .fontWeight(.bold)
                .foregroundStyle(.white.opacity(0.96))
            if !track.artist.isEmpty {
                Text(LyricsService.primaryArtist(track.artist))
                    .foregroundStyle(.white.opacity(0.62))
            }
            EqualizerBars(time: time, playing: player.isPlaying, color: palette.primary)
                .scaleEffect(pt / 13, anchor: .center)
                .padding(.leading, 2)
            if collapsed {
                ControlButton(id: "mini-play", hover: hover,
                              symbol: player.isPlaying ? "pause.fill" : "play.fill", size: pt * 0.95,
                              prominent: true, accent: palette.primary, glow: settings.glow,
                              help: player.isPlaying ? "Pause" : "Play") {
                    player.togglePlayPause()
                }
                .padding(.leading, 4)
                .transition(.scale.combined(with: .opacity))
                // Expand button tucks in only while you hover.
                collapseButton(collapsed: true, visible: hover.card)
                    .frame(width: hover.card ? 22 : 0)
                    .clipped()
            }
        }
        .lineLimit(1)
        .font(.system(size: pt, weight: .semibold, design: .rounded))
        .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
    }

    // MARK: Controls

    private func controls(track: NowPlaying.Track, palette: Palette, hovering: Bool, scale: Double) -> some View {
        let s = max(0.85, min(scale, 1.3))
        return VStack(spacing: 4) {
            if settings.controlsExpanded {
                HStack(spacing: 18 * s) {
                    ControlButton(id: "loop", hover: hover, symbol: "repeat.1", size: 12 * s,
                                  active: player.loopEnabled, accent: palette.primary, glow: settings.glow,
                                  help: "Repeat this song") {
                        player.loopEnabled.toggle()
                    }
                    ControlButton(id: "prev", hover: hover, symbol: "backward.fill", size: 14 * s,
                                  help: "Previous") { player.previous() }
                    ControlButton(id: "play", hover: hover,
                                  symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 17 * s,
                                  prominent: true, accent: palette.primary, glow: settings.glow,
                                  help: player.isPlaying ? "Pause" : "Play") {
                        player.togglePlayPause()
                    }
                    ControlButton(id: "next", hover: hover, symbol: "forward.fill", size: 14 * s,
                                  help: "Next") { player.next() }
                    if isDesktop {
                        ControlButton(id: "share", hover: hover, symbol: "square.and.arrow.up", size: 12 * s,
                                      help: "Save this lyric as an image") { shareCurrentLine(track) }
                        ControlButton(id: "queue", hover: hover, symbol: "list.bullet", size: 12 * s,
                                      help: "Open YouTube Music") { player.openPlayer() }
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Hidden until you hover, so it never spoils the look.
            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                    settings.controlsExpanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 18, weight: .medium))
                    .rotationEffect(.degrees(settings.controlsExpanded ? 180 : 0))
                    .foregroundStyle(.white.opacity(hovering ? 0.7 : 0))
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .frame(width: 60, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .allowsHitTesting(hovering)
            .help(settings.controlsExpanded ? "Hide controls" : "Show controls")
        }
    }

    private func shareCurrentLine(_ track: NowPlaying.Track) {
        guard let l = lyrics.currentLyrics else { NSSound.beep(); return }
        let i = l.index(at: player.position(at: Date()) + settings.offset + LyricStack.lead, duration: track.duration)
        let line = l.lines[max(i, 0)].display(romanize: settings.romanize)
        ShareCard.save(line: line, title: LyricsService.cleanTitle(track.title),
                       artist: LyricsService.primaryArtist(track.artist),
                       artwork: player.artwork, palette: player.palette, font: settings.font)
    }
}

/// Hover and resize tracking shared by the card and its buttons.
@MainActor
final class HoverState: ObservableObject {
    @Published var card = false
    @Published var button: String?
    @Published var resizeStart: Double?
}

struct ControlButton: View {
    let id: String
    @ObservedObject var hover: HoverState
    let symbol: String
    var size: CGFloat = 14
    var active = false
    var prominent = false
    var accent: Color = .white
    var glow = true
    var help: String = ""
    let action: () -> Void
    private var hovering: Bool { hover.button == id }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? accent : .white.opacity(hovering ? 1 : 0.82))
                .frame(width: size * (prominent ? 2.15 : 2.0), height: size * (prominent ? 2.15 : 2.0))
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : (prominent ? 0.06 : 0))))
                .shadow(color: accent.opacity(active && glow ? 0.7 : 0), radius: 8)
                .scaleEffect(hovering ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { inside in
            if inside { hover.button = id } else if hover.button == id { hover.button = nil }
        }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Small animated pieces

/// Tiny animated bars that bounce while music plays and settle when paused.
struct EqualizerBars: View {
    let time: Double
    let playing: Bool
    var color: Color = .white

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<4, id: \.self) { i in
                let speed = 3.1 + Double(i) * 0.8
                let height = playing ? 3 + 9 * abs(sin(time * speed + Double(i) * 1.4)) : 3
                Capsule().frame(width: 2.5, height: height)
            }
        }
        .frame(height: 12, alignment: .bottom)
        .foregroundStyle(color.opacity(0.9))
    }
}

/// Three dots that softly breathe, used for intros, instrumental breaks and loading.
struct BreathingDots: View {
    let time: Double
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<3, id: \.self) { i in
                let phase = (sin(time * 2.6 - Double(i) * 0.7) + 1) / 2
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .scaleEffect(0.65 + 0.45 * phase)
                    .opacity(0.35 + 0.65 * phase)
            }
        }
        .frame(height: 36)
    }
}

// MARK: - Lyric lines

/// Shows the lines around the focused one (2 above, 2 below). Rows keep their identity, so
/// on each new line they glide up together in one spring while the new line brightens and
/// grows into focus. Scrolling shifts the focus to look back; it returns to live by itself.
struct LyricStack: View {
    let lyrics: Lyrics
    let time: Double
    let duration: Double
    let palette: Palette
    let metrics: Metrics
    let font: LyricFont
    var glow = true
    var romanize = false
    var showTranslation = false
    var browseOffset = 0
    var onTap: ((LyricLine) -> Void)? = nil
    /// Reports (live line, line count) so scrolling can stop at the ends.
    var onLive: ((Int, Int) -> Void)? = nil

    private static let reach = 2
    /// Switch lines a hair early so it feels in sync rather than late.
    static let lead = 0.15

    var body: some View {
        let lines = lyrics.lines
        let live = lyrics.index(at: time + Self.lead, duration: duration)
        let hasIntro = lyrics.synced && (lines.first?.time ?? 0) > 4
        let browsing = browseOffset != 0
        let intro = live < 0 && hasIntro && !browsing
        let focus = min(max(max(live, 0) + browseOffset, 0), lines.count - 1)
        let lo = max(0, focus - Self.reach)
        let hi = min(lines.count - 1, focus + Self.reach)
        let rowHeight = metrics.fontSize * 1.3
        let padTop = Self.reach - (focus - lo) - (intro ? 1 : 0)
        let padBottom = Self.reach - (hi - focus)

        VStack(spacing: metrics.fontSize * 0.38) {
            ForEach(0..<max(padTop, 0), id: \.self) { _ in Color.clear.frame(height: rowHeight) }
            if intro {
                BreathingDots(time: time, color: palette.primary)
                    .frame(height: rowHeight)
                    .transition(.opacity)
            }
            ForEach(Array(lines[lo...hi])) { line in
                LyricLineView(
                    text: line.display(romanize: romanize),
                    translation: showTranslation ? line.translation : nil,
                    distance: line.id - focus + (intro ? 1 : 0),
                    isLive: line.id == live,
                    browsing: browsing,
                    time: time,
                    palette: palette,
                    metrics: metrics,
                    font: font,
                    glow: glow
                )
                .contentShape(Rectangle())
                .onTapGesture { onTap?(line) }
                .id(line.id)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: rowHeight * 0.6)),
                    removal: .opacity.combined(with: .offset(y: -rowHeight * 0.6))
                ))
            }
            ForEach(0..<max(padBottom, 0), id: \.self) { _ in Color.clear.frame(height: rowHeight) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: focus)
        .animation(.easeInOut(duration: 0.35), value: intro)
        .onChange(of: live, initial: true) { _, value in onLive?(value, lines.count) }
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.2),
                .init(color: .black, location: 0.8),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
        .clipped()
    }
}

/// One lyric line. The focused line is bright (with a glow in the song's colour when it's
/// the live line); the others are smaller, faded and slightly blurred.
struct LyricLineView: View {
    let text: String
    let translation: String?
    let distance: Int
    let isLive: Bool
    let browsing: Bool
    let time: Double
    let palette: Palette
    let metrics: Metrics
    let font: LyricFont
    let glow: Bool

    private var isInstrumental: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == "♪" || t == "♫"
    }

    var body: some View {
        let focused = distance == 0
        let d = Double(abs(distance))
        let glowing = glow && isLive

        VStack(spacing: metrics.fontSize * 0.12) {
            if isInstrumental {
                BreathingDots(time: time, color: palette.primary)
                    .opacity(focused ? 1 : 0.3)
            } else {
                Text(text)
                    .font(font.font(size: metrics.fontSize))
                    .tracking(font.tracking)
                    .foregroundStyle(.white)
                    .shadow(color: palette.primary.opacity(glowing ? 0.55 : 0), radius: 16)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                if let translation, focused {
                    Text(translation)
                        .font(.system(size: metrics.fontSize * 0.45, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                        .transition(.opacity)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
        .scaleEffect(focused ? 1.0 : 0.8)
        // While browsing, mark the live line with a little extra brightness so you can find it.
        .opacity(focused ? 1 : (isLive && browsing ? 0.75 : max(0.12, 0.5 - d * 0.16)))
        .blur(radius: focused ? 0 : 1.0 + d * 0.9)
    }
}

/// The lyrics card's frame inside its window.
struct CardFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n.width > 0 { value = n }
    }
}
