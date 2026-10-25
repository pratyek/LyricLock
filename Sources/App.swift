import AppKit
import SwiftUI
import Combine
import ServiceManagement
import IOKit.pwr_mgt
import Carbon.HIToolbox

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

/// Lyric sizing from one continuous scale (drag the corner grip, or pick a preset).
struct Metrics: Equatable {
    let scale: Double
    static let minScale = 0.6
    static let maxScale = 1.8
    var fontSize: CGFloat { 31 * scale }
    var cardWidth: CGFloat { 660 * scale }
    var lyricsHeight: CGFloat { fontSize * 5.6 }
    /// Fixed window big enough for the largest scale; the transparent rest lets clicks through.
    static let windowSize = NSSize(width: 660 * maxScale + 240, height: 31 * maxScale * 5.6 + 320)
    static let screen = Metrics(scale: 1.8)
    static func clamp(_ s: Double) -> Double { min(max(s, minScale), maxScale) }
}

enum LyricSize: String, CaseIterable {
    case small, medium, large, extraLarge
    var scale: Double {
        switch self { case .small: return 0.75; case .medium: return 1.0; case .large: return 1.3; case .extraLarge: return 1.6 }
    }
    var label: String {
        switch self { case .small: return "Small"; case .medium: return "Medium"; case .large: return "Large"; case .extraLarge: return "Extra Large" }
    }
}

enum TitleSize: String, CaseIterable {
    case small, medium, large
    var points: CGFloat {
        switch self { case .small: return 12; case .medium: return 15; case .large: return 19 }
    }
    var label: String { rawValue.capitalized }
}

enum LyricFont: String, CaseIterable {
    case standard, rounded, serif, mono, avenir, futura, didot, gillSans, optima, baskerville, typewriter, noteworthy

    var label: String {
        switch self {
        case .standard: return "SF Pro (Default)"
        case .rounded: return "SF Rounded"
        case .serif: return "New York (Serif)"
        case .mono: return "SF Mono"
        case .avenir: return "Avenir Next"
        case .futura: return "Futura"
        case .didot: return "Didot"
        case .gillSans: return "Gill Sans"
        case .optima: return "Optima"
        case .baskerville: return "Baskerville"
        case .typewriter: return "American Typewriter"
        case .noteworthy: return "Noteworthy"
        }
    }

    /// All built into macOS. Scripts these fonts don't cover (e.g. Tamil) fall back to the system font.
    func font(size: CGFloat) -> Font {
        switch self {
        case .standard: return .system(size: size, weight: .heavy)
        case .rounded: return .system(size: size, weight: .heavy, design: .rounded)
        case .serif: return .system(size: size, weight: .bold, design: .serif)
        case .mono: return .system(size: size * 0.9, weight: .bold, design: .monospaced)
        case .avenir: return .custom("AvenirNext-Bold", size: size)
        case .futura: return .custom("Futura-Bold", size: size)
        case .didot: return .custom("Didot-Bold", size: size)
        case .gillSans: return .custom("GillSans-SemiBold", size: size)
        case .optima: return .custom("Optima-Bold", size: size)
        case .baskerville: return .custom("Baskerville-Bold", size: size)
        case .typewriter: return .custom("AmericanTypewriter-Semibold", size: size)
        case .noteworthy: return .custom("Noteworthy-Bold", size: size)
        }
    }

