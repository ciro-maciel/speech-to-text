// The settings controls, from the Assistant: the shortcut recorder and its caps (the Windows
// app's Recorder.swift), the text field (Windows' ZenField) and the switch (the Tauri app's .sw).
import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Shortcuts

/// The key caps of a shortcut; click to record a new one. While recording, the next key press
/// becomes the shortcut; ⌫ alone removes it; esc cancels (unless Esc is what is being recorded
/// and keys alone are allowed: then esc is the shortcut).
struct KeyRecorder: View {
    let shortcut: Shortcut?
    /// The other shortcut and its name: the same combination can't do both.
    var other: Shortcut? = nil
    var otherName = ""
    var allowsKeyAlone = false
    /// While recording, the global shortcuts are off, so pressing one does not fire it.
    let onPause: (Bool) -> Void
    let onChange: (Shortcut?) -> Void

    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(action: toggle) {
                Group {
                    if recording {
                        Text(L("recorder.type")).font(Zen.font(11, .bold)).foregroundStyle(Zen.gray9)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Zen.gray0)
                            .overlay(Rectangle().strokeBorder(Zen.gray9, lineWidth: 1.5))
                    } else if let shortcut {
                        Caps(shortcut: shortcut)
                    } else {
                        Text(L("recorder.none")).font(Zen.font(11, .bold)).foregroundStyle(Zen.gray4)
                            .padding(.horizontal, 10).frame(height: 24)
                            .overlay(Rectangle().strokeBorder(Zen.gray3, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    }
                }
                .padding(2)
                .background(hover && !recording ? Zen.gray2 : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(recording ? L("recorder.help.recording") : L("recorder.help.idle"))
            if let message {
                Text(message).font(Zen.font(11, .medium)).foregroundStyle(Zen.red7)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .trailing)
            } else if recording {
                // A combination another app holds as a global shortcut never reaches this window.
                Text(allowsKeyAlone ? L("recorder.hint.keyAlone") : L("recorder.hint"))
                    .font(Zen.font(11, .medium)).foregroundStyle(Zen.gray5)
                    .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func toggle() { recording ? stopRecording() : start() }

    private func start() {
        message = nil
        recording = true
        onPause(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { onPause(false) }
        recording = false
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(Shortcut.relevant)
        let key = Int(event.keyCode)
        if key == kVK_Escape && mods.isEmpty && !allowsKeyAlone { stopRecording(); return }
        if (key == kVK_Delete || key == kVK_ForwardDelete) && mods.isEmpty {
            stopRecording()
            onChange(nil)
            return
        }
        let s = Shortcut(keyCode: UInt32(event.keyCode), modifiers: mods)
        guard allowsKeyAlone || s.isUsable else {
            message = L("recorder.needsModifier")
            return
        }
        stopRecording()
        if let other, other == s {
            message = L("recorder.duplicate", s.text, otherName)
            return
        }
        onChange(s)
    }
}

/// The caps: Tabler icons for modifiers and special keys, the letter otherwise.
struct Caps: View {
    let shortcut: Shortcut

    var body: some View {
        HStack(spacing: 4) {
            // Esc's glyph (⎋) reads as a refresh icon at this size; the word is clearer.
            ForEach(Array(shortcut.caps.map { $0 == "⎋" ? "Esc" : $0 }.enumerated()), id: \.offset) { _, cap in
                Group {
                    if cap.hasPrefix("icon:") {
                        Icon(name: String(cap.dropFirst(5)), size: 12, color: Zen.gray7)
                    } else {
                        Text(cap).font(Zen.font(11, .bold)).foregroundStyle(Zen.gray7)
                            .padding(.horizontal, cap.count > 1 ? 6 : 0)
                    }
                }
                .frame(minWidth: 22, minHeight: 22)
                .background(Zen.gray1)
                .zenBorder(Zen.gray3)
            }
        }
    }
}

// MARK: - Text field and switch

/// Text input of the panel theme: 36 high, 13 px, gray.3 rule, radius 0. Enter saves; the
/// value goes back to the saved one if the field loses focus without Enter.
struct ZenTextField: View {
    let placeholder: String
    let value: String
    var width: CGFloat = 240
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(Zen.font(13, .medium))
            .foregroundStyle(Zen.gray9)
            .focused($isFocused)
            .padding(.horizontal, 10)
            .frame(width: width, height: 36)
            .background(Zen.gray0)
            .overlay(Rectangle().strokeBorder(isFocused ? Zen.gray9 : Zen.gray3, lineWidth: 1))
            .onSubmit {
                let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty && text != value { onCommit(text) }
                isFocused = false
            }
            .onAppear { draft = value }
            .onChange(of: value) { _, new in if !isFocused { draft = new } }
            .onChange(of: isFocused) { _, focused in if !focused { draft = value } }
    }
}

/// The switch of Speech to Text (.sw): 34 × 18, gray.9 rule; off, a gray.4 square on the left;
/// on, filled gray.9 with a white square on the right.
struct ZenSwitch: View {
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Button { onToggle(!isOn) } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Rectangle().fill(isOn ? Zen.gray9 : Zen.gray0)
                Rectangle().strokeBorder(Zen.gray9, lineWidth: 1)
                Rectangle().fill(isOn ? Zen.gray0 : Zen.gray4).frame(width: 12, height: 12).padding(3)
            }
            .frame(width: 34, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? L("switch.on") : L("switch.off"))
    }
}
