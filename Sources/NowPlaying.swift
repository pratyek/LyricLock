import AppKit
import SwiftUI

/// Reads the system "Now Playing" info (what Control Center shows) via the open-source
/// `media-control` CLI, and sends playback commands back through it. This works for the
/// YouTube Music Safari web app because Safari publishes its media session to the system.
@MainActor
final class NowPlaying: ObservableObject {
    struct Track: Equatable {
        let title: String
        let artist: String
        let album: String
        let duration: Double
    }

    @Published private(set) var track: Track?
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var palette: Palette = .neutral
    /// Repeat the current song. Handled by LyricLock itself, since web players
    /// don't expose their repeat setting to macOS.
    @Published var loopEnabled = false

    private var baseElapsed: Double = 0
    private var baseDate = Date()
    private var rate: Double = 1
    private var timer: Timer?
    private var polling = false
    private var artworkSignature = ""
    private var playerBundleID: String?
    private var lastManualSkip = Date.distantPast
    private var lastLoopSeek = Date.distantPast
    // Self-checking seek: media-control's seek unit isn't documented, so LyricLock tries
    // seconds, checks the player actually moved, falls back to microseconds, and remembers
    // whichever worked.
    private var seekTarget: Double?
    private var seekSentAt = Date.distantPast
    private var seekTriedOther = false
    private var seekInMicros = UserDefaults.standard.bool(forKey: "seekInMicros")
    private let binary: String?

    init() {
        binary = ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if binary == nil {
            errorMessage = "media-control not installed — see README"
        }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
    }

    var playerBundleIdentifier: String? { playerBundleID }

    /// Current playback position in seconds, extrapolated smoothly between polls.
    func position(at date: Date) -> Double {
        guard isPlaying else { return baseElapsed }
        return baseElapsed + date.timeIntervalSince(baseDate) * rate
    }

    // MARK: Controls

    func togglePlayPause() {
        let now = Date()
        baseElapsed = position(at: now)
        baseDate = now
        isPlaying.toggle() // optimistic; the next poll confirms
        send(["toggle-play-pause"], fallback: ["send", "2"])
    }

    func next() {
        lastManualSkip = Date()
        send(["next-track"], fallback: ["send", "4"])
    }

    func previous() {
        lastManualSkip = Date()
        send(["previous-track"], fallback: ["send", "5"])
    }

    /// Brings the player (e.g. the YouTube Music web app) to the front.
    func openPlayer() {
        if let id = playerBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        // Fall back to the YouTube Music web app by name, then to the website.
        if let app = NSWorkspace.shared.runningApplications.first(where: { app in
            let name = (app.localizedName ?? "").lowercased()
            return name.contains("youtube music") || name == "yt music"
        }) {
            app.activate()
            return
        }
        if let url = URL(string: "https://music.youtube.com") { NSWorkspace.shared.open(url) }
    }

    /// Jump to a time in the song (used when you click a lyric line).
    func seek(to seconds: Double) {
        let t = max(0, seconds)
        baseElapsed = t
        baseDate = Date()
        lastLoopSeek = Date()
        seekTarget = t
        seekTriedOther = false
        sendSeek(t, micros: seekInMicros)
    }

    private func sendSeek(_ t: Double, micros: Bool) {
        seekSentAt = Date()
        if micros {
            let v = String(Int(t * 1_000_000))
            send(["seek", v], fallback: ["seek", v])
        } else {
            send(["seek", String(format: "%.2f", t)], fallback: ["seek", String(Int(t.rounded()))])
        }
    }

    private func seekToStart() { seek(to: 0) }

