import Foundation
import Combine

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

struct Lyrics: Equatable {
    let lines: [LyricLine]
    let synced: Bool
}

// MARK: - Controller

@MainActor
final class LyricsController: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case ready(Lyrics)
        case notFound
    }

    @Published private(set) var state: State = .idle
    private var cache: [String: Lyrics] = [:]
    private var currentKey = ""
    private var task: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    init(player: NowPlaying) {
        player.$track
            .sink { [weak self] track in self?.load(track) }
            .store(in: &bag)
    }

    var statusText: String {
        switch state {
        case .idle: return "Waiting for a song"
        case .loading: return "Finding lyrics…"
        case .ready(let l): return l.synced ? "Synced lyrics ✓" : "Plain lyrics (not time-synced)"
        case .notFound: return "No lyrics found"
        }
    }

    private func load(_ track: NowPlaying.Track?) {
        guard let track else {
            currentKey = ""
            task?.cancel()
            state = .idle
            return
        }
        let key = "\(track.title)|\(track.artist)".lowercased()
        guard key != currentKey else { return }
        currentKey = key
        task?.cancel()

        if let cached = cache[key] {
            state = .ready(cached)
            return
        }
        state = .loading
        task = Task { [weak self] in
            let result = await LyricsService.fetch(title: track.title, artist: track.artist,
                                                   album: track.album, duration: track.duration)
            guard let self, !Task.isCancelled, self.currentKey == key else { return }
            if let result {
                self.cache[key] = result
                self.state = .ready(result)
            } else {
                self.state = .notFound
            }
        }
    }
}

// MARK: - LRCLIB (free, no API key)

private struct LrclibRecord: Decodable {
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    var parsed: Lyrics? {
        if instrumental == true {
            return Lyrics(lines: [LyricLine(id: 0, time: 0, text: "♪ Instrumental ♪")], synced: true)
        }
        if let s = syncedLyrics, !s.isEmpty {
            let lines = LRC.parse(s)
            if !lines.isEmpty { return Lyrics(lines: lines, synced: true) }
        }
        if let p = plainLyrics, !p.isEmpty {
            let texts = p.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !texts.isEmpty {
                return Lyrics(lines: texts.enumerated().map { LyricLine(id: $0.offset, time: 0, text: $0.element) },
                              synced: false)
            }
        }
        return nil
    }
}

enum LyricsService {
    private static let base = "https://lrclib.net/api"

    static func fetch(title: String, artist: String, album: String, duration: Double) async -> Lyrics? {
        let original = baseTitle(title)          // keeps "(From ...)" in case LRCLIB uses it
        let t = cleanTitle(title)                // "Tiger Muthuvel Pandian"
        let a = cleanArtist(artist)
        let lead = primaryArtist(artist)         // "Anirudh Ravichander"
        let dur = String(Int(duration.rounded()))

        // 1. Exact matches (need album + duration)
        if !album.isEmpty, duration > 0 {
            for (tt, aa) in [(original, a), (t, a), (t, lead)] {
                if let record: LrclibRecord = await request("get", [
                        "track_name": tt, "artist_name": aa, "album_name": album, "duration": dur]),
                   let lyrics = record.parsed, lyrics.synced {
                    return lyrics
                }
            }
        }
        // 2. Title + main artist
        if let list: [LrclibRecord] = await request("search", ["track_name": t, "artist_name": lead]),
           let best = pick(list, duration, strict: false) {
            return best
        }
        // 3. Title only, but the length must match so we don't grab a different song
        if duration > 0,
           let list: [LrclibRecord] = await request("search", ["track_name": t]),
           let best = pick(list, duration, strict: true) {
            return best
        }
        // 4. Free text
        if let list: [LrclibRecord] = await request("search", ["q": "\(t) \(lead)"]),
           let best = pick(list, duration, strict: false) {
            return best
        }
        return nil
    }

    private static func pick(_ list: [LrclibRecord], _ duration: Double, strict: Bool) -> Lyrics? {
        func close(_ r: LrclibRecord) -> Bool {
            guard duration > 0, let d = r.duration else { return !strict }
            return abs(d - duration) < 4
        }
        let candidates = strict ? list.filter(close) : list
        let synced = candidates.filter { ($0.syncedLyrics ?? "").isEmpty == false }
        if let r = synced.first(where: close), let l = r.parsed { return l }
        if let r = synced.first, let l = r.parsed { return l }
        if let r = candidates.first(where: { $0.parsed != nil }) { return r.parsed }
        return nil
    }

    private static func request<T: Decodable>(_ path: String, _ params: [String: String]) async -> T? {
        var comps = URLComponents(string: "\(base)/\(path)")!
        comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("LyricLock/1.0 (personal macOS lyrics overlay)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            return nil
        }
    }

    /// Removes only video noise like "(Official Video)" or "[Lyrics]".
    static func baseTitle(_ s: String) -> String {
        var out = s
        let noise = #"\s*[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|remaster|hd|4k|m/?v)[^\)\]]*[\)\]]"#
        out = out.replacingOccurrences(of: noise, with: "", options: [.regularExpression, .caseInsensitive])
        if let bar = out.range(of: " | ") { out = String(out[..<bar.lowerBound]) }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Also strips film credits and features: `Song (From "Film")` -> `Song`.
    static func cleanTitle(_ s: String) -> String {
        var out = baseTitle(s)
        let patterns = [
            #"\s*[\(\[]\s*(from|feat\.?|ft\.?|featuring)\b[^\)\]]*[\)\]]"#,
            #"\s+-\s+(from|feat\.?|ft\.?)\b.*$"#,
            #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#,
        ]
        for p in patterns {
            out = out.replacingOccurrences(of: p, with: "", options: [.regularExpression, .caseInsensitive])
        }
        out = out.trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? baseTitle(s) : out
    }

    static func cleanArtist(_ s: String) -> String {
        s.replacingOccurrences(of: " - Topic", with: "")
         .replacingOccurrences(of: "VEVO", with: "")
         .trimmingCharacters(in: .whitespaces)
    }

    /// First credited artist: "Anirudh Ravichander, M.S Krsna & Super Subu" -> "Anirudh Ravichander".
    static func primaryArtist(_ s: String) -> String {
        let cleaned = cleanArtist(s)
        let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: ",&"))
        var first = parts.first ?? cleaned
        for sep in [" x ", " X ", " feat", " ft.", " and "] {
            if let r = first.range(of: sep) { first = String(first[..<r.lowerBound]) }
        }
        first = first.trimmingCharacters(in: .whitespaces)
        return first.isEmpty ? cleaned : first
    }
}

// MARK: - LRC parser

enum LRC {
    private static let tag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
    private static let wordTag = #"<\d{1,3}:\d{1,2}(?:\.\d{1,3})?>"#

    static func parse(_ source: String) -> [LyricLine] {
        var entries: [(Double, String)] = []
        for raw in source.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = tag.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length)
                .replacingOccurrences(of: wordTag, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Double(ns.substring(with: m.range(at: 2))
                    .replacingOccurrences(of: ":", with: ".")) ?? 0
                entries.append((minutes * 60 + seconds, text))
            }
        }
        entries.sort { $0.0 < $1.0 }
        return entries.enumerated().map { LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}
