import AppKit
import SwiftUI

/// Two kinds of transparent lyric windows share this class:
/// - `.lockScreen`: click-through, moved into a SkyLight (WindowServer) space above the
///   lock screen. Only made visible while the Mac is locked.
/// - `.desktop`: sits on the desktop layer, behind every app window, like a desktop widget.
///   Drag it anywhere; the position is remembered.
@MainActor
final class LyricOverlay {
    enum Mode { case lockScreen, desktop }

    private let window: NSWindow
    private let mode: Mode
    private(set) var isAboveLockScreen = false
    private static let size = NSSize(width: 880, height: 340)
    private static let originKey = "desktopOrigin"

    init<V: View>(rootView: V, mode: Mode) {
        self.mode = mode
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let host = DraggableHostingView(rootView: rootView)
        host.frame = NSRect(origin: .zero, size: Self.size)
        window.contentView = host

        switch mode {
        case .lockScreen:
            window.ignoresMouseEvents = true
            window.level = .screenSaver
            window.alphaValue = 0
        case .desktop:
            // Just above the desktop icons, below every normal app window.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.ignoresMouseEvents = false
            window.isMovableByWindowBackground = true
            NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.saveOrigin() }
            }
        }
    }

    func attachAboveLockScreen() {
        guard mode == .lockScreen else { return }
        window.orderFrontRegardless()
        isAboveLockScreen = SkyLight.moveToLockScreenSpace(window)
    }

    func reposition(lower: Bool) {
        guard let screen = NSScreen.screens.first else { return }
        if mode == .desktop, let saved = UserDefaults.standard.string(forKey: Self.originKey) {
            let p = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.insetBy(dx: -50, dy: -50).contains(p) }) {
                window.setFrameOrigin(p)
                return
            }
        }
        let f = screen.frame
        let size = window.frame.size
        let y = lower
            ? f.minY + f.height * 0.14
            : f.midY - size.height / 2 - f.height * 0.04
        window.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: y))
    }

    func resetDesktopPosition(lower: Bool) {
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        reposition(lower: lower)
    }

    func setVisible(_ visible: Bool) {
        switch mode {
        case .lockScreen:
            // Never order out: that would pull the window out of the lock-screen space.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                window.animator().alphaValue = visible ? 1 : 0
            }
        case .desktop:
            if visible {
                window.alphaValue = 0
                window.orderFront(nil)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.35
                    window.animator().alphaValue = 1
                }
            } else {
                window.orderOut(nil) // fully removed so it can't block clicks
            }
        }
    }

    private func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: Self.originKey)
    }
}

/// Lets the borderless desktop window be dragged by its content.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
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
