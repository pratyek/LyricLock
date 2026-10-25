import AppKit
import ApplicationServices
import Combine

/// Reads YouTube Music's "Up next" queue straight from its window via the Accessibility API
/// (the same way screen readers do), because the player never shares its queue with macOS.
struct QueueItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let artist: String
    let duration: String
    let isCurrent: Bool
    let isPast: Bool
}

/// AXUIElement isn't Sendable; this box just carries references between threads.
final class AXBox: @unchecked Sendable {
    let elements: [AXUIElement]
    init(_ elements: [AXUIElement]) { self.elements = elements }
}

struct QueueRow: @unchecked Sendable {
    let title: String
    let artist: String
    let duration: String
    let element: AXUIElement
}

@MainActor
final class QueueReader: ObservableObject {
    enum Status: Equatable { case idle, needsPermission, loading, empty, ready }

    @Published private(set) var items: [QueueItem] = []
    @Published private(set) var status: Status = .idle
    @Published var isOpen = false {
        didSet {
            guard isOpen != oldValue else { return }
            if isOpen { refresh() }
            updateTimer()
        }
    }

    private weak var player: NowPlaying?
    private var elements: [AXUIElement] = []
    private var timer: Timer?
    private var scanning = false
    private var bag = Set<AnyCancellable>()

