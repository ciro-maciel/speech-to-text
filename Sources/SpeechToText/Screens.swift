// The window, in the Cleaner frame (15-app-mac.md): the logotype, the menu in three groups and
// the status line in the sidebar; one page per item. The panes are the Tauri build's.
import AppKit
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case home, shortcut, transcription, glossary, ai, overlay, permissions, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return L("nav.home")
        case .shortcut: return L("nav.shortcut")
        case .transcription: return L("nav.transcription")
        case .glossary: return L("nav.glossary")
        case .ai: return L("nav.ai")
        case .overlay: return L("nav.overlay")
        case .permissions: return L("nav.permissions")
        case .system: return L("nav.system")
        }
    }

    var icon: String {
        switch self {
        case .home: return "home"
        case .shortcut: return "keyboard"
        case .transcription: return "cpu"
        case .glossary: return "vocabulary"
        case .ai: return "sparkles"
        case .overlay: return "layout-navbar"
        case .permissions: return "lock"
        case .system: return "settings"
        }
    }

    static let groups: [(String, [Pane])] = [
        ("nav.dictation", [.home, .shortcut, .transcription, .glossary]),
        ("nav.after", [.ai, .overlay]),
        ("nav.settings", [.permissions, .system]),
    ]
}

@MainActor
final class Navigation: ObservableObject {
    @Published var pane: Pane = .home
    /// Bumped every second while the window is open, so the permission lines follow the system.
    @Published var tick = 0
}

struct AppView: View {
    @ObservedObject var nav: Navigation
    @ObservedObject var settings: AppSettings
    @ObservedObject var dictation: Dictation
    @ObservedObject var history: History
    @ObservedObject var recorder: Recorder
    var shortcutsPaused: (Bool) -> Void

    var body: some View {
        MacShellView {
            MacSidebar(app: "Speech to Text") {
                ForEach(Pane.groups, id: \.0) { group in
                    MacSidebarGroup(title: L(group.0)) {
                        ForEach(group.1) { pane in
                            MacSidebarItem(icon: pane.icon, title: pane.title, active: nav.pane == pane) { nav.pane = pane }
                        }
                    }
                }
            } status: {
                let _ = nav.tick
                let (on, text) = PermissionLine.state()
                MacStatusLine(on: on, onText: text, offText: text) { nav.pane = .permissions }
            }
        } content: {
            MacPage {
                switch nav.pane {
                case .home: HomePane(settings: settings, history: history)
                case .shortcut: ShortcutPane(settings: settings, recorder: recorder, shortcutsPaused: shortcutsPaused)
                case .transcription: TranscriptionPane(settings: settings, dictation: dictation, history: history)
                case .glossary: GlossaryPane(settings: settings)
                case .ai: AIPane(settings: settings, shortcutsPaused: shortcutsPaused)
                case .overlay: OverlayPane(settings: settings)
                case .permissions: PermissionsPane(tick: nav.tick)
                case .system: SystemPane(settings: settings, history: history)
                }
            }
        }
    }
}

/// "Microfone e Acessibilidade ligados", or what is missing.
enum PermissionLine {
    static func state() -> (Bool, String) {
        let mic = Recorder.isAuthorized, ax = Permissions.isAccessibilityOn
        switch (mic, ax) {
        case (true, true): return (true, L("status.bothOn"))
        case (false, false): return (false, L("status.bothOff"))
        case (false, true): return (false, L("status.micOff"))
        case (true, false): return (false, L("status.axOff"))
        }
    }
}

private func header(_ pane: Pane, _ subtitle: String) -> some View {
    MacPageHeader(crumb: "Speech to Text", title: pane.title, subtitle: subtitle)
}

private func languageName(_ code: String) -> String { L("lang.\(code)") }

// MARK: - Início