    private func send(_ args: [String], fallback: [String]) {
        guard let binary else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if NowPlaying.run(binary, args).status != 0 {
                _ = NowPlaying.run(binary, fallback)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.poll()
            }
        }
    }

    // MARK: Polling

    private func poll() {
        guard let binary, !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = NowPlaying.run(binary, ["get"]).data
            Task { @MainActor in
                self?.polling = false
                self?.apply(data)
            }
        }
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> (data: Data?, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return (nil, -1) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (data, process.terminationStatus)
    }

    private func apply(_ data: Data?) {
        guard let data,
              let obj = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any],
              let title = obj["title"] as? String, !title.isEmpty
        else {
            if track != nil { track = nil }
            if isPlaying { isPlaying = false }
            return
        }

        let newTrack = Track(
            title: title,
            artist: (obj["artist"] as? String) ?? "",
            album: (obj["album"] as? String) ?? "",
            duration: Self.number(obj["duration"]) ?? 0
        )
        playerBundleID = (obj["parentApplicationBundleIdentifier"] as? String)
            ?? (obj["bundleIdentifier"] as? String)

        let reportedRate = Self.number(obj["playbackRate"])
        let playing = (obj["playing"] as? Bool) ?? ((reportedRate ?? 0) > 0)
        let newRate = (reportedRate ?? 1) > 0 ? (reportedRate ?? 1) : 1

        let now = Date()
        var elapsed: Double
        if let live = Self.number(obj["elapsedTimeNow"]) {
            elapsed = live
        } else {
            elapsed = Self.number(obj["elapsedTime"]) ?? 0
            if playing, let stamp = Self.date(obj["timestamp"]) {
                elapsed += max(0, now.timeIntervalSince(stamp)) * newRate
            }
        }

        let previousTrack = track
        let previousPosition = position(at: now)
        let changed = newTrack.title != previousTrack?.title || newTrack.artist != previousTrack?.artist

        // Loop fallback: the song ended and the player moved on by itself -> go back.
        if changed, loopEnabled, let old = previousTrack, old.duration > 5,
           previousPosition > old.duration - 4,
           now.timeIntervalSince(lastManualSkip) > 3 {
            send(["previous-track"], fallback: ["send", "5"])
        }

        // Snap on big changes (new song, play/pause, seeking); otherwise ease small drift
        // in gradually so the word animation never visibly jumps.
        // A seek is in flight: check it landed; ignore stale readings for a moment so the
        // lyrics don't bounce back; retry with the other unit if the player didn't move.
        var ignorePosition = false
        if let target = seekTarget, !changed {
            let expected = target + now.timeIntervalSince(seekSentAt) * (playing ? newRate : 0)
            let age = now.timeIntervalSince(seekSentAt)
            if abs(elapsed - expected) < 2.5 {
                seekTarget = nil
                UserDefaults.standard.set(seekInMicros, forKey: "seekInMicros")
            } else if age < 1.5 {
                ignorePosition = true
            } else if !seekTriedOther {
                seekTriedOther = true
                seekInMicros.toggle()
                sendSeek(expected, micros: seekInMicros)
                ignorePosition = true
            } else {
                seekTarget = nil   // give up; follow the player again
                seekInMicros.toggle()
            }
        } else if changed {
            seekTarget = nil
        }

        let drift = elapsed - previousPosition
        if ignorePosition {
            // keep the optimistic position
        } else if changed || playing != isPlaying || abs(drift) > 1.5 {
            baseElapsed = elapsed
            baseDate = now
        } else if abs(drift) > 0.12 {
            baseElapsed = previousPosition + drift * 0.35
            baseDate = now
        }
        rate = newRate
        if newTrack != track { track = newTrack }
        if playing != isPlaying { isPlaying = playing }
        if errorMessage != nil { errorMessage = nil }

        // Loop: restart just before the end.
        if loopEnabled, playing, newTrack.duration > 5,
           elapsed >= newTrack.duration - 1.2,
           now.timeIntervalSince(lastLoopSeek) > 4 {
            seekToStart()
        }

        updateArtwork(obj["artworkData"] as? String, trackChanged: changed)
    }

    private func updateArtwork(_ base64: String?, trackChanged: Bool) {
        guard let base64, !base64.isEmpty else {
            if trackChanged {
                artworkSignature = ""
                artwork = nil
                palette = .neutral
            }
            return
        }
        let signature = "\(base64.count)-\(base64.prefix(64))-\(base64.suffix(64))"
        guard signature != artworkSignature else { return }
        artworkSignature = signature
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
                  let image = NSImage(data: data) else { return }
            let newPalette = Palette.from(image)
            Task { @MainActor in
                guard let self, self.artworkSignature == signature else { return }
                self.artwork = image
                withAnimation(.easeInOut(duration: 1.2)) { self.palette = newPalette }
            }
        }
    }

    // MARK: JSON helpers

    nonisolated private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    nonisolated private static func date(_ value: Any?) -> Date? {
        if let n = value as? NSNumber {
            let v = n.doubleValue
            if v > 1e12 { return Date(timeIntervalSince1970: v / 1000) }   // milliseconds
            if v > 1e9 { return Date(timeIntervalSince1970: v) }           // seconds
            return nil
        }
        guard let s = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
