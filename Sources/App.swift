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

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// Seconds added to the playback position. Positive = lyrics appear earlier.
    @Published var offset: Double { didSet { defaults.set(offset, forKey: "offset") } }
    @Published var showOnDesktop: Bool { didSet { defaults.set(showOnDesktop, forKey: "showOnDesktop") } }
    @Published var lowerPosition: Bool { didSet { defaults.set(lowerPosition, forKey: "lowerPosition") } }

    private init() {
        offset = defaults.double(forKey: "offset")
        showOnDesktop = defaults.bool(forKey: "showOnDesktop")
        lowerPosition = defaults.bool(forKey: "lowerPosition")
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
    private var bag = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "music.quarternote.3",
                                           accessibilityDescription: "LyricLock")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        lockOverlay = LyricOverlay(rootView: LyricsView(player: player, lyrics: lyrics), mode: .lockScreen)
        lockOverlay.reposition(lower: settings.lowerPosition)
        lockOverlay.attachAboveLockScreen()

        desktopOverlay = LyricOverlay(rootView: LyricsView(player: player, lyrics: lyrics), mode: .desktop)
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
        desktopOverlay.setVisible(hasTrack && settings.showOnDesktop && !isLocked)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if let t = player.track {
            info(menu, "♪ \(t.title) — \(t.artist)")
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
        item(menu, "Lower on Lock Screen", #selector(togglePosition), on: settings.lowerPosition)
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