private struct HomePane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: History

    private var today: [HistoryEntry] { history.entries.filter { Calendar.current.isDateInToday($0.date) && $0.kind != "nothing" } }

    var body: some View {
        header(.home, subtitle)
        let words = today.reduce(0) { $0 + $1.words }
        let latencies = history.entries.filter { $0.kind != "nothing" }.prefix(20).map(\.latencyMs)
        CellRow {
            Cell(label: L("home.dictationsToday"), note: L("home.dictationsToday.note")) { Text("\(today.count)").zenDisplay(22) }
            Cell(label: L("home.wordsToday"), note: L("home.wordsToday.note")) { Text(words.formatted(.number.locale(Localization.locale))).zenDisplay(22) }
            Cell(label: L("home.latency"), note: L("home.latency.note"), isLast: true) {
                Text(latencies.isEmpty ? "—" : Self.seconds(Double(latencies.reduce(0, +)) / Double(latencies.count))).zenDisplay(22)
            }
        }
        .padding(.bottom, 32)

        BlockLabel(text: L("home.recent"))
        if history.entries.isEmpty {
            Text(L("home.empty")).zenNote()
        } else {
            Rows {
                ForEach(Array(history.entries.prefix(30).enumerated()), id: \.element.id) { index, entry in
                    if index > 0 { RowRule() }
                    RecentRow(entry: entry)
                }
            }
        }
        Text(settings.historyDays == 0 ? L("home.historyOff") : L("home.historyKept", settings.historyDays))
            .zenData(12, color: Zen.gray5).padding(.top, 12)
    }

    private var subtitle: String {
        guard let keys = settings.dictationShortcut?.text else { return L("home.sub.none") }
        var line = L(settings.triggerMode == .hold ? "home.sub.hold" : "home.sub.toggle", keys)
        if settings.translateEnabled, let t = settings.translateShortcut {
            // Mid-sentence, Portuguese writes language names in lower case; English capitalizes them.
            let name = languageName(settings.targetLanguage)
            line += L("home.sub.translate", t.text, Localization.isPortuguese ? name.lowercased() : name)
        }
        return line + ". " + L("home.pasteLast", "⌥⌘V") + "."
    }

    static func seconds(_ ms: Double) -> String { (ms / 1000).formatted(.number.precision(.fractionLength(1)).locale(Localization.locale)) + " s" }
}

private struct RecentRow: View {
    let entry: HistoryEntry
    @State private var copied = false
    @State private var hover = false

    var body: some View {
        Button {
            guard entry.kind != "nothing" else { return }
            Paster.copy(entry.text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(entry.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Localization.locale))).zenData(12, color: Zen.gray5).frame(width: 56, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.kind == "nothing" ? L("home.nothing") : entry.text)
                        .font(Zen.font(13, .medium)).foregroundStyle(entry.kind == "nothing" ? Zen.gray5 : Zen.gray9)
                        .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                    if entry.kind != "local", entry.kind != "nothing", entry.original != entry.text {
                        Text(L("home.original", entry.original)).zenData(12, color: Zen.gray5).lineLimit(2)
                    }
                }
                Text(copied ? L("copied") : kindLabel).zenLabel(10, color: Zen.gray5).lineLimit(1).fixedSize().frame(minWidth: 80, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(hover ? Zen.gray1 : Zen.gray0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }

    private var kindLabel: String {
        switch entry.kind {
        case "refined": return L("kind.refined")
        case "translated": return L("kind.translated")
        case "nothing": return "—"
        default: return L("kind.local")
        }
    }
}

// MARK: - Atalho e microfone

private struct ShortcutPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var recorder: Recorder
    var shortcutsPaused: (Bool) -> Void

    var body: some View {
        header(.shortcut, L("dict.sub"))
        SettingRows {
            SettingRow(title: L("dict.hotkey")) {
                KeyRecorder(shortcut: settings.dictationShortcut, other: settings.translateShortcut, otherName: L("ai.translateHotkey"),
                            onPause: shortcutsPaused) { settings.dictationShortcut = $0 }
            }
            SettingRow(title: L("dict.mode"), hint: L("dict.mode.hint")) {
                ZenSelect(value: L("dict.mode.\(settings.triggerMode.rawValue)"),
                          choices: TriggerMode.allCases.map { ($0.rawValue, L("dict.mode.\($0.rawValue)")) },
                          selected: settings.triggerMode.rawValue) { settings.triggerMode = TriggerMode(rawValue: $0) ?? .toggle }
            }
            .zIndex(6)
            SettingRow(title: L("dict.esc"), hint: L("dict.esc.hint")) {
                ZenSwitch(isOn: settings.escCancels) { settings.escCancels = $0 }
            }
            SettingRow(title: L("dict.mic"), hint: L("dict.mic.hint")) {
                MicMeter(level: recorder.level)
                ZenSelect(value: micName, choices: [("", L("dict.mic.default"))] + recorder.microphones.map { ($0.uid, $0.name) },
                          selected: settings.microphone ?? "", width: 280) { settings.microphone = $0.isEmpty ? nil : $0 }
            }
            .zIndex(5)
            SettingRow(title: L("dict.warm"), hint: L("dict.warm.hint")) {
                ZenSwitch(isOn: settings.keepMicrophoneWarm) { settings.keepMicrophoneWarm = $0 }
            }
            SettingRow(title: L("dict.language"), hint: L("dict.language.hint")) {
                ZenSelect(value: languageName(settings.language), choices: spokenLanguageCodes.map { ($0, languageName($0)) },
                          selected: settings.language) { settings.language = $0 }
            }
            .zIndex(4)
            SettingRow(title: L("dict.sounds")) {
                ZenSwitch(isOn: settings.sounds) { settings.sounds = $0 }
            }
            SettingRow(title: L("dict.mute"), hint: L("dict.mute.hint")) {
                ZenSwitch(isOn: settings.muteWhileDictating) { settings.muteWhileDictating = $0 }
            }
        }
        .onAppear { recorder.refreshMicrophones() }
    }

