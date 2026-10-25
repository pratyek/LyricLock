import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts via Carbon hot keys. They work from any app and
/// need no Accessibility permission. Each one has a tag so it can be removed again.
@MainActor
final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [String: (id: UInt32, ref: EventHotKeyRef?)] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    /// ⌃⌥⌘ (Control-Option-Command): a combo apps practically never use, so nothing is stolen.
    nonisolated static let ctrlOptCmd = UInt32(controlKey | optionKey | cmdKey)

    func register(keyCode: Int, modifiers: UInt32 = HotKeys.ctrlOptCmd, tag: String,
                  _ action: @escaping () -> Void) {
        install()
        unregister(tag: tag)
        let id = nextID
        nextID += 1
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C594C4B), id: id) // "LYLK"
        RegisterEventHotKey(UInt32(keyCode), modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs[tag] = (id, ref)
    }

    func unregister(tag: String) {
        guard let entry = refs.removeValue(forKey: tag) else { return }
        if let ref = entry.ref { UnregisterEventHotKey(ref) }
        handlers[entry.id] = nil
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

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
