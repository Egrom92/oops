import AppKit
import Carbon.HIToolbox
import Layouts
import ServiceManagement

/// Listens for the chosen trigger (see Trigger). A tap of modifiers is seen by watching modifier changes only;
/// ordinary keys are watched just while those modifiers are held, to tell the tap apart from Ctrl+Option+something.
/// A key combination is a Carbon hotkey; the conversion then waits for the modifiers to be released.
@MainActor
final class Hotkey {
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var armedAt: Date?
    private var carbonRef: EventHotKeyRef?
    private var carbonHandler: EventHandlerRef?
    private let action: () -> Void
    private var trigger = Trigger.current

    init(action: @escaping () -> Void) { self.action = action }

    /// Starts listening for Trigger.current. Returns false if a key combination is taken by another app.
    @discardableResult
    func start() -> Bool {
        stop()
        trigger = Trigger.current
        if let code = trigger.keyCode { return registerCarbon(code) }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            MainActor.assumeIsolated { self?.flagsChanged(e.modifierFlags) }
        }
        return true
    }

    func stop() {
        disarm()
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        flagsMonitor = nil
        if let r = carbonRef { UnregisterEventHotKey(r) }
        carbonRef = nil
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let f = flags.intersection(Trigger.modMask.union(.function))
        let want = trigger.mods
        if !f.subtracting(want).isEmpty { disarm(); return }   // another modifier joined in: not our tap
        if f == want {
            if trigger.side != 0 && flags.rawValue & trigger.side == 0 { disarm(); return }   // the other Cmd/Shift…
            guard armedAt == nil else { return }
            armedAt = Date()
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] _ in MainActor.assumeIsolated { self?.disarm() }
            }
        } else if f.isEmpty {
            let tapped = armedAt.map { Date().timeIntervalSince($0) < 1 } ?? false
            disarm()
            if tapped { action() }
        }
    }

    private func disarm() {
        armedAt = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
    }

    private func registerCarbon(_ code: Int) -> Bool {
        if carbonHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let me = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, ctx in
                guard let ctx else { return noErr }
                let hk = Unmanaged<Hotkey>.fromOpaque(ctx).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { hk.firedCarbon() } }
                return noErr
            }, 1, &spec, me, &carbonHandler)
        }
        var ref: EventHotKeyRef?
        let st = RegisterEventHotKey(UInt32(code), trigger.carbonModifiers, EventHotKeyID(signature: 0x4F4F5053 /* OOPS */, id: 1),
                                     GetApplicationEventTarget(), 0, &ref)
        guard st == noErr, let ref else { return false }
        carbonRef = ref
        return true
    }

    /// The combination was pressed: wait (up to 1.5 s) until the keys are let go, so they don't mix into ⌘C / ⌘V.
    private func firedCarbon() {
        let t0 = Date()
        func check() {
            if NSEvent.modifierFlags.intersection(Trigger.modMask).isEmpty || Date().timeIntervalSince(t0) > 1.5 { action(); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { MainActor.assumeIsolated { check() } }
        }
        check()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let fixer = Fixer()
    private lazy var hotkey = Hotkey { [weak self] in
        guard let self else { return }
        Task { @MainActor in await self.fixer.run() }
    }
    private var statusItem: NSStatusItem?
    private var layoutsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var loginItem: NSMenuItem?
    private var hintItem: NSMenuItem?
    private var triggerItems: [(Trigger, NSMenuItem)] = []
    private let customItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let recorder = TriggerRecorder()
    private var waitingForAccess: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-login") {   // used by uninstall.sh
            try? SMAppService.mainApp.unregister()
            NSApp.terminate(nil)
            return
        }
        setupMenu()
        enableLoginItemOnce()
        if AXIsProcessTrusted() {
            hotkey.start()
        } else {
            askForAccess()
        }
    }

    // Keyboard watching and the ⌘C / ⌘V presses need Accessibility; start as soon as it is granted.
    private func askForAccess() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        waitingForAccess = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard AXIsProcessTrusted() else { return }
                t.invalidate()
                self?.hotkey.start()
            }
        }
    }

    private func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Oops")
        img?.isTemplate = true
        item.button?.image = img
        let menu = NSMenu()
        menu.delegate = self
        let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        hintItem = hint
        let trigger = NSMenuItem(title: "Сочетание клавиш", action: nil, keyEquivalent: "")
        let triggerMenu = NSMenu()
        for (n, t) in Trigger.presets.enumerated() {
            let i = NSMenuItem(title: t.title, action: #selector(pickTrigger(_:)), keyEquivalent: "")
            i.target = self
            i.tag = n
            triggerItems.append((t, i))
            triggerMenu.addItem(i)
        }
        customItem.isEnabled = false
        triggerMenu.addItem(.separator())
        triggerMenu.addItem(customItem)
        let record = NSMenuItem(title: "Своё сочетание…", action: #selector(recordTrigger), keyEquivalent: "")
        record.target = self
        triggerMenu.addItem(record)
        trigger.submenu = triggerMenu
        layoutsItem.isEnabled = false
        let login = NSMenuItem(title: "Запускать при входе в систему", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        loginItem = login
        menu.items = [hint, layoutsItem, .separator(), trigger, login, .separator(),
                      NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")]
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        hintItem?.title = "\(Trigger.current.title) — исправить раскладку"
        let cur = Trigger.current
        for (t, i) in triggerItems { i.state = t == cur ? .on : .off }
        let isCustom = !Trigger.presets.contains(cur)
        customItem.isHidden = !isCustom
        customItem.title = cur.title
        customItem.state = isCustom ? .on : .off
        let names = KeyboardLayout.enabled().map(\.name)
        layoutsItem.title = AXIsProcessTrusted()
            ? (names.count >= 2 ? "Раскладки: " + names.joined(separator: ", ") : "Включите хотя бы две раскладки")
            : "Нужен доступ: Универсальный доступ → Oops"
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func pickTrigger(_ sender: NSMenuItem) { use(Trigger.presets[sender.tag]) }

    @objc private func recordTrigger() {
        hotkey.stop()   // so the keys pressed while recording don't convert anything
        recorder.record { [weak self] t in
            guard let self else { return }
            if let t { self.use(t) } else if AXIsProcessTrusted() { self.hotkey.start() }
        }
    }

    private func use(_ t: Trigger) {
        let old = Trigger.current
        Trigger.current = t
        guard AXIsProcessTrusted() else { return }   // starts once access is granted
        if !hotkey.start() {
            Trigger.current = old
            hotkey.start()
            let a = NSAlert()
            a.messageText = "\(t.title) уже занято"
            a.informativeText = "Это сочетание перехватывает другая программа или macOS. Выберите другое."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
    }

    @objc private func toggleLogin() {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() } else { try? SMAppService.mainApp.register() }
    }

    private func enableLoginItemOnce() {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"),
              !UserDefaults.standard.bool(forKey: "loginItemConfigured") else { return }
        if (try? SMAppService.mainApp.register()) != nil { UserDefaults.standard.set(true, forKey: "loginItemConfigured") }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
