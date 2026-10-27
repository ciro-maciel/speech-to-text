// From the Windows app (applications/apps/windows/desktop/Sources/Windows/Shortcut.swift), unchanged.
import AppKit
import Carbon.HIToolbox

/// A key plus modifiers, as the person recorded it. Saved as JSON in the settings.
struct Shortcut: Codable, Hashable {
    let keyCode: UInt32
    /// NSEvent.ModifierFlags raw value, masked to ⌃⌥⇧⌘.
    let flags: UInt

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.flags = modifiers.intersection(Self.relevant).rawValue
    }

    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: flags) }

    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// F1–F20 work alone; every other key needs ⌃, ⌥ or ⌘ (⇧ alone would eat a capital letter).
    var isUsable: Bool {
        Self.functionKeys.keys.contains(Int(keyCode)) || !modifiers.intersection([.control, .option, .command]).isEmpty
    }

    // MARK: - Names

    private static let special: [Int: (glyph: String, icon: String?, menu: String)] = [
        kVK_LeftArrow: ("←", "arrow-left", "\u{F702}"), kVK_RightArrow: ("→", "arrow-right", "\u{F703}"),
        kVK_UpArrow: ("↑", "arrow-up", "\u{F700}"), kVK_DownArrow: ("↓", "arrow-down", "\u{F701}"),
        kVK_Return: ("↩", "corner-down-left", "\r"), kVK_ANSI_KeypadEnter: ("⌤", "corner-down-left", "\u{3}"),
        kVK_Delete: ("⌫", "backspace", "\u{8}"), kVK_ForwardDelete: ("⌦", nil, "\u{F728}"),
        kVK_Tab: ("⇥", nil, "\t"), kVK_Space: (L("key.space"), nil, " "), kVK_Escape: ("⎋", nil, "\u{1B}"),
        kVK_Home: ("↖", nil, "\u{F729}"), kVK_End: ("↘", nil, "\u{F72B}"),
        kVK_PageUp: ("⇞", nil, "\u{F72C}"), kVK_PageDown: ("⇟", nil, "\u{F72D}"),
    ]

    private static let functionKeys: [Int: Int] = [
        kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6, kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10,
        kVK_F11: 11, kVK_F12: 12, kVK_F13: 13, kVK_F14: 14, kVK_F15: 15, kVK_F16: 16, kVK_F17: 17, kVK_F18: 18, kVK_F19: 19, kVK_F20: 20,
    ]

    /// The key's own name: "F", "←", "F5", "Space". Letters follow the current keyboard layout.
    var keyName: String {
        if let s = Self.special[Int(keyCode)] { return s.glyph }
        if let f = Self.functionKeys[Int(keyCode)] { return "F\(f)" }
        return Self.character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    /// The key as a menu key equivalent (NSMenuItem draws it with the native glyphs).
    var menuKey: String {
        if let s = Self.special[Int(keyCode)] { return s.menu }
        if let f = Self.functionKeys[Int(keyCode)] { return String(UnicodeScalar(0xF703 + f)!) }
        return Self.character(for: keyCode)?.lowercased() ?? ""
    }

    /// The caps as drawn in the settings: a Tabler icon ("icon:…") or text.
    var caps: [String] {
        var g: [String] = []
        if modifiers.contains(.control) { g.append("icon:chevron-up") }
        if modifiers.contains(.option) { g.append("icon:option") }
        if modifiers.contains(.shift) { g.append("icon:arrow-big-up") }
        if modifiers.contains(.command) { g.append("icon:command") }
        if let icon = Self.special[Int(keyCode)]?.icon { g.append("icon:\(icon)") } else { g.append(keyName) }
        return g
    }

    /// "⌃⌥F", for messages.
    var text: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + keyName
    }

    /// The character a key types with no modifiers, in the current keyboard layout.
    static func character(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { buffer -> OSStatus in
            let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let s = String(utf16CodeUnits: chars, count: length)
        return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }
}

extension Shortcut {
    static func ctrlOpt(_ key: Int) -> Shortcut { Shortcut(keyCode: UInt32(key), modifiers: [.control, .option]) }
    static func opt(_ key: Int) -> Shortcut { Shortcut(keyCode: UInt32(key), modifiers: [.option]) }
}
