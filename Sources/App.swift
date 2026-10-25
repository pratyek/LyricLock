import AppKit
import SwiftUI
import Combine
import ServiceManagement

@main
enum LyricLockMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() }
    }
}

enum LyricSize: String, CaseIterable {
    case small, medium, large
    var fontSize: CGFloat {
        switch self { case .small: return 28; case .medium: return 36; case .large: return 46 }
    }
    var cardWidth: CGFloat {
        switch self { case .small: return 620; case .medium: return 780; case .large: return 960 }
    }
    var lyricsHeight: CGFloat { fontSize * 7.4 }
    /// Window is bigger than the card so the glow and hover outline have room.
    var windowSize: NSSize { NSSize(width: cardWidth + 220, height: lyricsHeight + 330) }
    var label: String { rawValue.capitalized }
}

enum LyricFont: String, CaseIterable {
    case standard, rounded, serif
    var design: Font.Design {
        switch self { case .standard: return .default; case .rounded: return .rounded; case .serif: return .serif }
    }
    var weight: Font.Weight { self == .serif ? .bold : .heavy }
    var label: String {
        switch self { case .standard: return "Default"; case .rounded: return "Rounded"; case .serif: return "Serif" }
    }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// Seconds added to the playback position. Positive = lyrics appear earlier.
    @Published var offset: Double { didSet { defaults.set(offset, forKey: "offset") } }
    @Published var showOnDesktop: Bool { didSet { defaults.set(showOnDesktop, forKey: "showOnDesktop") } }
    @Published var lowerPosition: Bool { didSet { defaults.set(lowerPosition, forKey: "lowerPosition") } }
    @Published var size: LyricSize { didSet { defaults.set(size.rawValue, forKey: "size") } }
    @Published var font: LyricFont { didSet { defaults.set(font.rawValue, forKey: "font") } }
    @Published var lockAura: Bool { didSet { defaults.set(lockAura, forKey: "lockAura") } }
    @Published var autoHideWhenPaused: Bool { didSet { defaults.set(autoHideWhenPaused, forKey: "autoHide") } }
    @Published var controlsExpanded: Bool { didSet { defaults.set(controlsExpanded, forKey: "controlsExpanded") } }

    private init() {
        defaults.register(defaults: ["lockAura": true, "autoHide": true])
        offset = defaults.double(forKey: "offset")
        showOnDesktop = defaults.bool(forKey: "showOnDesktop")
        lowerPosition = defaults.bool(forKey: "lowerPosition")
        size = LyricSize(rawValue: defaults.string(forKey: "size") ?? "") ?? .medium
        font = LyricFont(rawValue: defaults.string(forKey: "font") ?? "") ?? .standard
        lockAura = defaults.bool(forKey: "lockAura")
        autoHideWhenPaused = defaults.bool(forKey: "autoHide")
        controlsExpanded = defaults.bool(forKey: "controlsExpanded")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let player = NowPlaying()
    private lazy var lyrics = LyricsController(player: player)
    private let settings = Settings.shared
    private var statusItem: NSStatusItem!
    private var lockOverlay: LyricOverlay!
    private var desktopOverlay: LyricOverlay!
    private var isLocked = false
    private var hasTrack = false
    private var pausedLong = false
    private var pauseTask: Task<Void, Never>?
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.quarternote.3",
                                           accessibilityDescription: "LyricLock")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        lockOverlay = LyricOverlay(mode: .lockScreen, size: settings.size) { _ in
            LyricsView(player: self.player, lyrics: self.lyrics, interactive: false, mover: nil)
        }
        lockOverlay.reposition(lower: settings.lowerPosition)
        lockOverlay.attachAboveLockScreen()

