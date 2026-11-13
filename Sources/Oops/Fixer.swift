import AppKit
import Carbon
import Layouts

/// Converts the selection, or the last word before the cursor, into the other layout — by copying it,
/// converting and pasting it back (⌘C / ⌘V), then puts the clipboard back as it was.
@MainActor
final class Fixer {
    private var busy = false
    private let pb = NSPasteboard.general
    /// Layouts used most recently first (to know which Latin layout "the other one" is).
    private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: "recentLayouts") ?? []

    /// Terminals: ⌘⇧← doesn't select to the line start there, so only a selection is converted.
    private let noLastWord: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                                           "com.mitchellh.ghostty"]

    init() {
        noteLayout()
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.noteLayout() } }
    }

    private func noteLayout() {
        guard let id = KeyboardLayout.currentID() else { return }
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        recent = Array(recent.prefix(10))
        UserDefaults.standard.set(recent, forKey: "recentLayouts")
    }

    func run() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let saved = saveClipboard()

        // 1. The selection, if there is one.
        if let sel = await copy(), !sel.isEmpty {
            if let (text, target) = converted(sel), text != sel { paste(text, then: target) }
            await restore(saved)
            return
        }

        // 2. No selection: the last word before the cursor.
        if let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, noLastWord.contains(app) {
            await restore(saved)
            return
        }
        Keys.press(Keys.left, [.maskCommand, .maskShift])   // select to the line start
        guard let line = await copy() else { await restore(saved); return }   // the cursor was at the line start
        Keys.press(Keys.right, [])                           // drop the selection, cursor back in place
        let trail = String(line.reversed().prefix { $0.isWhitespace }.reversed())
        let body = line.dropLast(trail.count)
        let word = String(body.reversed().prefix { !$0.isWhitespace }.reversed())
        guard !word.isEmpty, let (text, target) = converted(word), text != word else { await restore(saved); return }
        for _ in 0..<(word.count + trail.count) { Keys.press(Keys.left, [.maskShift]) }
        paste(text + trail, then: target)
        await restore(saved)
    }

    private func converted(_ s: String) -> (String, String)? {
        guard let p = Converter.pick(for: s, layouts: KeyboardLayout.enabled(), current: KeyboardLayout.currentID(),
                                     recent: recent) else { return nil }
        return (Converter.convert(s, from: p.from, to: p.to), p.to.id)
    }

    /// ⌘C, and the copied text if the clipboard changed within a quarter of a second.
    private func copy() async -> String? {
        let count = pb.changeCount
        Keys.press(Keys.c, [.maskCommand])
        for _ in 0..<13 {
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pb.changeCount != count { return pb.string(forType: .string) }
        }
        return nil
    }

    private func paste(_ text: String, then layout: String) {
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))  // clipboard managers: skip it
        pb.writeObjects([item])
        Keys.press(Keys.v, [.maskCommand])
        KeyboardLayout.select(layout)
    }

    // MARK: clipboard

    private func saveClipboard() -> [[(NSPasteboard.PasteboardType, Data)]] {
        (pb.pasteboardItems ?? []).map { item in item.types.compactMap { t in item.data(forType: t).map { (t, $0) } } }
    }

    /// After the app has had time to paste, the clipboard gets its old contents back.
    private func restore(_ saved: [[(NSPasteboard.PasteboardType, Data)]]) async {
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !saved.isEmpty else { return }
        pb.clearContents()
        pb.writeObjects(saved.map { types in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        })
    }
}

/// Synthetic key presses (need Accessibility).
enum Keys {
    static let c: CGKeyCode = 8, v: CGKeyCode = 9, left: CGKeyCode = 123, right: CGKeyCode = 124

    static func press(_ key: CGKeyCode, _ flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
        usleep(5000)
    }
}
