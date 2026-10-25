import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts via Carbon hot keys. They work from any app and
/// need no Accessibility permission.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef?] = []
    private var installed = false

    /// ⌃⌥⌘ (Control-Option-Command): a combo apps practically never use, so nothing is stolen.
    nonisolated static let ctrlOptCmd = UInt32(controlKey | optionKey | cmdKey)

    func register(keyCode: Int, modifiers: UInt32 = HotKeys.ctrlOptCmd, _ action: @escaping () -> Void) {
        install()
        let id = UInt32(handlers.count + 1)
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C594C4B), id: id) // "LYLK"
        RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    func unregisterAll() {
        for ref in refs { if let ref { UnregisterEventHotKey(ref) } }
        refs.removeAll()
        handlers.removeAll()
    }

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeys.shared.fire(id) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
