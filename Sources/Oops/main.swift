import AppKit
import Layouts
import ServiceManagement

/// Which modifier keys to tap. Ctrl+Option by default; the user can pick another in the menu.
enum Trigger: String, CaseIterable {
    case ctrlOption, ctrlShift, optionShift, ctrlCmd, optionCmd, ctrlOptionShift

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .ctrlOption: [.control, .option]
        case .ctrlShift: [.control, .shift]
        case .optionShift: [.option, .shift]
        case .ctrlCmd: [.control, .command]
        case .optionCmd: [.option, .command]
        case .ctrlOptionShift: [.control, .option, .shift]
        }
    }

    var title: String {
        switch self {
        case .ctrlOption: "Ctrl+Option"
        case .ctrlShift: "Ctrl+Shift"
        case .optionShift: "Option+Shift"
        case .ctrlCmd: "Ctrl+Cmd"
        case .optionCmd: "Option+Cmd"
        case .ctrlOptionShift: "Ctrl+Option+Shift"
        }
    }

    static var current: Trigger {
        get { Trigger(rawValue: UserDefaults.standard.string(forKey: "trigger") ?? "") ?? .ctrlOption }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "trigger") }
    }
}

/// Tap and release the chosen modifiers (Ctrl+Option by default; no other key in between, under a second):
/// the text is converted. Only modifier changes are watched; ordinary keys only while the modifiers are held,
/// to tell the tap apart from a shortcut like Ctrl+Option+something.
@MainActor
final class Hotkey {
    private var flagsMonitor: Any?
    private var keyMonitor: Any?
    private var armedAt: Date?
    private let action: () -> Void

    init(action: @escaping () -> Void) { self.action = action }

    func start() {
        stop()
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            MainActor.assumeIsolated { self?.flagsChanged(e.modifierFlags) }
        }
    }

    func stop() {
        disarm()
        if let m = flagsMonitor { NSEvent.removeMonitor(m) }
        flagsMonitor = nil
    }

    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let f = flags.intersection([.control, .option, .shift, .command, .function])
        let want = Trigger.current.flags
        if !f.subtracting(want).isEmpty { disarm(); return }   // another modifier joined in: not our tap
        if f == want {
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
    private var triggerItems: [Trigger: NSMenuItem] = [:]
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
        for t in Trigger.allCases {
            let i = NSMenuItem(title: t.title, action: #selector(pickTrigger(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = t.rawValue
            triggerItems[t] = i
            triggerMenu.addItem(i)
        }
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
        for (t, i) in triggerItems { i.state = t == Trigger.current ? .on : .off }
        let names = KeyboardLayout.enabled().map(\.name)
        layoutsItem.title = AXIsProcessTrusted()
            ? (names.count >= 2 ? "Раскладки: " + names.joined(separator: ", ") : "Включите хотя бы две раскладки")
            : "Нужен доступ: Универсальный доступ → Oops"
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func pickTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let t = Trigger(rawValue: raw) else { return }
        Trigger.current = t   // read on every key change, so it works at once
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
