import AppKit
import SwiftUI

/// Two kinds of lyric windows share this class:
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
    private static let originKey = "desktopTopLeft"

    init<V: View>(mode: Mode, @ViewBuilder content: (WindowMover?) -> V) {
        self.mode = mode
        let screenFrame = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = mode == .screensaver ? screenFrame : NSRect(origin: .zero, size: Metrics.windowSize)
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let host = OverlayHostingView(rootView: content(mode == .desktop ? mover : nil))
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        switch mode {
        case .lockScreen, .screensaver:
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.alphaValue = 0
        case .desktop:
            // Just above the desktop icons, below every normal app window.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.ignoresMouseEvents = false
            mover.window = window
            mover.onEnd = { [weak self] in self?.saveOrigin() }
        }
    }

    func attachAboveLockScreen() {
        guard mode != .desktop else { return }
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
        if mode == .desktop, let saved = UserDefaults.standard.string(forKey: Self.originKey) {
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
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        reposition(lower: lower)
    }

    func setVisible(_ visible: Bool) {
        switch mode {
        case .lockScreen, .screensaver:
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
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: Self.originKey)
    }
}

/// Moves the window by following the mouse; driven by a SwiftUI drag gesture so that
/// buttons inside the card still get their clicks.
@MainActor
final class WindowMover {
    weak var window: NSWindow?
    var onEnd: (() -> Void)?
    private var startMouse: NSPoint?
    private var startOrigin: NSPoint?

    func drag() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if startMouse == nil {
            startMouse = mouse
            startOrigin = window.frame.origin
        }
        guard let sm = startMouse, let so = startOrigin else { return }
        window.setFrameOrigin(NSPoint(x: so.x + mouse.x - sm.x, y: so.y + mouse.y - sm.y))
    }

    func end() {
        startMouse = nil
        startOrigin = nil
        onEnd?()
    }
}

/// Clicks work on the first try even though LyricLock is a background app.
final class OverlayHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
