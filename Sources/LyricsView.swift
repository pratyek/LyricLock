import SwiftUI

/// Transparent floating lyrics: no card, no progress bar. Soft shadows keep the
/// text readable on any wallpaper.
struct LyricsView: View {
    @ObservedObject var player: NowPlaying
    @ObservedObject var lyrics: LyricsController
    @ObservedObject var settings = Settings.shared

    var body: some View {
        ZStack {
            if let track = player.track {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying)) { context in
                    content(track, time: player.position(at: context.date))
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.5), value: player.track)
        .environment(\.colorScheme, .dark)
    }

    private func content(_ track: NowPlaying.Track, time: Double) -> some View {
        VStack(spacing: 14) {
            header(track, time: time)

            Group {
                switch lyrics.state {
                case .ready(let l):
                    LyricScroller(lyrics: l, time: time + settings.offset, duration: track.duration)
                case .loading:
                    placeholder("finding lyrics…")
                case .notFound, .idle:
                    placeholder("no lyrics for this one")
                }
            }
            .frame(height: 270)
        }
        .padding(.horizontal, 24)
        .opacity(player.isPlaying ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.5), value: player.isPlaying)
    }

    private func header(_ track: NowPlaying.Track, time: Double) -> some View {
        HStack(spacing: 10) {
            EqualizerBars(time: time, playing: player.isPlaying)
            Text(track.title.uppercased())
                .fontWeight(.bold)
            if !track.artist.isEmpty {
                Text(track.artist.uppercased())
                    .opacity(0.6)
            }
        }
        .lineLimit(1)
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .tracking(1.8)
        .foregroundStyle(.white.opacity(0.8))
        .shadow(color: .black.opacity(0.55), radius: 6, y: 1)
        .frame(maxWidth: 760)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 22, weight: .medium, design: .rounded))
            .italic()
            .foregroundStyle(.white.opacity(0.55))
            .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Tiny animated bars that bounce while music plays and settle when paused.
struct EqualizerBars: View {
    let time: Double
    let playing: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<4, id: \.self) { i in
                let speed = 3.1 + Double(i) * 0.8
                let height = playing ? 3 + 9 * abs(sin(time * speed + Double(i) * 1.4)) : 3
                Capsule().frame(width: 2.5, height: height)
            }
        }
        .frame(height: 12, alignment: .bottom)
        .foregroundStyle(.white.opacity(0.85))
    }
}

// MARK: - Scrolling lyric list

struct LyricScroller: View {
    let lyrics: Lyrics
    let time: Double
    let duration: Double

    var body: some View {
        let lines = lyrics.lines
        let index = currentIndex(lines)
        let progress = lineProgress(lines, index)

        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 18) {
                    Color.clear.frame(height: 100)
                    ForEach(lines) { line in
                        LyricLineView(
                            text: line.text,
                            distance: line.id - index,
                            progress: line.id == index ? progress : (line.id < index ? 1 : 0),
                            karaoke: lyrics.synced
                        )
                        .id(line.id)
                    }
                    Color.clear.frame(height: 100)
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)
            .scrollDisabled(true)
            .mask(
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.3),
                    .init(color: .black, location: 0.7),
                    .init(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            )
            .onAppear { proxy.scrollTo(max(index, 0), anchor: .center) }
            .onChange(of: index) { _, newIndex in
                withAnimation(.spring(response: 0.65, dampingFraction: 0.82)) {
                    proxy.scrollTo(max(newIndex, 0), anchor: .center)
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

    var body: some View {
        let isCurrent = distance == 0
        let d = Double(abs(distance))
        let display = text.isEmpty ? "♪" : text

        ZStack {
            Text(display)
                .foregroundStyle(.white.opacity(isCurrent && karaoke ? 0.38 : 1))
            if isCurrent && karaoke {
                Text(display)
                    .foregroundStyle(
                        LinearGradient(colors: [.white, Color(white: 0.92)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .black, location: progress),
                            .init(color: .clear, location: min(1, progress + 0.07)),
                        ], startPoint: .leading, endPoint: .trailing)
                    )
            }
        }
        .font(.system(size: 36, weight: .heavy))
        .tracking(-0.4)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        // legibility on bright wallpapers + soft glow on the active line
        .shadow(color: .black.opacity(0.55), radius: 10, y: 3)
        .shadow(color: .white.opacity(isCurrent ? 0.28 : 0), radius: 18)
        .scaleEffect(isCurrent ? 1.0 : 0.78)
        .opacity(isCurrent ? 1 : max(0.1, 0.5 - d * 0.13))
        .blur(radius: isCurrent ? 0 : min(d * 1.1, 4))
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: isCurrent)
    }
}
