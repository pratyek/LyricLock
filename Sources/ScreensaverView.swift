import SwiftUI

/// Full-screen "now playing" scene shown on top of the macOS screen saver while music plays:
/// blurred album art, a large clock, big animated lyrics and the song at the bottom.
struct ScreensaverView: View {
    @ObservedObject var player: NowPlaying
    @ObservedObject var lyrics: LyricsController
    @ObservedObject var settings = Settings.shared

    init(player: NowPlaying, lyrics: LyricsController) {
        self.player = player
        self.lyrics = lyrics
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                background
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                if let track = player.track {
                    VStack(spacing: 0) {
                        clock
                            .padding(.top, geo.size.height * 0.08)
                        Spacer(minLength: 20)
                        center(track, width: min(1240, geo.size.width * 0.82))
                        Spacer(minLength: 20)
                        footer(track)
                            .padding(.bottom, geo.size.height * 0.07)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                    .transition(.opacity)
                }
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.8), value: player.track)
    }

    // Static (not redrawn every frame), so the heavy blur costs nothing while lyrics animate.
    private var background: some View {
        let palette = player.palette
        return ZStack {
            Color.black
            if let art = player.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.35)
                    .blur(radius: 80)
                    .saturation(1.25)
                    .opacity(0.9)
            } else {
                ZStack {
                    Circle().fill(palette.primary).frame(width: 700, height: 700).offset(x: -300, y: -120)
                    Circle().fill(palette.secondary).frame(width: 600, height: 600).offset(x: 320, y: 160)
                }
                .blur(radius: 160)
                .opacity(0.5)
            }
            LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.55), Color.black.opacity(0.75)],
                           startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 1.2), value: palette)
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 4) {
                Text(ctx.date, format: .dateTime.hour().minute())
                    .font(.system(size: 92, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.92))
                Text(ctx.date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .shadow(color: .black.opacity(0.35), radius: 12, y: 3)
        }
    }

    @ViewBuilder
    private func center(_ track: NowPlaying.Track, width: CGFloat) -> some View {
        switch lyrics.state {
        case .ready(let l):
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !player.isPlaying)) { ctx in
                LyricStack(lyrics: l,
                           time: player.position(at: ctx.date) + settings.offset,
                           duration: track.duration,
                           palette: player.palette,
                           metrics: .screen,
                           font: settings.font,
                           glow: settings.glow,
                           romanize: settings.romanize,
                           showTranslation: settings.translate)
            }
            .frame(width: width, height: Metrics.screen.lyricsHeight)
        default:
            // No lyrics: a big, calm album cover instead.
            if let art = player.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 340, height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            }
        }
    }

    private func footer(_ track: NowPlaying.Track) -> some View {
        HStack(spacing: 18) {
            if let art = player.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(LyricsService.cleanTitle(track.title))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if !track.artist.isEmpty {
                    Text(LyricsService.primaryArtist(track.artist))
                        .font(.system(size: 17, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .lineLimit(1)
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying)) { ctx in
                EqualizerBars(time: ctx.date.timeIntervalSinceReferenceDate,
                              playing: player.isPlaying, color: player.palette.primary)
                    .scaleEffect(1.5, anchor: .bottom)
            }
            .frame(width: 24, height: 20)
            .padding(.leading, 6)
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 2)
    }
}
