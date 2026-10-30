// What the app asks of the system: paste where the cursor is, mute the Mac while dictating,
// the short tones, the permissions and opening at login.
import AppKit
import ApplicationServices
import AVFoundation
import ServiceManagement

enum Paster {
    enum Outcome { case pasted, needsPermission }

    /// The text goes to the clipboard and ⌘V to the app in front, and stays on the clipboard.
    /// It used to put the old clipboard back 400 ms later; an app slower than that to read it
    /// (VS Code while busy) pasted the old one, often an earlier dictation (30/10/2026).
    static func paste(_ text: String) async -> Outcome {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        guard AXIsProcessTrusted() else { return .needsPermission }
        // Let the pasteboard settle before the destination reads it.
        try? await Task.sleep(for: .milliseconds(30))
        postCommandV()
        return .pasted
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func postCommandV() {
        // Virtual key code of "V" on ANSI and ISO layouts (ABNT2 included).
        let source = CGEventSource(stateID: .hidSystemState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// Mutes the output instead of pausing media: there is no public API to pause what plays, and
/// a play/pause key would start playback when nothing was playing. Unmutes only what it muted.
/// One serial queue, so a very short dictation can't restore before the mute happened.
enum SystemAudio {
    private static let queue = DispatchQueue(label: "speech-to-text.system-audio")
    nonisolated(unsafe) private static var didMute = false

    static func mute() {
        queue.async {
            guard osascript("output muted of (get volume settings)") == "false" else { return }
            if osascript("set volume output muted true") != nil { didMute = true }
        }
    }

    static func restore() {
        queue.async {
            guard didMute else { return }
            _ = osascript("set volume output muted false")
            didMute = false
        }
    }

    /// Blocks until done: for quitting.
    static func restoreNow() { queue.sync { if didMute { _ = osascript("set volume output muted false"); didMute = false } } }

    private static func osascript(_ script: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The Tauri build's tones: 880 Hz to start, 660 to finish, 440 to cancel; 100 ms each.
@MainActor
enum Tones {
    private static var cache: [Int: NSSound] = [:]

    static func play(_ frequency: Int) {
        if cache[frequency] == nil { cache[frequency] = NSSound(data: wav(frequency)) }
        cache[frequency]?.stop()
        cache[frequency]?.play()
    }

    private static func wav(_ frequency: Int) -> Data {
        let rate = 44100, count = rate / 10
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let t = Double(i) / Double(rate)
            // 0.06 at the start, falling exponentially, as the WebAudio gain ramp did.
            let gain = 0.06 * pow(0.0001 / 0.06, t / 0.09)
            let sample = Int16(max(-1, min(1, sin(2 * .pi * Double(frequency) * t) * gain)) * 32767)
            withUnsafeBytes(of: sample.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + pcm.count)); header.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        header.append(contentsOf: "data".utf8); u32(UInt32(pcm.count))
        return header + pcm
    }
}

enum Permissions {
    static var isAccessibilityOn: Bool { AXIsProcessTrusted() }

    /// Puts the app in the Accessibility list (the system's prompt), so the person only turns it on.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestMicrophone(_ done: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { ok in DispatchQueue.main.async { done(ok) } }
    }

    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("[login-item] \(error)")
        }
    }
}
