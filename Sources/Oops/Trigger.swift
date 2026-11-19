import AppKit
import Carbon.HIToolbox

/// What converts the text. Either a tap of modifier keys (press and release, nothing else in between) —
/// Ctrl+Option by default, or e.g. the right ⌘ alone — or an ordinary key with modifiers, e.g. Ctrl+Option+Space.
struct Trigger: Equatable {
    /// Control / Option / Shift / Command.
    var mods: NSEvent.ModifierFlags
    /// For a tap of a single modifier: which physical key (left or right), as a device-dependent flag bit; 0 = either.
    var side: UInt = 0
    /// nil = a tap of the modifiers; otherwise the key pressed with them.
    var keyCode: Int? = nil

    static let modMask: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    static let presets: [Trigger] = [
        Trigger(mods: [.control, .option]), Trigger(mods: [.control, .shift]), Trigger(mods: [.option, .shift]),
        Trigger(mods: [.control, .command]), Trigger(mods: [.option, .command]), Trigger(mods: [.control, .option, .shift]),
    ]

    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK): tell the left key from the right one.
    static let sides: [(bit: UInt, flag: NSEvent.ModifierFlags, name: String)] = [
        (0x0001, .control, "Левый Ctrl"), (0x2000, .control, "Правый Ctrl"),
        (0x0002, .shift, "Левый Shift"), (0x0004, .shift, "Правый Shift"),
        (0x0020, .option, "Левый Option"), (0x0040, .option, "Правый Option"),
        (0x0008, .command, "Левый Cmd"), (0x0010, .command, "Правый Cmd"),
    ]

    var title: String {
        if keyCode == nil, side != 0, let s = Trigger.sides.first(where: { $0.bit == side }) { return s.name }
        var parts: [String] = []
        if mods.contains(.control) { parts.append("Ctrl") }
        if mods.contains(.option) { parts.append("Option") }
        if mods.contains(.shift) { parts.append("Shift") }
        if mods.contains(.command) { parts.append("Cmd") }
        if let k = keyCode { parts.append(Trigger.keyName(k)) }
        return parts.joined(separator: "+")
    }

    var carbonModifiers: UInt32 {
        var m = 0
        if mods.contains(.command) { m |= cmdKey }
        if mods.contains(.shift) { m |= shiftKey }
        if mods.contains(.option) { m |= optionKey }
        if mods.contains(.control) { m |= controlKey }
        return UInt32(m)
    }

    // MARK: saved choice

    static var current: Trigger {
        get {
            let d = UserDefaults.standard
            if let a = d.array(forKey: "trigger.v2") as? [Int], a.count == 3 {
                return Trigger(mods: NSEvent.ModifierFlags(rawValue: UInt(a[0])).intersection(modMask),
                               side: UInt(a[1]), keyCode: a[2] < 0 ? nil : a[2])
            }
            // The first version kept one of the presets by name.
            let old = ["ctrlOption": 0, "ctrlShift": 1, "optionShift": 2, "ctrlCmd": 3, "optionCmd": 4, "ctrlOptionShift": 5]
            if let s = d.string(forKey: "trigger"), let i = old[s] { return presets[i] }
            return presets[0]
        }
        set {
            UserDefaults.standard.set([Int(newValue.mods.rawValue), Int(newValue.side), newValue.keyCode ?? -1], forKey: "trigger.v2")
        }
    }

    // MARK: key names

    private static let named: [Int: String] = [
        kVK_Space: "Пробел", kVK_Return: "Enter", kVK_Tab: "Tab", kVK_Delete: "Delete", kVK_ForwardDelete: "Fn+Delete",
        kVK_Escape: "Esc", kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
    ]
    static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9,
                                         kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15]

    /// "Пробел", "F5", or the letter the key prints in the Latin layout ("Z", not "Я").
    static func keyName(_ code: Int) -> String {
        if let n = named[code] { return n }
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        let s = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var len = 0
            guard UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                 OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars) == noErr,
                  len > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: len)
        }
        let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return t.isEmpty ? "#\(code)" : t.uppercased()
    }
}

// MARK: - "Своё сочетание…": press what you want, the window remembers it

@MainActor
final class TriggerRecorder: NSObject, NSWindowDelegate {
    private var window: NSPanel?
    private let shown = NSTextField(labelWithString: "")
    private var monitor: Any?
    private var peak: NSEvent.ModifierFlags = []
    private var peakSide: UInt = 0
    private var onDone: (Trigger?) -> Void = { _ in }

    func record(_ done: @escaping (Trigger?) -> Void) {
        onDone = done
        if window == nil { window = makeWindow() }
        peak = []; peakSide = 0
        shown.stringValue = "…"
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e) }
            return nil
        }
    }

    private func makeWindow() -> NSPanel {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 170), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Своё сочетание для Oops"
        w.isReleasedWhenClosed = false
        w.level = .floating
        w.delegate = self
        let text = NSTextField(wrappingLabelWithString:
            "Нажмите и отпустите клавиши-модификаторы — например, только правый Cmd или Ctrl+Shift. " +
            "Или нажмите сочетание с обычной клавишей — например, Ctrl+Option+Пробел.\nEsc — отмена.")
        text.preferredMaxLayoutWidth = 380
        shown.font = .systemFont(ofSize: 22, weight: .semibold)
        shown.alignment = .center
        let stack = NSStackView(views: [text, shown])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 18, right: 20)
        w.contentView = stack
        return w
    }

    private func handle(_ e: NSEvent) {
        let f = e.modifierFlags.intersection(Trigger.modMask)
        if e.type == .flagsChanged {
            if f.isEmpty {
                guard !peak.isEmpty else { return }
                // A single modifier: remember which one (left/right); otherwise either side will do.
                let single = Trigger.sides.filter { peak == $0.flag }.first { peakSide & $0.bit != 0 }
                finish(Trigger(mods: peak, side: single?.bit ?? 0))
            } else {
                peak.formUnion(f)
                peakSide |= e.modifierFlags.rawValue & 0x207F
                shown.stringValue = Trigger(mods: peak).title
            }
            return
        }
        let code = Int(e.keyCode)
        if code == kVK_Escape && f.isEmpty { finish(nil); return }
        // An ordinary key needs Ctrl, Option or Cmd with it (with Shift alone it would fire on every capital letter).
        guard Trigger.functionKeys.contains(code) || !f.intersection([.control, .option, .command]).isEmpty else {
            NSSound.beep(); return
        }
        finish(Trigger(mods: f, keyCode: code))
    }

    private func finish(_ t: Trigger?) {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        window?.orderOut(nil)
        let done = onDone
        onDone = { _ in }
        done(t)
    }

    func windowWillClose(_ notification: Notification) { if monitor != nil { finish(nil) } }
}
