import AppKit
import Carbon

final class HotKey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var current: (UInt32, UInt32)?
    var action: (() -> Void)?
    init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            Unmanaged<HotKey>.fromOpaque(context).takeUnretainedValue().action?()
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }
    func register(key: UInt32, modifiers: UInt32) -> Bool {
        if let current, current.0 == key, current.1 == modifiers { return true }
        var next: EventHotKeyRef?
        let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: 0x434C4950, id: 1), GetApplicationEventTarget(), 0, &next)
        guard status == noErr else { return false }
        if let reference { UnregisterEventHotKey(reference) }
        reference = next
        current = (key, modifiers)
        return true
    }
    static func carbon(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value: UInt32 = 0
        if flags.contains(.command) { value |= UInt32(cmdKey) }
        if flags.contains(.shift) { value |= UInt32(shiftKey) }
        if flags.contains(.option) { value |= UInt32(optionKey) }
        if flags.contains(.control) { value |= UInt32(controlKey) }
        return value
    }
}

final class ShortcutRecorder: NSButton {
    var recorded: ((NSEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        title = "Press a shortcut (Esc to cancel)"
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self { keyDown(with: event); return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.makeFirstResponder(nil); title = UserDefaults.standard.string(forKey: "shortcutLabel") ?? "⇧⌘V"; return }
        guard !event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { NSSound.beep(); return }
        recorded?(event)
        window?.makeFirstResponder(nil)
    }
}
