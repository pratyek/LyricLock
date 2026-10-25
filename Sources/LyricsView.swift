import SwiftUI

/// Fully transparent floating lyrics. On the desktop the area is draggable, a faint outline
/// and a resize grip appear on hover, and there are collapsible playback controls.
/// On the lock screen it's display-only, with an optional soft album-colour aura.
struct LyricsView: View {
    @ObservedObject var player: NowPlaying
    @ObservedObject var lyrics: LyricsController
    @ObservedObject var settings = Settings.shared
    let interactive: Bool
    let mover: WindowMover?
    // Plain ObservableObject instead of @State: on newer SDKs @State is a macro whose
    // plugin only ships with full Xcode, not the Command Line Tools.
    @ObservedObject var hover: HoverState

    init(player: NowPlaying, lyrics: LyricsController, interactive: Bool, mover: WindowMover?) {
        self.player = player
        self.lyrics = lyrics
        self.interactive = interactive
        self.mover = mover
        self.hover = HoverState()   // created once per window, so it lives as long as the view
    }

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
        .animation(.easeInOut(duration: 0.5), value: player.track)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Card

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 24, style: .continuous) }

    private func card(_ track: NowPlaying.Track, time: Double) -> some View {
        let palette = player.palette
        let m = settings.metrics
        let hovering = hover.card || hover.resizeStart != nil
        let hasLyrics: Bool = {
            switch lyrics.state {
            case .ready, .loading: return true
            case .notFound, .idle: return false
            }
        }()

        return VStack(spacing: 12 * m.scale) {
            header(track, time: time, palette: palette, metrics: m)

            if hasLyrics {
                Group {
                    switch lyrics.state {
                    case .ready(let l):
                        LyricStack(lyrics: l, time: time + settings.offset, duration: track.duration,
                                   palette: palette, metrics: m, font: settings.font)
                    default:
                        BreathingDots(time: Date().timeIntervalSinceReferenceDate, color: palette.primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: m.lyricsHeight)
                .transition(.opacity)
            }

            if interactive {
                controls(palette: palette, hovering: hovering, scale: m.scale)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(width: m.cardWidth)
        // Transparent. A near-invisible fill keeps the whole area grabbable; on hover a faint
        // outline shows what you're about to drag.
        .background(shape.fill(Color.black.opacity(interactive ? (hovering ? 0.12 : 0.004) : 0)))
        .overlay(shape.strokeBorder(Color.white.opacity(hovering ? 0.14 : 0), lineWidth: 0.75))
        .overlay(alignment: .bottomTrailing) {
            if interactive { resizeGrip(visible: hovering) }
        }
        .background(aura(palette))
        .contentShape(shape)
        .onHover { hover.card = interactive && $0 }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { _ in mover?.drag() }
                .onEnded { _ in mover?.end() },
            including: interactive ? .all : .subviews
        )
        .opacity(player.isPlaying ? 1 : 0.7)
        .animation(.easeInOut(duration: 0.5), value: player.isPlaying)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: hasLyrics)
        .animation(.easeOut(duration: 0.2), value: hovering)
    }

    /// Drag the bottom-right corner to make the lyrics any size.
    private func resizeGrip(visible: Bool) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(visible ? 0.6 : 0))
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
            .padding(6)
            .help("Drag to resize")
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if hover.resizeStart == nil { hover.resizeStart = settings.scale }
                        let start = hover.resizeStart ?? settings.scale
                        // The card grows around its centre, so its right edge moves half the width change.
                        let delta = (value.translation.width + value.translation.height * 0.6) / 330
                        settings.scale = min(max(start + delta, Metrics.minScale), Metrics.maxScale)
                    }
                    .onEnded { _ in hover.resizeStart = nil }
            )
    }

    @ViewBuilder
    private func aura(_ palette: Palette) -> some View {
        if !interactive && settings.lockAura {
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

    private func header(_ track: NowPlaying.Track, time: Double, palette: Palette, metrics m: Metrics) -> some View {
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
        }
        .lineLimit(1)
        .font(.system(size: pt, weight: .semibold, design: .rounded))
        .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
    }

    // MARK: Controls

    private func controls(palette: Palette, hovering: Bool, scale: Double) -> some View {
        let s = max(0.85, min(scale, 1.3))
        return VStack(spacing: 4) {
            if settings.controlsExpanded {
                HStack(spacing: 20 * s) {
                    ControlButton(id: "loop", hover: hover, symbol: "repeat.1", size: 12 * s,
                                  active: player.loopEnabled, accent: palette.primary,
                                  help: "Repeat this song") {
                        player.loopEnabled.toggle()
                    }
                    ControlButton(id: "prev", hover: hover, symbol: "backward.fill", size: 14 * s,
                                  help: "Previous") { player.previous() }
                    ControlButton(id: "play", hover: hover,
                                  symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 17 * s,
                                  prominent: true, accent: palette.primary,
                                  help: player.isPlaying ? "Pause" : "Play") {
                        player.togglePlayPause()
                    }
                    ControlButton(id: "next", hover: hover, symbol: "forward.fill", size: 14 * s,
                                  help: "Next") { player.next() }
                    ControlButton(id: "queue", hover: hover, symbol: "list.bullet", size: 12 * s,
                                  help: "Open YouTube Music") { player.openPlayer() }
                }
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                    settings.controlsExpanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 18, weight: .medium))
                    .rotationEffect(.degrees(settings.controlsExpanded ? 180 : 0))
                    .foregroundStyle(.white.opacity(hovering ? 0.7 : 0.22))
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .frame(width: 60, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(settings.controlsExpanded ? "Hide controls" : "Show controls")
        }
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
                .shadow(color: accent.opacity(active ? 0.7 : 0), radius: 8)
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

/// Shows the lines around the current one (2 above, 2 below). Rows keep their identity, so
/// on each new line they glide up together in one spring while the new line brightens and
/// grows into focus. Drawing 5 lines instead of the whole song keeps it at 60 fps.
struct LyricStack: View {
    let lyrics: Lyrics
    let time: Double
    let duration: Double
    let palette: Palette
    let metrics: Metrics
    let font: LyricFont

    private static let reach = 2
    /// Switch lines a hair early so it feels in sync rather than late.
    private static let lead = 0.15

    var body: some View {
        let lines = lyrics.lines
        let raw = currentIndex(lines)
        let hasIntro = lyrics.synced && (lines.first?.time ?? 0) > 4
        let intro = raw < 0 && hasIntro
        let center = max(raw, 0)
        let lo = max(0, center - Self.reach)
        let hi = min(lines.count - 1, center + Self.reach)
        let rowHeight = metrics.fontSize * 1.3
        let padTop = Self.reach - (center - lo) - (intro ? 1 : 0)
        let padBottom = Self.reach - (hi - center)

        VStack(spacing: metrics.fontSize * 0.38) {
            ForEach(0..<max(padTop, 0), id: \.self) { _ in Color.clear.frame(height: rowHeight) }
            if intro {
                BreathingDots(time: time, color: palette.primary)
                    .frame(height: rowHeight)
                    .transition(.opacity)
            }
            ForEach(Array(lines[lo...hi])) { line in
                LyricLineView(
                    text: line.text,
                    distance: line.id - center + (intro ? 1 : 0),
                    time: time,
                    palette: palette,
                    metrics: metrics,
                    font: font
                )
                .id(line.id)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: rowHeight * 0.6)),
                    removal: .opacity.combined(with: .offset(y: -rowHeight * 0.6))
                ))
            }
            ForEach(0..<max(padBottom, 0), id: \.self) { _ in Color.clear.frame(height: rowHeight) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.42, dampingFraction: 0.82), value: center)
        .animation(.easeInOut(duration: 0.35), value: intro)
        .mask(
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.22),
                .init(color: .black, location: 0.78),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
        )
        .clipped()
    }

    private func currentIndex(_ lines: [LyricLine]) -> Int {
        guard !lines.isEmpty else { return 0 }
        let t = time + Self.lead
        if !lyrics.synced {
            guard duration > 0 else { return 0 }
            return min(lines.count - 1, max(0, Int(t / duration * Double(lines.count))))
        }
        var lo = 0, hi = lines.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }
}

/// One lyric line. The current line is bright with a soft glow in the song's colour;
/// the others are smaller, faded and slightly blurred. All changes animate with the stack.
struct LyricLineView: View {
    let text: String
    let distance: Int
    let time: Double
    let palette: Palette
    let metrics: Metrics
    let font: LyricFont

    private var isInstrumental: Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t == "♪" || t == "♫"
    }

    var body: some View {
        let isCurrent = distance == 0
        let d = Double(abs(distance))

        Group {
            if isInstrumental {
                BreathingDots(time: time, color: palette.primary)
                    .opacity(isCurrent ? 1 : 0.3)
            } else {
                Text(text)
                    .foregroundStyle(.white)
                    .shadow(color: palette.primary.opacity(isCurrent ? 0.55 : 0), radius: 16)
            }
        }
        .font(.system(size: metrics.fontSize, weight: font.weight, design: font.design))
        .tracking(font == .serif ? 0 : -0.3)
        .lineLimit(2)
        .minimumScaleFactor(0.8)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
        .scaleEffect(isCurrent ? 1.0 : 0.8)
        .opacity(isCurrent ? 1 : max(0.12, 0.5 - d * 0.16))
        .blur(radius: isCurrent ? 0 : 1.0 + d * 0.9)
    }
}
