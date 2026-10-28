// The settings, in UserDefaults; the OpenRouter key in the Keychain. On the first launch the
// Tauri app's settings.json (same bundle identifier, same folder) is read once, so moving from
// one build to the other keeps the shortcuts, the AI and the overlay as they were.
import AppKit
import Carbon.HIToolbox
import Foundation
import Security

enum TriggerMode: String, CaseIterable { case hold, toggle }

enum RefineLevel: String, CaseIterable { case light, rewrite }

/// The nine places the overlay can sit, on the display with the cursor.
enum OverlayPosition: String, CaseIterable {
    case topLeft = "top-left", top, topRight = "top-right"
    case left, center, right
    case bottomLeft = "bottom-left", bottom, bottomRight = "bottom-right"

    var title: String {
        switch self {
        case .topLeft: return L("ov.topLeft")
        case .top: return L("ov.top")
        case .topRight: return L("ov.topRight")
        case .left: return L("ov.left")
        case .center: return L("ov.center")
        case .right: return L("ov.right")
        case .bottomLeft: return L("ov.bottomLeft")
        case .bottom: return L("ov.bottom")
        case .bottomRight: return L("ov.bottomRight")
        }
    }
}

/// Translation targets, in menu order.
let languageCodes = ["pt", "en", "es", "fr", "de", "it", "ja", "ko", "zh", "ru"]
/// What Parakeet hears among them: European languages only.
let spokenLanguageCodes = ["pt", "en", "es", "fr", "de", "it", "ru"]