    private var micName: String {
        guard let uid = settings.microphone else { return L("dict.mic.default") }
        return recorder.microphones.first { $0.uid == uid }?.name ?? L("dict.mic.default")
    }
}

// MARK: - Transcrição

private struct TranscriptionPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var dictation: Dictation
    @ObservedObject var history: History

    var body: some View {
        header(.transcription, L("tx.sub"))
        BlockLabel(text: L("tx.model"))
        Rows {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Parakeet").font(Zen.font(14, .bold)).foregroundStyle(Zen.gray9)
                    Text(L("model.parakeet")).font(Zen.font(12, .medium)).foregroundStyle(Zen.gray5)
                }
                Spacer(minLength: 16)
                DataPair(label: L("tx.size"), value: Self.bytes(Transcriber.isInstalled ? Transcriber.installedSize() : Transcriber.downloadBytes))
                DataPair(label: L("tx.timeHere"), value: averageTime)
                action.frame(width: 120, alignment: .trailing)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        if let progress = dictation.downloadProgress {
            VStack(alignment: .leading, spacing: 8) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Zen.gray2)
                        Rectangle().fill(Zen.gray9).frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 4)
                Text(L("model.progress", Int(progress * 100), Self.bytes(Transcriber.downloadBytes))).zenData(12, color: Zen.gray6)
            }
            .padding(.top, 12)
        } else if let message = dictation.downloadMessage {
            Text(message).zenData(12, color: Zen.gray6).padding(.top, 12)
        }

        SettingRows {
            SettingRow(title: L("tx.keepLoaded"), hint: L("tx.keepLoaded.hint")) {
                ZenSwitch(isOn: settings.keepModelLoaded) { settings.keepModelLoaded = $0 }
            }
        }
        .padding(.top, 32)
        Text(L("tx.timeNote")).zenData(12, color: Zen.gray5).padding(.top, 12)
    }

    @ViewBuilder private var action: some View {
        if dictation.downloadProgress != nil {
            Button(L("model.cancel")) { dictation.cancelDownload() }.buttonStyle(ZenButtonStyle(kind: .secondary))
        } else if Transcriber.isInstalled {
            Text(L("model.inUse")).zenLabel(10, color: Zen.gray9)
        } else {
            Button(L("model.download")) { dictation.downloadModel() }.buttonStyle(ZenButtonStyle())
        }
    }

    private var averageTime: String {
        let times = history.entries.filter { $0.kind != "nothing" && $0.model == Transcriber.modelName }.map(\.latencyMs)
        return times.isEmpty ? "—" : HomePane.seconds(Double(times.reduce(0, +)) / Double(times.count))
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

private struct DataPair: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(label).zenLabel(10)
            Text(value).font(Zen.font(13, .bold)).foregroundStyle(Zen.gray9)
        }
        .frame(width: 90, alignment: .trailing)
    }
}

// MARK: - Glossário

private struct GlossaryPane: View {
    @ObservedObject var settings: AppSettings
    @State private var draft = ""

