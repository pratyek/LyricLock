import Foundation
import Combine

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
    /// Latin-letter version for non-Latin scripts (e.g. Tamil → "karuppan varanda").
    var romanized: String? = nil
    /// English translation, when available on this Mac.
    var translation: String? = nil

    /// What to display, honouring the Romanize setting.
    func display(romanize: Bool) -> String { romanize ? (romanized ?? text) : text }
}

struct Lyrics: Equatable {
    var lines: [LyricLine]
    let synced: Bool

    /// Index of the line playing at `time` (-1 before the first synced line).
    func index(at time: Double, duration: Double) -> Int {
        guard !lines.isEmpty else { return 0 }
        if !synced {
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

    /// Adds romanized text to lines written in non-Latin scripts. Uses macOS's built-in
    /// transliteration (ICU), fully offline.
    func romanizedCopy() -> Lyrics {
        var copy = self
        for i in copy.lines.indices {
            let t = copy.lines[i].text
            guard Lyrics.needsRomanizing(t) else { continue }
            let latin = t.applyingTransform(.toLatin, reverse: false)?
                .applyingTransform(.stripCombiningMarks, reverse: false)
            copy.lines[i].romanized = latin
        }
        return copy
    }

    static func needsRomanizing(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isAlphabetic && $0.value > 0x024F }
    }

    var hasNonLatin: Bool { lines.contains { $0.romanized != nil } }
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
    @Published private(set) var translationNote: String?
    private var cache: [String: Lyrics] = [:]
    private(set) var currentKey = ""
    private var currentTrack: NowPlaying.Track?
    private var task: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()
    private static let overridesKey = "lyricsOverrides"

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

    var currentLyrics: Lyrics? {
        if case .ready(let l) = state { return l }
        return nil
    }

    private static func key(_ t: NowPlaying.Track) -> String { "\(t.title)|\(t.artist)".lowercased() }

    private func load(_ track: NowPlaying.Track?) {
        guard let track else {
            currentKey = ""
            currentTrack = nil
            task?.cancel()
            translateTask?.cancel()
            state = .idle
            return
        }
        let key = Self.key(track)
        guard key != currentKey else { return }
        currentKey = key
        currentTrack = track
        task?.cancel()
        translateTask?.cancel()
        translationNote = nil

        if let cached = cache[key] {
            publish(cached, key: key)
            return
        }
        state = .loading
        let overrideID = (UserDefaults.standard.dictionary(forKey: Self.overridesKey) as? [String: Int])?[key]
        task = Task { [weak self] in
            var result: Lyrics?
            if let id = overrideID { result = await LyricsService.fetch(id: id) }
            if result == nil {
                result = await LyricsService.fetch(title: track.title, artist: track.artist,
                                                   album: track.album, duration: track.duration)
            }
            guard let self, !Task.isCancelled, self.currentKey == key else { return }
            if let result {
                self.publish(result, key: key)
            } else {
                self.state = .notFound
            }
        }
    }

    private func publish(_ raw: Lyrics, key: String) {
        let lyrics = raw.romanizedCopy()
        cache[key] = lyrics
        state = .ready(lyrics)
        if Settings.shared.translate { translateCurrent() }
    }

    /// Use a lyrics result the person picked by hand, and remember it for this song.
    func choose(_ record: LrclibRecord) {
        guard !currentKey.isEmpty, let parsed = record.parsed else { return }
        var overrides = (UserDefaults.standard.dictionary(forKey: Self.overridesKey) as? [String: Int]) ?? [:]
        overrides[currentKey] = record.id
        UserDefaults.standard.set(overrides, forKey: Self.overridesKey)
        task?.cancel()
        translateTask?.cancel()
        publish(parsed, key: currentKey)
    }

    /// Fetch English translations for the current lyrics (Apple's on-device translator).
    func translateCurrent() {
        guard case .ready(let lyrics) = state, lyrics.lines.allSatisfy({ $0.translation == nil }) else { return }
        let key = currentKey
        translateTask?.cancel()
        translateTask = Task { [weak self] in
            let outcome = await LyricTranslator.translate(lyrics.lines.map(\.text))
            guard let self, !Task.isCancelled, self.currentKey == key else { return }
            switch outcome {
            case .translated(let texts):
                var copy = lyrics
                for i in copy.lines.indices where i < texts.count { copy.lines[i].translation = texts[i] }
                self.cache[key] = copy
                self.state = .ready(copy)
                self.translationNote = nil
            case .alreadyEnglish:
                self.translationNote = nil
            case .needsDownload(let language):
                self.translationNote = "Translation: download \(language) → English in System Settings › General › Language & Region › Translation Languages"
            case .unavailable(let reason):
                self.translationNote = "Translation: \(reason)"
            }
        }
    }

    func clearTranslations() {
        translateTask?.cancel()
        translationNote = nil
        guard case .ready(var lyrics) = state else { return }
        for i in lyrics.lines.indices { lyrics.lines[i].translation = nil }
        cache[currentKey] = lyrics
        state = .ready(lyrics)
    }
}

// MARK: - LRCLIB (free, no API key)

struct LrclibRecord: Decodable, Identifiable, Equatable {
    let id: Int
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let instrumental: Bool?
    let plainLyrics: String?
    let syncedLyrics: String?

    var isSynced: Bool { !(syncedLyrics ?? "").isEmpty }

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

    /// A specific record by its LRCLIB id (used for lyrics the person picked by hand).
    static func fetch(id: Int) async -> Lyrics? {
        let record: LrclibRecord? = await request("get/\(id)", [:])
        return record?.parsed
    }

    /// Free-text search for the "Find Lyrics" window.
    static func search(_ query: String) async -> [LrclibRecord] {
        let list: [LrclibRecord]? = await request("search", ["q": query])
        return list ?? []
    }

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
        if !params.isEmpty { comps.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) } }
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
    /// Keeps duo names like "She & Him" or "Simon & Garfunkel" intact when there's no comma.
    static func primaryArtist(_ s: String) -> String {
        let cleaned = cleanArtist(s)
        var first = cleaned.components(separatedBy: ",").first ?? cleaned
        for sep in [" x ", " X ", " feat", " ft.", " Feat", " Ft."] {
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
