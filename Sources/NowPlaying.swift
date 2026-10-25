import Foundation

/// Reads the system "Now Playing" info (what the lock-screen media widget shows),
/// via the open-source `media-control` CLI. That works for the YouTube Music
/// Safari web app because Safari publishes its media session to the system.
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

    private var baseElapsed: Double = 0
    private var baseDate = Date()
    private var rate: Double = 1
    private var timer: Timer?
    private var polling = false
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

    /// Current playback position in seconds, extrapolated smoothly between polls.
    func position(at date: Date) -> Double {
        guard isPlaying else { return baseElapsed }
        return baseElapsed + date.timeIntervalSince(baseDate) * rate
    }

    // MARK: Polling

    private func poll() {
        guard let binary, !polling else { return }
        polling = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let data = NowPlaying.run(binary, ["get"])
            Task { @MainActor in
                self?.polling = false
                self?.apply(data)
            }
        }
    }

    nonisolated private static func run(_ path: String, _ args: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
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

        let changed = newTrack.title != track?.title || newTrack.artist != track?.artist
        let drift = abs(position(at: now) - elapsed)
        if changed || playing != isPlaying || drift > 0.35 {
            baseElapsed = elapsed
            baseDate = now
        }
        rate = newRate
        if newTrack != track { track = newTrack }
        if playing != isPlaying { isPlaying = playing }
        if errorMessage != nil { errorMessage = nil }
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