    var body: some View {
        header(.glossary, L("gl.sub"))
        HStack(spacing: 12) {
            TextField(L("gl.placeholder"), text: $draft)
                .textFieldStyle(.plain).font(Zen.font(13, .medium)).foregroundStyle(Zen.gray9)
                .padding(.horizontal, 10).frame(width: 320, height: 36)
                .background(Zen.gray0).overlay(Rectangle().strokeBorder(Zen.gray3, lineWidth: 1))
                .onSubmit(add)
            Button(L("gl.add"), action: add).buttonStyle(ZenButtonStyle()).disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.bottom, 24)
        if settings.glossary.isEmpty {
            Text(L("gl.empty")).zenNote()
        } else {
            Rows {
                ForEach(Array(settings.glossary.enumerated()), id: \.offset) { index, term in
                    if index > 0 { RowRule() }
                    HStack {
                        Text(term).font(Zen.font(13, .bold)).foregroundStyle(Zen.gray9)
                        Spacer()
                        Button { settings.glossary.remove(at: index) } label: { Icon(name: "x", size: 14, color: Zen.gray6) }
                            .buttonStyle(.plain).help(L("gl.remove", term))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                }
            }
            Text(L("gl.count", count: settings.glossary.count)).zenData(12, color: Zen.gray5).padding(.top, 12)
        }
    }

    private func add() {
        let term = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !settings.glossary.contains(term) else { draft = ""; return }
        settings.glossary.append(term)
        draft = ""
    }
}

// MARK: - Inteligência

private struct AIPane: View {
    @ObservedObject var settings: AppSettings
    var shortcutsPaused: (Bool) -> Void
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        header(.ai, L("ai.sub"))
        SettingRows {
            SettingRow(title: L("ai.refine"), hint: L("ai.refine.hint")) {
                ZenSwitch(isOn: settings.refine) { settings.refine = $0 }
            }
            SettingRow(title: L("ai.level"), hint: L("ai.level.hint")) {
                ZenSelect(value: L("ai.level.\(settings.refineLevel.rawValue)"),
                          choices: RefineLevel.allCases.map { ($0.rawValue, L("ai.level.\($0.rawValue)")) },
                          selected: settings.refineLevel.rawValue) { settings.refineLevel = RefineLevel(rawValue: $0) ?? .light }
            }
            .zIndex(6)
            SettingRow(title: L("ai.translate")) {
                ZenSwitch(isOn: settings.translateEnabled) { settings.translateEnabled = $0 }
            }
            SettingRow(title: L("ai.translateHotkey")) {
                KeyRecorder(shortcut: settings.translateShortcut, other: settings.dictationShortcut, otherName: L("dict.hotkey"),
                            onPause: shortcutsPaused) { settings.translateShortcut = $0 }
            }
            SettingRow(title: L("ai.target")) {
                ZenSelect(value: languageName(settings.targetLanguage), choices: languageCodes.map { ($0, languageName($0)) },
                          selected: settings.targetLanguage) { settings.targetLanguage = $0 }
            }
            .zIndex(5)
        }
        BlockLabel(text: L("ai.provider")).padding(.top, 32)
        SettingRows {
            SettingRow(title: L("ai.model")) {
                ZenTextField(placeholder: L("ai.modelPlaceholder"), value: settings.openRouterModel, width: 320) { settings.openRouterModel = $0 }
            }
            SettingRow(title: L("ai.key")) {
                ZenSecureField(value: settings.openRouterKey) { settings.openRouterKey = $0 }
                Button(isTesting ? L("ai.testing") : L("ai.test"), action: test).buttonStyle(ZenButtonStyle(kind: .secondary)).disabled(isTesting)
            }
        }
        if let testResult { Text(testResult).zenData(12, color: Zen.gray6).padding(.top, 12) }
        Text(L("ai.note")).zenData(12, color: Zen.gray5).padding(.top, 12)
    }

    private func test() {
        isTesting = true
        testResult = nil
        let started = Date()
        Task {
            do {
                _ = try await OpenRouter.refine("teste de conexão", language: settings.language, glossary: [], level: .light,
                                                model: settings.openRouterModel, key: settings.openRouterKey)
                testResult = L("ai.replied", HomePane.seconds(Date().timeIntervalSince(started) * 1000))
            } catch {
                testResult = L("ai.noReply", error.localizedDescription)
            }
            isTesting = false
        }
    }
}

/// The key field: dots, the same frame as ZenTextField; Enter saves.
private struct ZenSecureField: View {
    let value: String
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        SecureField("sk-or-…", text: $draft)
            .textFieldStyle(.plain).font(Zen.font(13, .medium)).foregroundStyle(Zen.gray9)
            .focused($isFocused)
            .padding(.horizontal, 10).frame(width: 220, height: 36)
            .background(Zen.gray0).overlay(Rectangle().strokeBorder(isFocused ? Zen.gray9 : Zen.gray3, lineWidth: 1))
            .onSubmit { onCommit(draft.trimmingCharacters(in: .whitespacesAndNewlines)); isFocused = false }
            .onAppear { draft = value }
            .onChange(of: isFocused) { _, focused in if !focused { draft = value } }
    }
}