    init(player: NowPlaying) {
        self.player = player
        player.$track
            .map { $0?.title }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.isOpen else { return }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    self.refresh()
                }
            }
            .store(in: &bag)
    }

    // MARK: Permission

    func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        Task { @MainActor in
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if AXIsProcessTrusted() { self.refresh(); return }
            }
        }
    }

    // MARK: Reading

    func refresh() {
        guard AXIsProcessTrusted() else {
            status = .needsPermission
            items = []
            return
        }
        guard !scanning else { return }
        guard let pid = playerPID() else {
            status = .empty
            items = []
            return
        }
        scanning = true
        if items.isEmpty { status = .loading }
        let current = player?.track.map { LyricsService.cleanTitle($0.title).lowercased() } ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let rows = QueueScanner.scan(pid: pid)
            Task { @MainActor in self?.apply(rows, currentTitle: current) }
        }
    }

    private func apply(_ rows: [QueueRow], currentTitle: String) {
        scanning = false
        elements = rows.map(\.element)
        guard !rows.isEmpty else {
            status = .empty
            items = []
            return
        }
        let currentIndex = rows.firstIndex { row in
            let t = LyricsService.cleanTitle(row.title).lowercased()
            return !currentTitle.isEmpty && (t == currentTitle || t.hasPrefix(currentTitle) || currentTitle.hasPrefix(t))
        }
        let newItems = rows.enumerated().map { i, r in
            QueueItem(id: i, title: r.title, artist: r.artist, duration: r.duration,
                      isCurrent: i == currentIndex, isPast: currentIndex.map { i < $0 } ?? false)
        }
        if newItems != items { items = newItems }
        status = .ready
    }

    func play(_ item: QueueItem) {
        guard item.id < elements.count else { return }
        let box = AXBox([elements[item.id]])
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = QueueScanner.press(box.elements[0])
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self?.refresh()
            }
        }
    }

    /// Writes what LyricLock can "see" in the YouTube Music window, for troubleshooting.
    func saveScan() {
        guard AXIsProcessTrusted() else { requestPermission(); return }
        guard let pid = playerPID() else { NSSound.beep(); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let text = QueueScanner.dump(pid: pid)
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/LyricLock-queue-scan.txt")
            try? text.write(to: url, atomically: true, encoding: .utf8)
            Task { @MainActor in NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }

    private func updateTimer() {
        timer?.invalidate()
        timer = nil
        guard isOpen else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func playerPID() -> pid_t? {
        if let id = player?.playerBundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
            return app.processIdentifier
        }
        // Fallback: find the YouTube Music web app by name.
        return NSWorkspace.shared.runningApplications.first { app in
            let name = (app.localizedName ?? "").lowercased()
            return name.contains("youtube music") || name == "yt music"
        }?.processIdentifier
    }
}

// MARK: - Accessibility tree walking (runs off the main thread)

enum QueueScanner {
    private static let attributes = ["AXRole", "AXValue", "AXTitle", "AXDescription", "AXChildren"] as CFArray
    private static let durationPattern = try! NSRegularExpression(pattern: #"^\d{1,2}:\d{2}(:\d{2})?$"#)

    struct Info {
        let role: String
        let value: String?
        let label: String?
        let children: [AXUIElement]
    }

    static func info(_ e: AXUIElement) -> Info {
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, attributes, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
              let cf = values, let arr = (cf as NSArray) as? [Any], arr.count == 5
        else { return Info(role: "", value: nil, label: nil, children: []) }
        func str(_ v: Any) -> String? {
            guard let s = v as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return Info(role: (arr[0] as? String) ?? "",
                    value: str(arr[1]),
                    label: str(arr[2]) ?? str(arr[3]),
                    children: (arr[4] as? [AXUIElement]) ?? [])
    }

    static func isDuration(_ s: String) -> Bool {
        durationPattern.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    private static func isNoise(_ s: String) -> Bool {
        let t = s.lowercased()
        return s.count <= 1 || ["•", "song", "video", "explicit", "playing", "paused", "e"].contains(t)
    }

    private static func windows(_ pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.5)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return [] }
        return list
    }

    /// Finds queue rows: the smallest groups holding a title, an artist and one duration ("3:45").
    /// If an "Up next" heading exists, only rows after it are kept.
    static func scan(pid: pid_t) -> [QueueRow] {
        var budget = 9000
        var rows: [QueueRow] = []
        var markerIndex: Int?

        func visit(_ e: AXUIElement, depth: Int) -> (texts: [String], hasRow: Bool) {
            guard budget > 0, depth < 90 else { return ([], false) }
            budget -= 1
            let node = info(e)
            if markerIndex == nil,
               let label = node.value ?? node.label,
               label.lowercased() == "up next" {
                markerIndex = rows.count
            }
            var texts: [String] = []
            if node.role == "AXStaticText", let v = node.value ?? node.label { texts.append(v) }
            var hasRow = false
            for child in node.children {
                let r = visit(child, depth: depth + 1)
                hasRow = hasRow || r.hasRow
                if texts.count < 40 { texts += r.texts }
            }
            if !hasRow, node.role != "AXStaticText", (2...8).contains(texts.count) {
                let durations = texts.filter(isDuration)
                let others = texts.filter { !isDuration($0) && !isNoise($0) }
                if durations.count == 1, let title = others.first {
                    let artist = others.count > 1
                        ? (others[1].components(separatedBy: " • ").first ?? others[1])
                        : ""
                    rows.append(QueueRow(title: title, artist: artist, duration: durations[0], element: e))
                    return ([], true)
                }
            }
            return (hasRow ? [] : texts, hasRow)
        }

        for w in windows(pid) { _ = visit(w, depth: 0) }
        if let m = markerIndex, m < rows.count { return Array(rows[m...]) }
        return rows
    }

    /// Tries to start playback of a queue row: its "Play" button first, then the row, then any button/link.
    static func press(_ row: AXUIElement) -> Bool {
        let press = "AXPress" as CFString
        var queue = info(row).children
        var fallback: [AXUIElement] = []
        var visited = 0
        while !queue.isEmpty, visited < 120 {
            let c = queue.removeFirst()
            visited += 1
            let n = info(c)
            if n.role == "AXButton", (n.label ?? "").lowercased().hasPrefix("play"),
               AXUIElementPerformAction(c, press) == .success { return true }
            if ["AXButton", "AXLink"].contains(n.role) { fallback.append(c) }
            queue += n.children
        }
        if AXUIElementPerformAction(row, press) == .success { return true }
        for c in fallback where AXUIElementPerformAction(c, press) == .success { return true }
        return false
    }

    static func dump(pid: pid_t) -> String {
        var lines: [String] = ["LyricLock queue scan — \(Date())", ""]
        var budget = 9000
        func visit(_ e: AXUIElement, depth: Int) {
            guard budget > 0, depth < 90 else { return }
            budget -= 1
            let n = info(e)
            var line = String(repeating: "  ", count: depth) + n.role
            if let v = n.value { line += "  value=\"\(v.prefix(80))\"" }
            if let l = n.label { line += "  label=\"\(l.prefix(80))\"" }
            lines.append(line)
            for c in n.children { visit(c, depth: depth + 1) }
        }
        for w in windows(pid) { visit(w, depth: 0) }
        let rows = scan(pid: pid)
        lines.append("")
        lines.append("Detected queue rows: \(rows.count)")
        for r in rows { lines.append("  • \(r.title) — \(r.artist) (\(r.duration))") }
        return lines.joined(separator: "\n")
    }
}
