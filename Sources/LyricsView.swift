import SwiftUI

/// Translucent glass card tinted with the song's colours. On the desktop it is draggable and
/// has collapsible playback controls; on the lock screen it is display-only with an optional
/// soft album-colour aura behind it.
struct LyricsView: View {
    @ObservedObject var player: NowPlaying
    @ObservedObject var lyrics: LyricsController
    @ObservedObject var settings = Settings.shared
    let interactive: Bool
    let mover: WindowMover?
    // Plain ObservableObject instead of @State: on newer SDKs @State is a macro whose
    // plugin only ships with full Xcode, not the Command Line Tools.
    @ObservedObject var hover: HoverState
    private var hovering: Bool { hover.card }

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
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying)) { context in
                    card(track, time: player.position(at: context.date))
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .padding(.top, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.5), value: player.track)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Card

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 30, style: .continuous) }

    private func card(_ track: NowPlaying.Track, time: Double) -> some View {
        let palette = player.palette
        let hasLyrics: Bool = {
            switch lyrics.state {
            case .ready, .loading: return true
            case .notFound, .idle: return false
            }
        }()

        return VStack(spacing: 14) {
            header(track, time: time, palette: palette)

            if hasLyrics {
                Group {
                    switch lyrics.state {
                    case .ready(let l):
                        LyricScroller(lyrics: l, time: time + settings.offset, duration: track.duration,
                                      palette: palette, size: settings.size, font: settings.font)
                    default:
                        BreathingDots(time: Date().timeIntervalSinceReferenceDate, color: palette.primary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(height: settings.size.lyricsHeight)
                .transition(.opacity)
            }

            if interactive {
                controls(palette: palette)
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 20)
        .padding(.bottom, interactive ? 10 : 20)
        .frame(width: settings.size.cardWidth)
        .background(glass(palette))
        .overlay(shape.strokeBorder(Color.white.opacity(hovering ? 0.26 : 0.09), lineWidth: 1))
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
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: hasLyrics)
        .animation(.easeOut(duration: 0.2), value: hovering)
    }

    private func glass(_ palette: Palette) -> some View {
        ZStack {
            shape.fill(.ultraThinMaterial).opacity(0.78)
            shape.fill(
                LinearGradient(colors: [palette.tint.opacity(0.55), Color.black.opacity(0.28)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            // faint top highlight, like light hitting glass
            shape.fill(
                LinearGradient(colors: [Color.white.opacity(0.07), .clear],
                               startPoint: .top, endPoint: .center)
            )
        }
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
    }

    @ViewBuilder
    private func aura(_ palette: Palette) -> some View {
        if !interactive && settings.lockAura {
            ZStack {
                Circle().fill(palette.primary).frame(width: 340, height: 340).offset(x: -170, y: -10)
                Circle().fill(palette.secondary).frame(width: 300, height: 300).offset(x: 180, y: 30)
            }
            .blur(radius: 90)
            .opacity(0.45)
            .allowsHitTesting(false)
        }
    }

    // MARK: Header

    private func header(_ track: NowPlaying.Track, time: Double, palette: Palette) -> some View {
        HStack(spacing: 10) {
            if let art = player.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
            }
            Text(LyricsService.cleanTitle(track.title))
                .fontWeight(.bold)
                .foregroundStyle(.white.opacity(0.92))
            if !track.artist.isEmpty {
                Text(LyricsService.primaryArtist(track.artist))
                    .foregroundStyle(.white.opacity(0.55))
            }
            EqualizerBars(time: time, playing: player.isPlaying, color: palette.primary)
        }
        .lineLimit(1)
        .font(.system(size: 13, weight: .semibold, design: .rounded))
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
    }

    // MARK: Controls

    private func controls(palette: Palette) -> some View {
        VStack(spacing: 6) {
            if settings.controlsExpanded {
                HStack(spacing: 26) {
                    ControlButton(id: "loop", hover: hover, symbol: "repeat.1", size: 15,
                                  active: player.loopEnabled, accent: palette.primary,
                                  help: "Repeat this song") {
                        player.loopEnabled.toggle()
                    }
                    ControlButton(id: "prev", hover: hover, symbol: "backward.fill", size: 18, help: "Previous") { player.previous() }
                    ControlButton(id: "play", hover: hover, symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 22,
                                  prominent: true, accent: palette.primary,
                                  help: player.isPlaying ? "Pause" : "Play") {
                        player.togglePlayPause()
                    }
                    ControlButton(id: "next", hover: hover, symbol: "forward.fill", size: 18, help: "Next") { player.next() }
                    ControlButton(id: "queue", hover: hover, symbol: "list.bullet", size: 15,
                                  help: "Open YouTube Music to see the queue") { player.openPlayer() }
                }
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                    settings.controlsExpanded.toggle()
                }
            } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 20, weight: .medium))
                    .rotationEffect(.degrees(settings.controlsExpanded ? 180 : 0))
                    .foregroundStyle(.white.opacity(hovering ? 0.75 : 0.3))
                    .frame(width: 60, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(settings.controlsExpanded ? "Hide controls" : "Show controls")
        }
    }
}

/// Hover tracking shared by the card and its buttons.
@MainActor
final class HoverState: ObservableObject {
    @Published var card = false
    @Published var button: String?
}

struct ControlButton: View {
    let id: String
    @ObservedObject var hover: HoverState
    let symbol: String
    var size: CGFloat = 17
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
                .foregroundStyle(active ? accent : .white.opacity(hovering ? 1 : 0.8))
                .frame(width: prominent ? 46 : 32, height: prominent ? 46 : 32)
                .background(
                    Circle().fill(Color.white.opacity(prominent ? (hovering ? 0.22 : 0.14) : (hovering ? 0.1 : 0)))
                )
                .overlay(
                    Circle().strokeBorder(accent.opacity(prominent ? 0.35 : 0), lineWidth: 1)
                )
                .shadow(color: accent.opacity(active ? 0.6 : 0), radius: 8)
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
        .shadow(color: color.opacity(0.6), radius: 4)
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
                    .frame(width: 11, height: 11)
                    .scaleEffect(0.65 + 0.45 * phase)
                    .opacity(0.35 + 0.65 * phase)
                    .shadow(color: color.opacity(0.7 * phase), radius: 8)
            }
        }
        .frame(height: 40)
    }
}

