import AppKit
import SwiftUI

/// "Find Lyrics…" window: search LRCLIB and pick the right lyrics for the current song.
/// The choice is remembered for that song from then on.
@MainActor
final class LyricSearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [LrclibRecord] = []
    @Published private(set) var searching = false
    @Published private(set) var message: String?
    private let lyrics: LyricsController
    private let player: NowPlaying
    var onDone: (() -> Void)?

    init(lyrics: LyricsController, player: NowPlaying) {
        self.lyrics = lyrics
        self.player = player
    }

    var currentDuration: Double { player.track?.duration ?? 0 }

    func prefill() {
        if let t = player.track {
            query = "\(LyricsService.cleanTitle(t.title)) \(LyricsService.primaryArtist(t.artist))"
            search()
        }
    }

    func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        message = nil
        Task {
            let found = await LyricsService.search(q)
            // Synced first, then closest length to the song that's playing.
            let d = currentDuration
            self.results = found.sorted { a, b in
                if a.isSynced != b.isSynced { return a.isSynced }
                guard d > 0 else { return false }
                return abs((a.duration ?? 0) - d) < abs((b.duration ?? 0) - d)
            }
            self.searching = false
            if found.isEmpty { self.message = "Nothing found. Try fewer words, or just the song name." }
        }
    }

    func choose(_ r: LrclibRecord) {
        lyrics.choose(r)
        onDone?()
    }
}

struct LyricSearchView: View {
    @ObservedObject var model: LyricSearchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Find Lyrics")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Pick the right lyrics for the song that's playing. LyricLock remembers your choice.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Song name and artist", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.search() }
                Button("Search") { model.search() }
                    .keyboardShortcut(.defaultAction)
            }

            if model.searching {
                ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.top, 20)
            } else if let msg = model.message {
                Text(msg).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 20)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(model.results) { r in
                        Button { model.choose(r) } label: { row(r) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
    }

    private func row(_ r: LrclibRecord) -> some View {
        let d = model.currentDuration
        let close = d > 0 && abs((r.duration ?? 0) - d) < 4
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.trackName ?? "Untitled").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text([r.artistName, r.albumName].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if close {
                Text("same length").font(.system(size: 10, weight: .semibold)).foregroundStyle(.green)
            }
            Text(r.isSynced ? "Synced" : "Plain")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(r.isSynced ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.2)))
            Text(format(r.duration ?? 0))
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
    }

    private func format(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
