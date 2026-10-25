import AppKit
import SwiftUI

/// Lyric windows. Important safety rule: every window ignores the mouse by default, and only
/// takes clicks while the pointer is actually over the visible lyrics card (checked 20× a
/// second). So an invisible or transparent part of a window can never block your Mac.
///
/// Kinds:
/// - `.lockScreen`: click-through, moved into a SkyLight (WindowServer) space above the
///   lock screen. Only made visible while the Mac is locked.
/// - `.desktop`: sits on the desktop layer, behind every app window, like a desktop widget.
///   Drag it anywhere; buttons work; the position is remembered.
@MainActor
final class LyricOverlay {
    enum Mode { case lockScreen, desktop, screensaver }

    private let window: NSWindow
    private let mode: Mode
    private let mover = WindowMover()
    private(set) var isAboveLockScreen = false
    private var shown = false
    private var mouseTimer: Timer?
    private var cursorHidden = false
    /// Screensaver only: called when Space is pressed while it has focus.
    var onSpace: (() -> Void)? {
        didSet { (window as? KeyableWindow)?.onSpace = onSpace }
    }
    private var originKey: String { mode == .lockScreen ? "lockTopLeft" : "desktopTopLeft" }

    init<V: View>(mode: Mode, @ViewBuilder content: (WindowMover?) -> V) {
        self.mode = mode
        let screenFrame = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = mode == .screensaver ? screenFrame : NSRect(origin: .zero, size: Metrics.windowSize)
        window = mode == .screensaver
            ? KeyableWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let host = OverlayHostingView(rootView: content(mode == .screensaver ? nil : mover))
        let browse = mover.browse
        host.onScroll = { event in browse.scroll(event) }
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        switch mode {
        case .lockScreen:
            window.ignoresMouseEvents = true
            window.canBecomeVisibleWithoutLogin = true
            window.level = .screenSaver
            window.alphaValue = 0
            mover.window = window          // draggable on the lock screen too
            mover.onEnd = { [weak self] in self?.saveOrigin() }
        case .screensaver:
            // LyricLock's own full-screen screensaver: a normal top-level window that takes
            // focus while shown, so clicks and keys land on it (and do nothing) until Space.
            window.ignoresMouseEvents = false
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.alphaValue = 0
        case .desktop:
            // Just above the desktop icons, below every normal app window.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.ignoresMouseEvents = true
            mover.window = window
            mover.onEnd = { [weak self] in self?.saveOrigin() }
        }

        // The screensaver never takes the mouse: any movement there should wake the Mac.
        if mode != .screensaver {
            mouseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateMousePassThrough() }
            }
        }
    }

    /// Take mouse events only while the pointer is over the visible lyrics card.
    private func updateMousePassThrough() {
        var accept = false
        if shown, window.alphaValue > 0.5, mover.cardRect.width > 1 {
            if mover.isInteracting {
                accept = true   // keep the drag/resize going even if the pointer slips outside
            } else {
                let f = window.frame
                let r = mover.cardRect
                let onScreen = NSRect(x: f.minX + r.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
                accept = onScreen.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
            }
        }
        if window.ignoresMouseEvents == accept { window.ignoresMouseEvents = !accept }
    }

    func attachAboveLockScreen() {
        guard mode == .lockScreen else { return }
        window.orderFrontRegardless()
        isAboveLockScreen = SkyLight.moveToLockScreenSpace(window)
    }

    func reposition(lower: Bool) {
        guard let screen = NSScreen.screens.first else { return }
        if mode == .screensaver {
            window.setFrame(screen.frame, display: true)
            return
        }
        let size = window.frame.size
        if mode != .screensaver, let saved = UserDefaults.standard.string(forKey: originKey) {
            let topLeft = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -80, dy: -80).contains(topLeft) }) {
                window.setFrameOrigin(NSPoint(x: topLeft.x, y: topLeft.y - size.height))
                return
            }
        }
        let f = screen.frame
        // The card hangs from the top of the window, so aim the window's upper part at the target.
        let targetCenterY = lower ? f.minY + f.height * 0.3 : f.midY - f.height * 0.02
        let y = targetCenterY - size.height * 0.62
        window.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: y))
    }

    // The window is always sized for the largest lyric scale; the transparent area around
    // the lyrics lets clicks through, so resizing the lyrics never needs to resize the window.

    func resetDesktopPosition(lower: Bool) {
        UserDefaults.standard.removeObject(forKey: originKey)
        reposition(lower: lower)
    }

    func setVisible(_ visible: Bool) {
        shown = visible
        if !visible { window.ignoresMouseEvents = true }
        switch mode {
        case .screensaver:
            if visible {
                if let screen = NSScreen.main ?? NSScreen.screens.first { window.setFrame(screen.frame, display: true) }
                window.alphaValue = 0
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.6
                    window.animator().alphaValue = 1
                }
                if !cursorHidden { NSCursor.hide(); cursorHidden = true }
            } else {
                if cursorHidden { NSCursor.unhide(); cursorHidden = false }
                guard window.isVisible else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.35
                    window.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.window.alphaValue == 0 else { return }
                        self.window.orderOut(nil)
                    }
                })
            }
        case .lockScreen:
            // Never order out: that would pull the window out of the lock-screen space.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                window.animator().alphaValue = visible ? 1 : 0
            }
        case .desktop:
            if visible {
                guard !window.isVisible || window.alphaValue < 1 else { return }
                window.alphaValue = 0
                window.orderFront(nil)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.4
                    window.animator().alphaValue = 1
                }
            } else {
                guard window.isVisible else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.4
                    window.animator().alphaValue = 0
                }, completionHandler: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.window.alphaValue == 0 else { return }
                        self.window.orderOut(nil) // fully removed so it can't block clicks
                    }
                })
            }
        }
    }

    private func saveOrigin() {
        let f = window.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: originKey)
    }
}