// MARK: - Scrolling lyric list

struct LyricScroller: View {
    let lyrics: Lyrics
    let time: Double
    let duration: Double
    let palette: Palette
    let size: LyricSize
    let font: LyricFont

    private static let introID = -1

    var body: some View {
        let lines = lyrics.lines
        let hasIntro = lyrics.synced && (lines.first?.time ?? 0) > 4
        let raw = currentIndex(lines)
        let index = raw >= 0 ? raw : (hasIntro ? Self.introID : 0)
        let progress = lineProgress(lines, raw)

        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: size.fontSize * 0.5) {
                    Color.clear.frame(height: size.lyricsHeight * 0.38)
                    if hasIntro {
                        BreathingDots(time: time, color: palette.primary)
                            .opacity(index == Self.introID ? 1 : 0)
                            .id(Self.introID)
                    }
                    ForEach(lines) { line in
                        LyricLineView(
                            text: line.text,
                            distance: line.id - max(index, 0) + (index == Self.introID ? 1 : 0),
                            progress: line.id == index ? progress : (line.id < index ? 1 : 0),
                            karaoke: lyrics.synced,
                            time: time,
                            palette: palette,
                            size: size,
                            font: font
                        )
                        .id(line.id)
                    }
                    Color.clear.frame(height: size.lyricsHeight * 0.38)
                }
                .padding(.horizontal, 6)
            }
            .scrollIndicators(.never)
            .scrollDisabled(true)
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.28),
                    .init(color: .black, location: 0.72),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .onAppear { proxy.scrollTo(index, anchor: .center) }
            .onChange(of: index) { _, newIndex in
                withAnimation(.spring(response: 0.7, dampingFraction: 0.84)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func currentIndex(_ lines: [LyricLine]) -> Int {
        guard !lines.isEmpty else { return 0 }
        if !lyrics.synced {
            guard duration > 0 else { return 0 }
            return min(lines.count - 1, max(0, Int(time / duration * Double(lines.count))))
        }
        var lo = 0, hi = lines.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= time { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    private func lineProgress(_ lines: [LyricLine], _ index: Int) -> Double {
        guard lyrics.synced, index >= 0, index < lines.count else { return 0 }
        let start = lines[index].time
        let next = index + 1 < lines.count ? lines[index + 1].time : (duration > 0 ? duration : start + 5)
        // Sweep at roughly singing speed rather than across long instrumental gaps.
        let singing = Double(lines[index].text.count) * 0.085 + 0.6
        let span = max(0.3, min(next - start, singing))
        return min(max((time - start) / span, 0), 1)
    }
}

struct LyricLineView: View {
    let text: String
    let distance: Int
    let progress: Double
    let karaoke: Bool
    let time: Double
    let palette: Palette
    let size: LyricSize
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
                    .opacity(isCurrent ? 1 : 0.25)
            } else if isCurrent && karaoke {
                WordLine(text: text, progress: progress, palette: palette)
            } else {
                Text(text).foregroundStyle(.white)
            }
        }
        .font(.system(size: size.fontSize, weight: font.weight, design: font.design))
        .tracking(font == .serif ? 0 : -0.4)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
        .scaleEffect(isCurrent ? 1.0 : 0.8)
        .opacity(isCurrent ? 1 : max(0.1, 0.48 - d * 0.13))
        .blur(radius: isCurrent ? 0 : min(1.2 + d * 0.9, 4.5))
        .offset(y: isCurrent ? 0 : (distance < 0 ? -4 : 4))
        .animation(.spring(response: 0.6, dampingFraction: 0.8), value: isCurrent)
    }
}

