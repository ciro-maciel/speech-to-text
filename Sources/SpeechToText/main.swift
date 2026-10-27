// Speech to Text for macOS: the letter S in the menu bar, the overlay, and one window in the
// Cleaner frame. Press the shortcut, speak, and the text lands where the cursor is; Parakeet
// runs on this Mac, in this process.
import AppKit
import AVFoundation
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private let history = History()
    private let recorder = Recorder()
    private lazy var dictation = Dictation(settings: settings, history: history, recorder: recorder)
    private let nav = Navigation()
    private let hotKeys = HotKeys()
    private var overlay: OverlayController?
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var watches: Set<AnyCancellable> = []
    private var ringFrame = 0
    private var ringTimer: Timer?
    private var windowTimer: Timer?
    private var areShortcutsPaused = false

    private enum HotKey: UInt32 { case dictation = 1, translate = 2, pasteLast = 3, escape = 4 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy at a time: a second launch shows the first one's window and leaves.
        let id = Bundle.main.bundleIdentifier ?? ""
        if NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0 != .current }) {
            DistributedNotificationCenter.default().postNotificationName(.init("\(id).open"), object: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("\(id).open"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openWindow(nil) }
        }

        NSApp.setActivationPolicy(.accessory)
        // The system is light for now; the app forces it.
        NSApp.appearance = NSAppearance(named: .aqua)
        Zen.registerFonts()

        history.load(days: settings.historyDays)
        overlay = OverlayController(dictation: dictation, recorder: recorder, settings: settings)
        dictation.onEscapeNeeded = { [weak self] needed in self?.setEscape(needed) }
        dictation.openWindow = { [weak self] pane in self?.openWindow(pane) }
        settings.onShortcutsChange = { [weak self] in self?.registerShortcuts() }
        settings.onMicrophoneChange = { [weak self] in self?.applyMicrophone() }
        settings.onModelChange = { [weak self] in self?.dictation.applyKeepLoaded() }
        settings.onHistoryDaysChange = { [weak self] in
            guard let self else { return }
            self.history.setRetention(days: self.settings.historyDays)
        }

        setUpMenuBar()
        registerShortcuts()
        // Ask for the microphone before opening it: macOS answers an app without it with silence.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            Permissions.requestMicrophone { [weak self] _ in self?.applyMicrophone() }
        } else {
            applyMicrophone()
        }
        dictation.preload()
        E2E.watch { [weak self] command in self?.run(command) }

        if !Recorder.isAuthorized || !Permissions.isAccessibilityOn || !Transcriber.isInstalled {
            openWindow(Transcriber.isInstalled ? .permissions : .transcription)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        recorder.stopEngine()
        SystemAudio.restoreNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow(nil)
        return true
    }

    private func applyMicrophone() {
        recorder.configure(deviceUID: settings.microphone, warm: settings.keepMicrophoneWarm)
    }

    // MARK: - Shortcuts

    private func registerShortcuts() {
        for id in [HotKey.dictation, .translate, .pasteLast] { hotKeys.unregister(id: id.rawValue) }
        // An end-to-end run is driven through its trigger file and never takes a key from the person.
        guard !areShortcutsPaused, !E2E.isOn else { return }
        if let s = settings.dictationShortcut {
            hotKeys.register(id: HotKey.dictation.rawValue, shortcut: s) { [weak self] isDown in
                isDown ? self?.dictation.pressed(.transcribe) : self?.dictation.released(.transcribe)
            }
        }
        if settings.translateEnabled, let s = settings.translateShortcut {
            hotKeys.register(id: HotKey.translate.rawValue, shortcut: s) { [weak self] isDown in
                isDown ? self?.dictation.pressed(.translate) : self?.dictation.released(.translate)
            }
        }
        let pasteLast = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: [.command, .option])
        hotKeys.register(id: HotKey.pasteLast.rawValue, shortcut: pasteLast) { [weak self] isDown in
            if isDown, self?.dictation.isPaused == false { self?.dictation.pasteLast() }
        }
    }

    /// Esc is held only while listening, so it is not taken from other apps the rest of the time.
    private func setEscape(_ needed: Bool) {
        if needed, !E2E.isOn {
            hotKeys.register(id: HotKey.escape.rawValue, shortcut: Shortcut(keyCode: UInt32(kVK_Escape), modifiers: [])) { [weak self] isDown in
                if isDown { self?.dictation.cancel() }
            }
        } else {
            hotKeys.unregister(id: HotKey.escape.rawValue)
        }
    }

    // MARK: - Menu bar

    private func setUpMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        dictation.$activity.combineLatest(dictation.$pausedUntil)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateGlyph() }
            .store(in: &watches)
        dictation.$listeningSince.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateTooltip() }.store(in: &watches)
        updateGlyph()
    }

    /// The S never leaves (13-favicon.md): a dot while listening, a turning ring while processing,
    /// a dash when paused, the S in outline when a permission or the model is missing.
    private func updateGlyph() {
        ringTimer?.invalidate()
        ringTimer = nil
        let name: String
        if dictation.isPaused {
            name = "menubar-paused"
        } else {
            switch dictation.activity {
            case .listening: name = "menubar-listening"
            case .processing:
                name = "menubar-processing-\(ringFrame % 8)"
                ringTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.ringFrame += 1
                        self.setGlyph("menubar-processing-\(self.ringFrame % 8)")
                    }
                }
            case .idle:
                name = needsAttention ? "menubar-attention" : "menubar"
            }
        }
        setGlyph(name)
        updateTooltip()
    }

    private var drawnGlyph = ""
    private func setGlyph(_ name: String) {
        guard name != drawnGlyph else { return }
        drawnGlyph = name
        // Image and template flag set together, before the button sees it: no black frame.
        if let image = Icon.image(name)?.copy() as? NSImage {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            statusItem.button?.image = image
        } else {
            statusItem.button?.title = "S"
        }
    }

    private var needsAttention: Bool { !Recorder.isAuthorized || !Permissions.isAccessibilityOn || !Transcriber.isInstalled }

    private func updateTooltip() {
        if let since = dictation.listeningSince {
            statusItem.button?.toolTip = "Speech to Text · " + L("menu.listening", OverlayView.clock(Date().timeIntervalSince(since)))
        } else {
            statusItem.button?.toolTip = "Speech to Text · " + statusText
        }
    }

    private var statusText: String {
        if let until = dictation.pausedUntil, until > Date() {
            return L("menu.pausedUntil", until.formatted(date: .omitted, time: .shortened))
        }
        let keys = settings.dictationShortcut?.text ?? L("hotkey.none")
        return L(settings.triggerMode == .hold ? "menu.ready.hold" : "menu.ready.toggle", keys)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let pasteLast = item(L("menu.pasteLast"), #selector(pasteLastFromMenu), key: "v")
        pasteLast.keyEquivalentModifierMask = [.command, .option]
        pasteLast.isEnabled = history.lastText != nil
        menu.addItem(pasteLast)
        let recent = NSMenuItem(title: L("menu.recent"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        let texts = history.recentTexts(5)
        if texts.isEmpty {
            let none = NSMenuItem(title: L("menu.recent.none"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            recentMenu.addItem(none)
        }
        for text in texts {
            let entry = item(Self.truncate(text, 60), #selector(copyRecent(_:)))
            entry.representedObject = text
            recentMenu.addItem(entry)
        }
        recent.submenu = recentMenu
        menu.addItem(recent)
        menu.addItem(.separator())

        let refine = item(L("menu.refine"), #selector(toggleRefine))
        refine.state = settings.refine ? .on : .off
        menu.addItem(refine)
        let target = NSMenuItem(title: L("menu.translateTo", L("lang.\(settings.targetLanguage)")), action: nil, keyEquivalent: "")
        target.isEnabled = settings.translateEnabled
        let targetMenu = NSMenu()
        for code in languageCodes {
            let choice = item(L("lang.\(code)"), #selector(pickTarget(_:)))
            choice.representedObject = code
            choice.state = code == settings.targetLanguage ? .on : .off
            targetMenu.addItem(choice)
        }
        target.submenu = targetMenu
        menu.addItem(target)

        recorder.refreshMicrophones()
        let micName = settings.microphone.flatMap { uid in recorder.microphones.first { $0.uid == uid }?.name } ?? L("dict.mic.default")
        let mic = NSMenuItem(title: L("menu.microphone", Self.truncate(micName, 32)), action: nil, keyEquivalent: "")
        let micMenu = NSMenu()
        let systemDefault = item(L("dict.mic.default"), #selector(pickMicrophone(_:)))
        systemDefault.representedObject = ""
        systemDefault.state = settings.microphone == nil ? .on : .off
        micMenu.addItem(systemDefault)
        for device in recorder.microphones {
            let choice = item(Self.truncate(device.name, 48), #selector(pickMicrophone(_:)))
            choice.representedObject = device.uid
            choice.state = device.uid == settings.microphone ? .on : .off
            micMenu.addItem(choice)
        }
        mic.submenu = micMenu
        menu.addItem(mic)
        menu.addItem(.separator())

        if dictation.isPaused {
            menu.addItem(item(L("menu.resume", dictation.pausedUntil!.formatted(date: .omitted, time: .shortened)), #selector(resume)))
        } else {
            menu.addItem(item(L("menu.pause"), #selector(pauseHour)))
        }
        if !Recorder.isAuthorized {
            menu.addItem(item(L("menu.micBlocked"), #selector(openPermissions)))
        } else if !Permissions.isAccessibilityOn {
            menu.addItem(item(L("menu.pasteOff"), #selector(openPermissions)))
        }
        menu.addItem(.separator())
        menu.addItem(item(L("menu.settings"), #selector(openFromMenu), key: ","))
        menu.addItem(.separator())
        menu.addItem(item(L("menu.quit"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    private static func truncate(_ text: String, _ max: Int) -> String {
        text.count <= max ? text : String(text.prefix(max - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    @objc private func pasteLastFromMenu() { dictation.pasteLast() }
    @objc private func copyRecent(_ sender: NSMenuItem) { if let text = sender.representedObject as? String { Paster.copy(text) } }
    @objc private func toggleRefine() { settings.refine.toggle() }
    @objc private func pickTarget(_ sender: NSMenuItem) { if let code = sender.representedObject as? String { settings.targetLanguage = code } }
    @objc private func pickMicrophone(_ sender: NSMenuItem) {
        let uid = sender.representedObject as? String ?? ""
        settings.microphone = uid.isEmpty ? nil : uid
    }
    @objc private func pauseHour() { dictation.pause(for: 3600) }
    @objc private func resume() { dictation.pause(for: 0) }
    @objc private func openPermissions() {
        Permissions.requestAccessibility()
        openWindow(.permissions)
    }
    @objc private func openFromMenu() { openWindow(nil) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Window

    private func openWindow(_ pane: Pane?) {
        if let pane { nav.pane = pane }
        if window == nil {
            let root = AppView(nav: nav, settings: settings, dictation: dictation, history: history, recorder: recorder) { [weak self] paused in
                self?.areShortcutsPaused = paused
                self?.registerShortcuts()
            }
            window = MacShell.window(title: "Speech to Text", size: CGSize(width: 1040, height: 760),
                                     minSize: CGSize(width: 960, height: 640), autosave: "SpeechToTextWindow", root: root)
            window?.appearance = NSAppearance(named: .aqua)
        }
        // The permission lines follow the system while the window is open.
        windowTimer?.invalidate()
        windowTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.window?.isVisible == true { self.nav.tick += 1; self.updateGlyph() } else { self.windowTimer?.invalidate() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - End-to-end commands

    private func run(_ command: String) {
        let parts = command.split(separator: " ", maxSplits: 1).map(String.init)
        switch (parts.first, parts.count > 1 ? parts[1] : "") {
        case ("press", let mode): dictation.pressed(DictationMode(rawValue: mode) ?? .transcribe)
        case ("release", let mode): dictation.released(DictationMode(rawValue: mode) ?? .transcribe)
        case ("escape", _): dictation.cancel()
        case ("paste-last", _): dictation.pasteLast()
        case ("open", let pane):
            openWindow(Pane(rawValue: pane))
            NSLog("[e2e] window %d", window?.windowNumber ?? 0)
        case ("keep-loaded", let value): settings.keepModelLoaded = value == "true"
        // The same path as the microphone menu and the settings' select.
        case ("microphone", let uid): settings.microphone = uid == "default" ? nil : uid
        case ("download", _): dictation.downloadModel()
        case ("cancel-download", _): dictation.cancelDownload()
        default: NSLog("[e2e] unknown command: \(command)")
        }
    }
}

// Top-level code runs on the main thread; say so, since AppDelegate is main-actor isolated.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