/// Moves the window by following the mouse; driven by a SwiftUI drag gesture so that
/// buttons inside the card still get their clicks.
@MainActor
final class WindowMover {
    weak var window: NSWindow?
    let browse = BrowseState()
    /// Where the lyrics card is inside the window (top-left origin), reported by the view.
    var cardRect: CGRect = .zero
    /// True while dragging or resizing.
    var isInteracting = false
    var onEnd: (() -> Void)?
    private var startMouse: NSPoint?
    private var startOrigin: NSPoint?

    func drag() {
        guard let window else { return }
        isInteracting = true
        let mouse = NSEvent.mouseLocation
        if startMouse == nil {
            startMouse = mouse
            startOrigin = window.frame.origin
        }
        guard let sm = startMouse, let so = startOrigin else { return }
        window.setFrameOrigin(NSPoint(x: so.x + mouse.x - sm.x, y: so.y + mouse.y - sm.y))
    }

    func end() {
        isInteracting = false
        startMouse = nil
        startOrigin = nil
        onEnd?()
    }
}

/// Clicks work on the first try even though LyricLock is a background app.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    var onScroll: ((NSEvent) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func scrollWheel(with event: NSEvent) { onScroll?(event) }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Minimal wrapper around private SkyLight calls, loaded at runtime so the app
/// still launches (without lock-screen support) if Apple removes them.
enum SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> UInt64
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias SpaceAddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    @MainActor
    static func moveToLockScreenSpace(_ window: NSWindow) -> Bool {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let pConn = dlsym(handle, "SLSMainConnectionID"),
              let pCreate = dlsym(handle, "SLSSpaceCreate"),
              let pLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let pShow = dlsym(handle, "SLSShowSpaces"),
              let pAdd = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else { return false }

        let mainConnection = unsafeBitCast(pConn, to: MainConnectionID.self)
        let spaceCreate = unsafeBitCast(pCreate, to: SpaceCreate.self)
        let setLevel = unsafeBitCast(pLevel, to: SpaceSetAbsoluteLevel.self)
        let showSpaces = unsafeBitCast(pShow, to: ShowSpaces.self)
        let addWindows = unsafeBitCast(pAdd, to: SpaceAddWindows.self)

        let connection = mainConnection()
        let space = spaceCreate(connection, 1, 0)
        guard space != 0 else { return false }
        _ = setLevel(connection, space, 400)             // above the lock-screen UI
        _ = showSpaces(connection, [NSNumber(value: space)] as CFArray)
        _ = addWindows(connection, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        return true
    }
}

/// Scroll over the lyrics to look back (or ahead); after a few seconds without scrolling
/// it glides back to the live line.
@MainActor
final class BrowseState: ObservableObject {
    @Published private(set) var offset = 0
    private var accumulated: CGFloat = 0
    private var resetTask: Task<Void, Never>?

    func scroll(_ event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 14
        accumulated += dy
        let step: CGFloat = 34
        var changed = false
        while accumulated >= step { accumulated -= step; offset -= 1; changed = true }
        while accumulated <= -step { accumulated += step; offset += 1; changed = true }
        guard changed || offset != 0 else { return }
        resetTask?.cancel()
        resetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            self?.reset()
        }
    }

    /// Clamp after the view knows how many lines there are.
    func clamp(to range: ClosedRange<Int>) {
        if offset < range.lowerBound { offset = range.lowerBound }
        if offset > range.upperBound { offset = range.upperBound }
    }

    func reset() {
        resetTask?.cancel()
        accumulated = 0
        if offset != 0 { offset = 0 }
    }
}

/// Borderless window that can take keyboard focus (used by the screensaver). Every key is
/// swallowed quietly except Space, which ends the screensaver.
final class KeyableWindow: NSWindow {
    var onSpace: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { onSpace?() }   // 49 = Space
    }
}