@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var dictationShortcut: Shortcut? { didSet { saveShortcut("dictationShortcut", dictationShortcut); onShortcutsChange() } }
    @Published var translateShortcut: Shortcut? { didSet { saveShortcut("translateShortcut", translateShortcut); onShortcutsChange() } }
    @Published var triggerMode: TriggerMode { didSet { defaults.set(triggerMode.rawValue, forKey: "triggerMode") } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var autoPaste: Bool { didSet { defaults.set(autoPaste, forKey: "autoPaste") } }
    /// A CoreAudio device UID; nil follows the system's default input.
    @Published var microphone: String? { didSet { defaults.set(microphone, forKey: "microphone"); onMicrophoneChange() } }
    @Published var keepMicrophoneWarm: Bool { didSet { defaults.set(keepMicrophoneWarm, forKey: "keepMicrophoneWarm"); onMicrophoneChange() } }
    @Published var escCancels: Bool { didSet { defaults.set(escCancels, forKey: "escCancels") } }
    @Published var sounds: Bool { didSet { defaults.set(sounds, forKey: "sounds") } }
    @Published var muteWhileDictating: Bool { didSet { defaults.set(muteWhileDictating, forKey: "muteWhileDictating") } }
    @Published var keepModelLoaded: Bool { didSet { defaults.set(keepModelLoaded, forKey: "keepModelLoaded"); onModelChange() } }
    @Published var glossary: [String] { didSet { defaults.set(glossary, forKey: "glossary") } }
    @Published var refine: Bool { didSet { defaults.set(refine, forKey: "refine") } }
    @Published var refineLevel: RefineLevel { didSet { defaults.set(refineLevel.rawValue, forKey: "refineLevel") } }
    @Published var translateEnabled: Bool { didSet { defaults.set(translateEnabled, forKey: "translateEnabled"); onShortcutsChange() } }
    @Published var targetLanguage: String { didSet { defaults.set(targetLanguage, forKey: "targetLanguage") } }
    @Published var openRouterModel: String { didSet { defaults.set(openRouterModel, forKey: "openRouterModel") } }
    @Published var openRouterKey: String { didSet { Keychain.set(openRouterKey, account: "openrouter") } }
    @Published var overlayPosition: OverlayPosition { didSet { defaults.set(overlayPosition.rawValue, forKey: "overlayPosition") } }
    @Published var overlayShowText: Bool { didSet { defaults.set(overlayShowText, forKey: "overlayShowText") } }
    @Published var overlayShowTimer: Bool { didSet { defaults.set(overlayShowTimer, forKey: "overlayShowTimer") } }
    /// 0 keeps history in memory only.
    @Published var historyDays: Int { didSet { defaults.set(historyDays, forKey: "historyDays"); onHistoryDaysChange() } }

    var onShortcutsChange: () -> Void = {}
    var onMicrophoneChange: () -> Void = {}
    var onModelChange: () -> Void = {}
    var onHistoryDaysChange: () -> Void = {}

    static let defaultDictation = Shortcut(keyCode: UInt32(kVK_Space), modifiers: [.command, .shift])
    static let defaultTranslate = Shortcut(keyCode: UInt32(kVK_ANSI_T), modifiers: [.command, .shift])

    init() {
        if !UserDefaults.standard.bool(forKey: "importedTauriSettings") {
            TauriSettings.importOnce(into: UserDefaults.standard)
        }
        let d = UserDefaults.standard
        dictationShortcut = Self.loadShortcut("dictationShortcut", d, default: Self.defaultDictation)
        translateShortcut = Self.loadShortcut("translateShortcut", d, default: Self.defaultTranslate)
        triggerMode = TriggerMode(rawValue: d.string(forKey: "triggerMode") ?? "") ?? .toggle
        language = d.string(forKey: "language") ?? "pt"
        autoPaste = d.object(forKey: "autoPaste") as? Bool ?? true
        microphone = d.string(forKey: "microphone")
        keepMicrophoneWarm = d.object(forKey: "keepMicrophoneWarm") as? Bool ?? false
        escCancels = d.object(forKey: "escCancels") as? Bool ?? true
        sounds = d.object(forKey: "sounds") as? Bool ?? false
        muteWhileDictating = d.object(forKey: "muteWhileDictating") as? Bool ?? false
        keepModelLoaded = d.object(forKey: "keepModelLoaded") as? Bool ?? true
        glossary = d.stringArray(forKey: "glossary") ?? []
        refine = d.object(forKey: "refine") as? Bool ?? false
        refineLevel = RefineLevel(rawValue: d.string(forKey: "refineLevel") ?? "") ?? .light
        translateEnabled = d.object(forKey: "translateEnabled") as? Bool ?? true
        targetLanguage = d.string(forKey: "targetLanguage") ?? "en"
        openRouterModel = d.string(forKey: "openRouterModel") ?? "google/gemini-2.5-flash-lite"
        openRouterKey = Keychain.get(account: "openrouter") ?? ""
        overlayPosition = OverlayPosition(rawValue: d.string(forKey: "overlayPosition") ?? "") ?? .topRight
        overlayShowText = d.object(forKey: "overlayShowText") as? Bool ?? true
        overlayShowTimer = d.object(forKey: "overlayShowTimer") as? Bool ?? true
        historyDays = d.object(forKey: "historyDays") as? Int ?? 7
    }

    /// Never set: the default. Removed on purpose ("none"): no shortcut, never the default.
    private static func loadShortcut(_ key: String, _ d: UserDefaults, default value: Shortcut) -> Shortcut? {
        guard let data = d.data(forKey: key) else { return value }
        if data == Data("none".utf8) { return nil }
        return (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? value
    }

    private func saveShortcut(_ key: String, _ value: Shortcut?) {
        let data = value.flatMap { try? JSONEncoder().encode($0) } ?? Data("none".utf8)
        defaults.set(data, forKey: key)
    }
}

/// ~/Library/Application Support, or STT_DATA_DIR for end-to-end runs: FileManager reads the
/// real home whatever HOME says, and a test must never touch the person's history or settings.
enum DataFolder {
    static let root: URL = ProcessInfo.processInfo.environment["STT_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
}

/// The Tauri build's settings.json (tauri-plugin-store, camelCase keys), read once.
enum TauriSettings {
    static var folder: URL { DataFolder.root.appendingPathComponent("click.ciromaciel.speech-to-text") }

    static func importOnce(into d: UserDefaults) {
        defer { d.set(true, forKey: "importedTauriSettings") }
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("settings.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        func shortcut(_ key: String, _ to: String) {
            guard let text = json[key] as? String else { return }
            let value = parse(accelerator: text)
            d.set(value.flatMap { try? JSONEncoder().encode($0) } ?? Data("none".utf8), forKey: to)
        }
        shortcut("hotkey", "dictationShortcut")
        shortcut("translateHotkey", "translateShortcut")
        let renames: [(String, String)] = [
            ("triggerMode", "triggerMode"), ("language", "language"), ("autoPaste", "autoPaste"),
            ("escCancels", "escCancels"), ("sounds", "sounds"), ("muteWhileDictating", "muteWhileDictating"),
            ("keepModelLoaded", "keepModelLoaded"), ("refinementEnabled", "refine"), ("refinementLevel", "refineLevel"),
            ("translateEnabled", "translateEnabled"), ("targetLanguage", "targetLanguage"), ("openrouterModel", "openRouterModel"),
            ("overlayPosition", "overlayPosition"), ("overlayShowText", "overlayShowText"),
            ("overlayShowTimer", "overlayShowTimer"), ("historyDays", "historyDays"), ("preHeatMicrophone", "keepMicrophoneWarm"),
        ]
        for (from, to) in renames {
            if let value = json[from], !(value is NSNull), !((value as? String)?.isEmpty ?? false) { d.set(value, forKey: to) }
        }
        if let glossary = json["refinementGlossary"] as? String {
            let terms = glossary.split(whereSeparator: { "\n,;".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            d.set(terms, forKey: "glossary")
        }
        if let key = json["openrouterApiKey"] as? String, !key.isEmpty, Keychain.get(account: "openrouter") == nil {
            Keychain.set(key, account: "openrouter")
        }
        // The webview's microphone id has no meaning outside the webview: the system default.
    }

    /// "CommandOrControl+Shift+Space", "Command+2": Tauri's accelerator syntax.
    static func parse(accelerator: String) -> Shortcut? {
        var mods: NSEvent.ModifierFlags = []
        var key: Int?
        for raw in accelerator.split(separator: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces).lowercased()
            switch part {
            case "commandorcontrol", "cmdorctrl", "command", "cmd", "meta", "super", "leftcommand", "rightcommand": mods.insert(.command)
            case "control", "ctrl", "leftcontrol", "rightcontrol": mods.insert(.control)
            case "shift", "leftshift", "rightshift": mods.insert(.shift)
            case "alt", "option", "leftalt", "rightalt", "rightoption": mods.insert(.option)
            default: key = keyCode(part)
            }
        }
        guard let key else { return nil }
        return Shortcut(keyCode: UInt32(key), modifiers: mods)
    }

    private static func keyCode(_ name: String) -> Int? {
        let named: [String: Int] = [
            "space": kVK_Space, "enter": kVK_Return, "escape": kVK_Escape, "esc": kVK_Escape, "tab": kVK_Tab,
            "backspace": kVK_Delete, "delete": kVK_ForwardDelete, "home": kVK_Home, "end": kVK_End,
            "pageup": kVK_PageUp, "pagedown": kVK_PageDown, "arrowup": kVK_UpArrow, "up": kVK_UpArrow,
            "arrowdown": kVK_DownArrow, "down": kVK_DownArrow, "arrowleft": kVK_LeftArrow, "left": kVK_LeftArrow,
            "arrowright": kVK_RightArrow, "right": kVK_RightArrow,
            "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
            "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
            "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
            "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
            "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        return named[name]
    }
}

/// One generic password per account, under the app's own service.
enum Keychain {
    private static let service = "click.ciromaciel.speech-to-text"

    static func get(account: String) -> String? {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}
