import AppKit
import Layouts
import ServiceManagement

/// Tap and release Ctrl+Option (no other key in between, under a second): the text is converted.
/// Only modifier changes are watched; ordinary keys only while Ctrl+Option are held, to tell
/// the shortcut apart from Ctrl+Option+something.
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
        let f = flags.intersection(.deviceIndependentFlagsMask)
        let ctrl = f.contains(.control), alt = f.contains(.option)
        if f.contains(.command) || f.contains(.shift) || f.contains(.function) { disarm(); return }
        if ctrl && alt {
            guard armedAt == nil else { return }
            armedAt = Date()
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) {
                [weak self] _ in MainActor.assumeIsolated { self?.disarm() }
            }
        } else if !ctrl && !alt {
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
        let img = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Layout Converter")
        img?.isTemplate = true
        item.button?.image = img
        let menu = NSMenu()
        menu.delegate = self
        let hint = NSMenuItem(title: "Ctrl+Option — исправить раскладку", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        layoutsItem.isEnabled = false
        let login = NSMenuItem(title: "Запускать при входе в систему", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        loginItem = login
        menu.items = [hint, layoutsItem, .separator(), login, .separator(),
                      NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")]
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        let names = KeyboardLayout.enabled().map(\.name)
        layoutsItem.title = AXIsProcessTrusted()
            ? (names.count >= 2 ? "Раскладки: " + names.joined(separator: ", ") : "Включите хотя бы две раскладки")
            : "Нужен доступ: Универсальный доступ → Layout Converter"
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
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