// MARK: - Overlay

private struct OverlayPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        header(.overlay, L("ov.sub"))
        SettingRows {
            SettingRow(title: L("ov.position")) {
                ZenSelect(value: settings.overlayPosition.title, choices: OverlayPosition.allCases.map { ($0.rawValue, $0.title) },
                          selected: settings.overlayPosition.rawValue) { settings.overlayPosition = OverlayPosition(rawValue: $0) ?? .topRight }
            }
            .zIndex(6)
            SettingRow(title: L("ov.showText"), hint: L("ov.showText.hint")) {
                ZenSwitch(isOn: settings.overlayShowText) { settings.overlayShowText = $0 }
            }
            SettingRow(title: L("ov.timer")) {
                ZenSwitch(isOn: settings.overlayShowTimer) { settings.overlayShowTimer = $0 }
            }
        }
        BlockLabel(text: L("ov.preview")).padding(.top, 32)
        HStack(spacing: 12) {
            Text(L("hud.pasted")).font(Zen.font(10, .extraBold)).tracking(1.5).textCase(.uppercase).foregroundStyle(Zen.gray0)
            if settings.overlayShowText {
                Text(L("ov.previewText")).font(Zen.font(12, .medium)).foregroundStyle(Zen.gray3)
            }
            Text(L("hud.words", count: 7)).font(Zen.font(12, .medium)).foregroundStyle(Zen.gray4)
        }
        .padding(.horizontal, 14).frame(height: 40).background(Zen.gray9).fixedSize()
    }
}

// MARK: - Permissões

private struct PermissionsPane: View {
    let tick: Int

    var body: some View {
        let mic = Recorder.isAuthorized, ax = Permissions.isAccessibilityOn
        let missing = (mic ? 0 : 1) + (ax ? 0 : 1)
        header(.permissions, missing == 0 ? L("perm.sub.ok") : L(missing == 1 ? "perm.sub.one" : "perm.sub.two"))
        Rows {
            row(title: L("perm.microphone"), isOn: mic, onText: L("perm.mic.granted"),
                offText: Recorder.isDenied ? L("perm.mic.denied") : L("perm.mic.pending")) {
                if Recorder.isDenied { Permissions.openSettings("Privacy_Microphone") } else { Permissions.requestMicrophone { _ in } }
            }
            RowRule()
            row(title: L("perm.autoPaste"), isOn: ax, onText: L("perm.ax.on"), offText: L("perm.ax.off")) {
                Permissions.requestAccessibility()
                Permissions.openSettings("Privacy_Accessibility")
            }
        }
        Text(L("perm.liveNote")).zenData(12, color: Zen.gray5).padding(.top, 12)
    }

    private func row(title: String, isOn: Bool, onText: String, offText: String, fix: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            Icon(name: isOn ? "check" : "lock", size: 18, color: isOn ? Zen.gray9 : Zen.red7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Zen.font(14, .bold)).foregroundStyle(Zen.gray9)
                Text(isOn ? onText : offText).font(Zen.font(12, .medium)).foregroundStyle(isOn ? Zen.gray5 : Zen.red7)
            }
            Spacer()
            if isOn {
                Text(L("perm.status.granted")).zenLabel(10, color: Zen.gray9)
            } else {
                Button(L("perm.allow"), action: fix).buttonStyle(ZenButtonStyle())
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

// MARK: - Sistema

private struct SystemPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var history: History
    @State private var isLoginItem = LoginItem.isOn

    var body: some View {
        header(.system, L("sys.sub"))
        SettingRows {
            SettingRow(title: L("sys.autolaunch")) {
                ZenSwitch(isOn: isLoginItem) { LoginItem.set($0); isLoginItem = LoginItem.isOn }
            }
            SettingRow(title: L("sys.history"), hint: L("sys.history.hint")) {
                ZenSelect(value: daysTitle(settings.historyDays), choices: [0, 7, 30].map { (String($0), daysTitle($0)) },
                          selected: String(settings.historyDays), width: 160) { settings.historyDays = Int($0) ?? 7 }
                Button(L("sys.clear")) { history.clear(days: settings.historyDays) }
                    .buttonStyle(ZenButtonStyle(kind: .secondary)).disabled(history.entries.isEmpty)
            }
            .zIndex(5)
        }
    }

    private func daysTitle(_ days: Int) -> String { days == 0 ? L("sys.history.off") : L("sys.history.days", days) }
}
