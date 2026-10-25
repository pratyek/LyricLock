import SwiftUI

/// Fully transparent floating lyrics. On the desktop the area is draggable, a faint outline
/// appears on hover, and there are collapsible controls plus a queue sidebar.
/// On the lock screen it's display-only, with an optional soft album-colour aura.
struct LyricsView: View {
    @ObservedObject var player: NowPlaying
    @ObservedObject var lyrics: LyricsController
    @ObservedObject var queue: QueueReader
    @ObservedObject var settings = Settings.shared
    let interactive: Bool
    let mover: WindowMover?
    // Plain ObservableObject instead of @State: on newer SDKs @State is a macro whose
    // plugin only ships with full Xcode, not the Command Line Tools.
    @ObservedObject var hover: HoverState

    init(player: NowPlaying, lyrics: LyricsController, queue: QueueReader,
         interactive: Bool, mover: WindowMover?) {
        self.player = player
        self.lyrics = lyrics
        self.queue = queue
        self.interactive = interactive
        self.mover = mover
        self.hover = HoverState()   // created once per window, so it lives as long as the view
    }

    private var showQueue: Bool { interactive && queue.isOpen }

    var body: some View {
        ZStack(alignment: .top) {
            if let track = player.track {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !player.isPlaying)) { context in
                    // Sidebar is an overlay so the lyrics don't shift when it opens.
                    card(track, time: player.position(at: context.date))
                        .overlay(alignment: .topTrailing) {
                            if showQueue {
                                QueueSidebar(queue: queue, hover: hover, palette: player.palette,
                                             height: settings.size.lyricsHeight + 96)
                                    .offset(x: 290 + 18)
                                    .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                        }
                }
                .transition(.opacity)
            }
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeInOut(duration: 0.5), value: player.track)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: showQueue)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Card

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 24, style: .continuous) }

    private func card(_ track: NowPlaying.Track, time: Double) -> some View {
        let palette = player.palette
        let hovering = hover.card
        let hasLyrics: Bool = {
            switch lyrics.state {
            case .ready, .loading: return true
            case .notFound, .idle: return false
            }
        }()

        return VStack(spacing: 12) {
            header(track, time: time, palette: palette)

            if hasLyrics {
                Group {
                    switch lyrics.state {
                    case .ready(let l):
                        LyricStack(lyrics: l, time: time + settings.offset, duration: track.duration,
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
                controls(palette: palette, hovering: hovering)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(width: settings.size.cardWidth)
        // Transparent. A near-invisible fill keeps the whole area grabbable; on hover a faint
        // outline shows what you're about to drag.
        .background(shape.fill(Color.black.opacity(interactive ? (hovering ? 0.12 : 0.004) : 0)))
        .overlay(shape.strokeBorder(Color.white.opacity(hovering ? 0.14 : 0), lineWidth: 0.75))
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

    private func header(_ track: NowPlaying.Track, time: Double, palette: Palette) -> some View {
        HStack(spacing: 9) {
            if let art = player.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
            }
            Text(LyricsService.cleanTitle(track.title))
                .fontWeight(.bold)
                .foregroundStyle(.white.opacity(0.95))
            if !track.artist.isEmpty {
                Text(LyricsService.primaryArtist(track.artist))
                    .foregroundStyle(.white.opacity(0.6))
            }
            EqualizerBars(time: time, playing: player.isPlaying, color: palette.primary)
        }
        .lineLimit(1)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
    }

    // MARK: Controls

    private func controls(palette: Palette, hovering: Bool) -> some View {
        VStack(spacing: 4) {
            if settings.controlsExpanded {
                HStack(spacing: 20) {
                    ControlButton(id: "loop", hover: hover, symbol: "repeat.1", size: 12,
                                  active: player.loopEnabled, accent: palette.primary,
                                  help: "Repeat this song") {
                        player.loopEnabled.toggle()
                    }
                    ControlButton(id: "prev", hover: hover, symbol: "backward.fill", size: 14,
                                  help: "Previous") { player.previous() }
                    ControlButton(id: "play", hover: hover,
                                  symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 17,
                                  prominent: true, accent: palette.primary,
                                  help: player.isPlaying ? "Pause" : "Play") {
                        player.togglePlayPause()
                    }
                    ControlButton(id: "next", hover: hover, symbol: "forward.fill", size: 14,
                                  help: "Next") { player.next() }
                    ControlButton(id: "queue", hover: hover, symbol: "list.bullet", size: 12,
                                  active: queue.isOpen, accent: palette.primary,
                                  help: queue.isOpen ? "Hide queue" : "Show queue") {
                        queue.isOpen.toggle()
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                    settings.controlsExpanded.toggle()
                    if !settings.controlsExpanded { queue.isOpen = false }
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

/// Hover tracking shared by the card, its buttons and the queue rows.
@MainActor
final class HoverState: ObservableObject {
    @Published var card = false
    @Published var button: String?
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
                .frame(width: prominent ? 36 : 28, height: prominent ? 36 : 28)
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

// MARK: - Queue sidebar

struct QueueSidebar: View {
    @ObservedObject var queue: QueueReader
    @ObservedObject var hover: HoverState
    let palette: Palette
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("UP NEXT")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .tracking(1.8)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                ControlButton(id: "q-refresh", hover: hover, symbol: "arrow.clockwise", size: 10,
                              help: "Refresh queue") { queue.refresh() }
            }
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 290, height: height, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
    }

    @ViewBuilder
    private var content: some View {
        switch queue.status {
        case .needsPermission:
            message("LyricLock needs Accessibility access to read YouTube Music's queue.",
                    button: "Allow Access") { queue.requestPermission() }
        case .loading, .idle:
            BreathingDots(time: Date().timeIntervalSinceReferenceDate, color: palette.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            message("Couldn't find the queue. Open the player in YouTube Music (click the song at the bottom), then refresh.",
                    button: "Save Scan for Claude") { queue.saveScan() }
        case .ready:
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(queue.items) { item in
                        row(item).id(item.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.05),
                    .init(color: .black, location: 0.9),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .onAppear { scrollToCurrent(proxy) }
            .onChange(of: queue.items) { _, _ in scrollToCurrent(proxy) }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy) {
        guard let current = queue.items.first(where: \.isCurrent) else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.85)) {
            proxy.scrollTo(current.id, anchor: .top)
        }
    }

    private func row(_ item: QueueItem) -> some View {
        let key = "q-\(item.id)"
        let hovering = hover.button == key
        return Button { queue.play(item) } label: {
            HStack(spacing: 10) {
                Group {
                    if item.isCurrent {
                        EqualizerBars(time: Date().timeIntervalSinceReferenceDate, playing: true, color: palette.primary)
                    } else {
                        Text("\(item.id + 1)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
                .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(item.isCurrent ? palette.primary : .white.opacity(0.92))
                    if !item.artist.isEmpty {
                        Text(item.artist)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                Text(item.duration)
                    .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(item.isCurrent ? palette.primary.opacity(0.14) : Color.white.opacity(hovering ? 0.08 : 0))
            )
            .opacity(item.isPast ? 0.42 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Play \(item.title)")
        .onHover { inside in
            if inside { hover.button = key } else if hover.button == key { hover.button = nil }
        }
    }

    private func message(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Text(text)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Button(action: action) {
                Text(button)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(palette.primary.opacity(0.3)))
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.75))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Shows only the lines around the current one (2 above, 2 below). Rows keep their identity,
/// so when the line changes they glide up in one smooth spring instead of re-scrolling a
/// long list. Rendering 5 lines instead of the whole song is also what keeps it at 60 fps.
struct LyricStack: View {
    let lyrics: Lyrics
    let time: Double
    let duration: Double
    let palette: Palette
    let size: LyricSize
    let font: LyricFont

    private static let reach = 2

    var body: some View {
        let lines = lyrics.lines
        let raw = currentIndex(lines)
        let hasIntro = lyrics.synced && (lines.first?.time ?? 0) > 4
        let intro = raw < 0 && hasIntro
        let center = max(raw, 0)
        let lo = max(0, center - Self.reach)
        let hi = min(lines.count - 1, center + Self.reach)
        let progress = lineProgress(lines, raw)
        let rowHeight = size.fontSize * 1.3
        let padTop = Self.reach - (center - lo) - (intro ? 1 : 0)
        let padBottom = Self.reach - (hi - center)

        VStack(spacing: size.fontSize * 0.38) {
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
                    progress: line.id == raw ? progress : (line.id < raw ? 1 : 0),
                    karaoke: lyrics.synced,
                    time: time,
                    palette: palette,
                    size: size,
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
        .animation(.spring(response: 0.38, dampingFraction: 0.88), value: center)
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

    /// 0→1 across the sung part of the line. Fast lines (rap) fill as fast as the next line
    /// arrives; slow lines fill at a natural singing pace instead of crawling through gaps.
    private func lineProgress(_ lines: [LyricLine], _ index: Int) -> Double {
        guard lyrics.synced, index >= 0, index < lines.count else { return 0 }
        let start = lines[index].time
        let next = index + 1 < lines.count ? lines[index + 1].time : (duration > 0 ? duration : start + 5)
        let gap = max(next - start, 0.2)
        let natural = Double(lines[index].text.count) * 0.065 + 0.3
        let span = max(0.2, min(gap * 0.88, natural))
        let lead = 0.12   // highlight a hair early; feels in sync rather than late
        return min(max((time + lead - start) / span, 0), 1)
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
                    .opacity(isCurrent ? 1 : 0.3)
            } else if isCurrent && karaoke {
                WordLine(text: text, progress: progress, palette: palette)
            } else {
                Text(text).foregroundStyle(.white)
            }
        }
        .font(.system(size: size.fontSize, weight: font.weight, design: font.design))
        .tracking(font == .serif ? 0 : -0.3)
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
        .scaleEffect(isCurrent ? 1.0 : 0.8)
        .opacity(isCurrent ? 1 : max(0.12, 0.5 - d * 0.16))
        .blur(radius: isCurrent ? 0 : 1.0 + d * 0.9)
    }
}

/// Active line: each word brightens, lifts slightly and glows in the song's colour as it's sung.
struct WordLine: View {
    let text: String
    let progress: Double
    let palette: Palette

    var body: some View {
        let words = text.split(separator: " ").map(String.init)
        let weights = words.map { Double(max($0.count, 1)) + 1.0 }
        let total = weights.reduce(0, +)
        var bounds: [(Double, Double)] = []
        var acc = 0.0
        for w in weights {
            bounds.append((acc / total, (acc + w) / total))
            acc += w
        }

        return FlowLayout(spacing: 0.26, lineSpacing: 0) {
            ForEach(words.indices, id: \.self) { i in
                let a = bounds[i].0
                let b = bounds[i].1
                let linear = min(max((progress - a) / max(b - a, 0.001), 0), 1)
                let p = linear * linear * (3 - 2 * linear)        // smoothstep
                Text(words[i])
                    .foregroundStyle(Color.white.opacity(0.36 + 0.64 * p))
                    .shadow(color: palette.primary.opacity(0.75 * p), radius: 12)
                    .offset(y: -2.5 * p)
            }
        }
    }
}

/// Centered wrapping layout for words. `spacing` is a fraction of the word height.
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