    var tracking: CGFloat { (self == .standard || self == .rounded) ? -0.3 : 0 }
}

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    /// Seconds added to the playback position. Positive = lyrics appear earlier.
    @Published var offset: Double { didSet { defaults.set(offset, forKey: "offset") } }
    @Published var showOnDesktop: Bool { didSet { defaults.set(showOnDesktop, forKey: "showOnDesktop") } }
    @Published var lowerPosition: Bool { didSet { defaults.set(lowerPosition, forKey: "lowerPosition") } }
    @Published var scale: Double { didSet { defaults.set(scale, forKey: "scale") } }
    @Published var titleSize: TitleSize { didSet { defaults.set(titleSize.rawValue, forKey: "titleSize") } }
    var metrics: Metrics { Metrics(scale: scale) }
    @Published var font: LyricFont { didSet { defaults.set(font.rawValue, forKey: "font") } }
    @Published var lockAura: Bool { didSet { defaults.set(lockAura, forKey: "lockAura") } }
    @Published var autoHideWhenPaused: Bool { didSet { defaults.set(autoHideWhenPaused, forKey: "autoHide") } }
    @Published var controlsExpanded: Bool { didSet { defaults.set(controlsExpanded, forKey: "controlsExpanded") } }
    @Published var screensaver: Bool { didSet { defaults.set(screensaver, forKey: "screensaver") } }
    @Published var keepAwake: Bool { didSet { defaults.set(keepAwake, forKey: "keepAwake") } }
    @Published var glow: Bool { didSet { defaults.set(glow, forKey: "glow") } }
    @Published var romanize: Bool { didSet { defaults.set(romanize, forKey: "romanize") } }
    @Published var translate: Bool { didSet { defaults.set(translate, forKey: "translate") } }
    @Published var menuBarLyric: Bool { didSet { defaults.set(menuBarLyric, forKey: "menuBarLyric") } }
    @Published var collapsed: Bool { didSet { defaults.set(collapsed, forKey: "collapsed") } }

    private init() {
        defaults.register(defaults: ["lockAura": true, "autoHide": true, "screensaver": true, "keepAwake": true,
                                     "scale": 1.0, "controlsExpanded": true, "glow": true])
        offset = defaults.double(forKey: "offset")
        showOnDesktop = defaults.bool(forKey: "showOnDesktop")
        lowerPosition = defaults.bool(forKey: "lowerPosition")
        scale = min(max(defaults.double(forKey: "scale"), Metrics.minScale), Metrics.maxScale)
        titleSize = TitleSize(rawValue: defaults.string(forKey: "titleSize") ?? "") ?? .medium
        font = LyricFont(rawValue: defaults.string(forKey: "font") ?? "") ?? .standard
        lockAura = defaults.bool(forKey: "lockAura")
        autoHideWhenPaused = defaults.bool(forKey: "autoHide")
        controlsExpanded = defaults.bool(forKey: "controlsExpanded")
        screensaver = defaults.bool(forKey: "screensaver")
        keepAwake = defaults.bool(forKey: "keepAwake")
        glow = defaults.bool(forKey: "glow")
        romanize = defaults.bool(forKey: "romanize")
        translate = defaults.bool(forKey: "translate")
        menuBarLyric = defaults.bool(forKey: "menuBarLyric")
        collapsed = defaults.bool(forKey: "collapsed")
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
    private var screensaverOverlay: LyricOverlay!
    private var isScreensaver = false
    private var displayAssertion: IOPMAssertionID = 0
    private var menuBarTimer: Timer?
    private var searchWindow: NSWindow?
    private lazy var searchModel = LyricSearchModel(lyrics: lyrics, player: player)
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

        lockOverlay = LyricOverlay(mode: .lockScreen) {
            LyricsView(player: self.player, lyrics: self.lyrics, place: .lockScreen, mover: $0)
        }
        lockOverlay.reposition(lower: settings.lowerPosition)
        lockOverlay.attachAboveLockScreen()

        desktopOverlay = LyricOverlay(mode: .desktop) { mover in
            LyricsView(player: self.player, lyrics: self.lyrics, place: .desktop, mover: mover)
        }
        desktopOverlay.reposition(lower: settings.lowerPosition)

        screensaverOverlay = LyricOverlay(mode: .screensaver) { _ in
            ScreensaverView(player: self.player, lyrics: self.lyrics)
        }
        screensaverOverlay.attachAboveLockScreen()

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked),
                        name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlocked),
                        name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screensaverStarted),
                        name: Notification.Name("com.apple.screensaver.didstart"), object: nil)
        dnc.addObserver(self, selector: #selector(screensaverStopped),
                        name: Notification.Name("com.apple.screensaver.didstop"), object: nil)

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

        _ = lyrics // start observing
        player.start()
        registerShortcuts()
        menuBarTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMenuBarLyric() }
        }
    }

    // MARK: Lock state

    @objc private func screenLocked() { isLocked = true; updateVisibility() }
    @objc private func screenUnlocked() { isLocked = false; updateVisibility() }
    @objc private func screensaverStarted() { isScreensaver = true; updateVisibility() }
    @objc private func screensaverStopped() { isScreensaver = false; updateVisibility() }
    @objc private func screensChanged() {
        screensaverOverlay.reposition(lower: false)
        lockOverlay.reposition(lower: settings.lowerPosition)
        desktopOverlay.reposition(lower: settings.lowerPosition)
    }

    private func updateVisibility() {
        let saver = hasTrack && isScreensaver && settings.screensaver
        screensaverOverlay.setVisible(saver)
        lockOverlay.setVisible(hasTrack && isLocked && !saver)
        let hiddenForPause = settings.autoHideWhenPaused && pausedLong
        desktopOverlay.setVisible(hasTrack && settings.showOnDesktop && !isLocked && !isScreensaver && !hiddenForPause)
        updateDisplayAssertion()
    }

    /// While music plays on the lock screen or screensaver, keep the display from sleeping,
    /// so the lyrics stay visible. Released as soon as music pauses or you unlock.
    private func updateDisplayAssertion(playing: Bool? = nil) {
        // `playing` is passed from the publisher, which fires just before the property changes.
        let isPlaying = playing ?? player.isPlaying
        let want = settings.keepAwake && isPlaying && hasTrack && (isLocked || isScreensaver)
        if want, displayAssertion == 0 {
            var id: IOPMAssertionID = 0
            let ok = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                                 IOPMAssertionLevel(255),
                                                 "LyricLock is showing lyrics" as CFString, &id)
            if ok == kIOReturnSuccess { displayAssertion = id }
        } else if !want, displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
    }

    /// Desktop lyrics fade out after 30s of pause and return on play.
    private func playbackChanged(_ playing: Bool) {
        pauseTask?.cancel()
        updateDisplayAssertion(playing: playing)
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
        item(menu, "Lyrics Screensaver", #selector(toggleScreensaver), on: settings.screensaver)
        item(menu, "Start Screensaver Now", #selector(startScreensaver))
        item(menu, "Keep Screen On While Music Plays", #selector(toggleKeepAwake), on: settings.keepAwake)
        menu.addItem(.separator())

        item(menu, "Glow", #selector(toggleGlow), on: settings.glow)
        item(menu, "Romanize Lyrics (English Letters)", #selector(toggleRomanize), on: settings.romanize)
        item(menu, "Show English Translation", #selector(toggleTranslate), on: settings.translate)
        if settings.translate, let note = lyrics.translationNote { info(menu, "   " + note) }
        item(menu, "Show Lyric in Menu Bar", #selector(toggleMenuBarLyric), on: settings.menuBarLyric)
        item(menu, "Find Lyrics for This Song…", #selector(openSearch))
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for size in LyricSize.allCases {
            let i = NSMenuItem(title: size.label, action: #selector(pickSize(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = size.rawValue
            i.state = abs(settings.scale - size.scale) < 0.03 ? .on : .off
            sizeMenu.addItem(i)
        }
        sizeMenu.addItem(.separator())
        let tip = NSMenuItem(title: "Tip: drag the corner grip on the lyrics to any size", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        sizeMenu.addItem(tip)
        let sizeItem = NSMenuItem(title: "Lyrics Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let titleMenu = NSMenu()
        for t in TitleSize.allCases {
            let i = NSMenuItem(title: t.label, action: #selector(pickTitleSize(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = t.rawValue
            i.state = settings.titleSize == t ? .on : .off
            titleMenu.addItem(i)
        }
        let titleItem = NSMenuItem(title: "Song & Artist Size", action: nil, keyEquivalent: "")
        titleItem.submenu = titleMenu
        menu.addItem(titleItem)

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

        let keys = NSMenu()
        for (label, combo) in [("Show / Hide Desktop Lyrics", "⌥⌘L"), ("Play / Pause", "⌥⌘P"),
                               ("Next Song", "⌥⌘→"), ("Previous Song", "⌥⌘←"),
                               ("Bigger Lyrics", "⌥⌘="), ("Smaller Lyrics", "⌥⌘−"),
                               ("Save Lyric Image", "⌥⌘S")] {
            let i = NSMenuItem(title: "\(combo)   \(label)", action: nil, keyEquivalent: "")
            i.isEnabled = false
            keys.addItem(i)
        }
        let keysItem = NSMenuItem(title: "Keyboard Shortcuts", action: nil, keyEquivalent: "")
        keysItem.submenu = keys
        menu.addItem(keysItem)

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
    @objc private func toggleScreensaver() { settings.screensaver.toggle(); updateVisibility() }
    @objc private func toggleKeepAwake() { settings.keepAwake.toggle(); updateDisplayAssertion() }
    @objc private func startScreensaver() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
    }
    @objc private func toggleGlow() { settings.glow.toggle() }
    @objc private func toggleRomanize() { settings.romanize.toggle() }
    @objc private func toggleTranslate() {
        settings.translate.toggle()
        if settings.translate { lyrics.translateCurrent() } else { lyrics.clearTranslations() }
    }
    @objc private func toggleMenuBarLyric() { settings.menuBarLyric.toggle(); updateMenuBarLyric() }

    @objc private func openSearch() {
        if searchWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.title = "Find Lyrics"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LyricSearchView(model: searchModel))
            w.center()
            searchModel.onDone = { [weak w] in w?.close() }
            searchWindow = w
        }
        searchModel.prefill()
        NSApp.activate()
        searchWindow?.makeKeyAndOrderFront(nil)
    }

    /// Current lyric line next to the ♫ icon.
    private func updateMenuBarLyric() {
        guard let button = statusItem.button else { return }
        var text = ""
        if settings.menuBarLyric, let l = lyrics.currentLyrics, let t = player.track {
            let i = l.index(at: player.position(at: Date()) + settings.offset + LyricStack.lead, duration: t.duration)
            if i >= 0 {
                let line = l.lines[i].display(romanize: settings.romanize).trimmingCharacters(in: .whitespaces)
                text = line.count > 42 ? String(line.prefix(40)) + "…" : line
            }
        }
        let title = text.isEmpty ? "" : " " + text
        if button.title != title { button.title = title }
    }

    private func registerShortcuts() {
        let keys = HotKeys.shared
        keys.register(keyCode: kVK_ANSI_L) { [weak self] in self?.toggleDesktop() }
        keys.register(keyCode: kVK_ANSI_P) { [weak self] in self?.player.togglePlayPause() }
        keys.register(keyCode: kVK_RightArrow) { [weak self] in self?.player.next() }
        keys.register(keyCode: kVK_LeftArrow) { [weak self] in self?.player.previous() }
        keys.register(keyCode: kVK_ANSI_Equal) { [weak self] in self?.nudgeSize(0.1) }
        keys.register(keyCode: kVK_ANSI_Minus) { [weak self] in self?.nudgeSize(-0.1) }
        keys.register(keyCode: kVK_ANSI_S) { [weak self] in self?.saveLyricImage() }
    }

    private func nudgeSize(_ delta: Double) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            settings.scale = Metrics.clamp(settings.scale + delta)
        }
    }

    private func saveLyricImage() {
        guard let l = lyrics.currentLyrics, let t = player.track else { NSSound.beep(); return }
        let i = l.index(at: player.position(at: Date()) + settings.offset + LyricStack.lead, duration: t.duration)
        ShareCard.save(line: l.lines[max(i, 0)].display(romanize: settings.romanize),
                       title: LyricsService.cleanTitle(t.title), artist: LyricsService.primaryArtist(t.artist),
                       artwork: player.artwork, palette: player.palette, font: settings.font)
    }

    @objc private func toggleAutoHide() { settings.autoHideWhenPaused.toggle(); updateVisibility() }
    @objc private func toggleAura() { settings.lockAura.toggle() }
    @objc private func pickSize(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let size = LyricSize(rawValue: raw) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { settings.scale = size.scale }
        }
    }
    @objc private func pickTitleSize(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let t = TitleSize(rawValue: raw) { settings.titleSize = t }
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