/// Active line: each word lifts slightly, brightens and glows in the song's colour as it's sung.
struct WordLine: View {
    let text: String
    let progress: Double
    let palette: Palette

    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        let weights = words.map { Double(max($0.count, 1)) + 1.5 }
        let total = weights.reduce(0, +)
        var bounds: [(Double, Double)] = []
        var acc = 0.0
        for w in weights {
            bounds.append((acc / total, (acc + w) / total))
            acc += w
        }

        return FlowLayout(spacing: 0.27, lineSpacing: 2) {
            ForEach(words.indices, id: \.self) { i in
                let a = bounds[i].0
                let b = bounds[i].1
                let p = min(max((progress - a) / max(b - a, 0.001), 0), 1)
                let pop = sin(p * .pi)                          // peaks mid-word
                Text(words[i])
                    .foregroundStyle(Color.white.opacity(0.34 + 0.66 * p))
                    .shadow(color: palette.primary.opacity(0.85 * p), radius: 14)
                    .shadow(color: palette.primary.opacity(0.4 * pop), radius: 4)
                    .scaleEffect(1 + 0.05 * pop, anchor: .bottom)
                    .offset(y: -3 * p - 2 * pop)
            }
        }
    }
}

/// Centered wrapping layout for words. `spacing` is a fraction of the font's line height.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(bounds.width, subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for i in row.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - s.height) / 2),
                                  proposal: ProposedViewSize(s))
                x += s.width + gap(s)
            }
            y += row.height + lineSpacing
        }
    }

    private func gap(_ s: CGSize) -> CGFloat { s.height * spacing }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? s.width : row.width + gap(s) + s.width
            if needed > maxWidth, !row.items.isEmpty {
                rows.append(row)
                row = Row(items: [i], width: s.width, height: s.height)
            } else {
                row.items.append(i)
                row.width = needed
                row.height = max(row.height, s.height)
            }
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