        desktopOverlay = LyricOverlay(mode: .desktop, size: settings.size) { mover in
            LyricsView(player: self.player, lyrics: self.lyrics, interactive: true, mover: mover)
        }
        desktopOverlay.reposition(lower: settings.lowerPosition)

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked),
                        name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlocked),
                        name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)

        player.$track
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] has in
                self?.hasTrack = has
                self?.updateVisibility()
            }
            .store(in: &bag)

        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in self?.playbackChanged(playing) }
            .store(in: &bag)

        settings.$size
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] size in
                guard let self else { return }
                self.lockOverlay.resize(to: size, lower: self.settings.lowerPosition)
                self.desktopOverlay.resize(to: size, lower: self.settings.lowerPosition)
            }
            .store(in: &bag)

        _ = lyrics // start observing
        player.start()
    }

    // MARK: Lock state

    @objc private func screenLocked() { isLocked = true; updateVisibility() }
    @objc private func screenUnlocked() { isLocked = false; updateVisibility() }
    @objc private func screensChanged() {
        lockOverlay.reposition(lower: settings.lowerPosition)
        desktopOverlay.reposition(lower: settings.lowerPosition)
    }

    private func updateVisibility() {
        lockOverlay.setVisible(hasTrack && isLocked)
        let hiddenForPause = settings.autoHideWhenPaused && pausedLong
        desktopOverlay.setVisible(hasTrack && settings.showOnDesktop && !isLocked && !hiddenForPause)
    }

    /// Desktop lyrics fade out after 30s of pause and return on play.
    private func playbackChanged(_ playing: Bool) {
        pauseTask?.cancel()
        if playing {
            if pausedLong { pausedLong = false; updateVisibility() }
        } else {
            pauseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self, !Task.isCancelled, !self.player.isPlaying else { return }
                self.pausedLong = true
                self.updateVisibility()
            }
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let t = player.track {
            info(menu, "♪ \(LyricsService.cleanTitle(t.title)) — \(LyricsService.primaryArtist(t.artist))")
            info(menu, lyrics.statusText)
        } else {
            info(menu, player.errorMessage ?? "Nothing playing")
        }
        if !lockOverlay.isAboveLockScreen {
            info(menu, "⚠︎ Lock-screen layer unavailable on this macOS")
        }
        menu.addItem(.separator())

        item(menu, "Show on Desktop", #selector(toggleDesktop), on: settings.showOnDesktop)
        item(menu, "Reset Desktop Position", #selector(resetDesktop))
        item(menu, "Hide Desktop Lyrics When Paused", #selector(toggleAutoHide), on: settings.autoHideWhenPaused)
        item(menu, "Lower on Lock Screen", #selector(togglePosition), on: settings.lowerPosition)
        item(menu, "Album Glow on Lock Screen", #selector(toggleAura), on: settings.lockAura)
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for size in LyricSize.allCases {
            let i = NSMenuItem(title: size.label, action: #selector(pickSize(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = size.rawValue
            i.state = settings.size == size ? .on : .off
            sizeMenu.addItem(i)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let fontMenu = NSMenu()
        for font in LyricFont.allCases {
            let i = NSMenuItem(title: font.label, action: #selector(pickFont(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = font.rawValue
            i.state = settings.font == font ? .on : .off
            fontMenu.addItem(i)
        }
        let fontItem = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        fontItem.submenu = fontMenu
        menu.addItem(fontItem)
        menu.addItem(.separator())

        info(menu, String(format: "Timing offset: %+.2fs", settings.offset))
        item(menu, "Show Lyrics Earlier (+0.25s)", #selector(earlier))
        item(menu, "Show Lyrics Later (−0.25s)", #selector(later))
        item(menu, "Reset Timing", #selector(resetTiming))
        menu.addItem(.separator())

        item(menu, "Launch at Login", #selector(toggleLogin),
             on: SMAppService.mainApp.status == .enabled)
        item(menu, "Quit LyricLock", #selector(quit))
    }

    private func info(_ menu: NSMenu, _ title: String) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        menu.addItem(i)
    }

    private func item(_ menu: NSMenu, _ title: String, _ action: Selector, on: Bool = false) {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = on ? .on : .off
        menu.addItem(i)
    }

    @objc private func toggleDesktop() { settings.showOnDesktop.toggle(); updateVisibility() }
    @objc private func togglePosition() {
        settings.lowerPosition.toggle()
        lockOverlay.reposition(lower: settings.lowerPosition)
    }
    @objc private func toggleAutoHide() { settings.autoHideWhenPaused.toggle(); updateVisibility() }
    @objc private func toggleAura() { settings.lockAura.toggle() }
    @objc private func pickSize(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let size = LyricSize(rawValue: raw) { settings.size = size }
    }
    @objc private func pickFont(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let font = LyricFont(rawValue: raw) { settings.font = font }
    }
    @objc private func resetDesktop() { desktopOverlay.resetDesktopPosition(lower: false) }
    @objc private func earlier() { settings.offset += 0.25 }
    @objc private func later() { settings.offset -= 0.25 }
    @objc private func resetTiming() { settings.offset = 0 }
    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            NSSound.beep()
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
