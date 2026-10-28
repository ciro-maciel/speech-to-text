// The dictation: the shortcut's press and release, the microphone, Parakeet, the optional AI
// and the paste. The rules are the Tauri build's (hotkey.rs, lib.rs):
//   - one recording at a time; only the shortcut that started it stops it
//   - Segurar: dictates while the key is down; a quick tap waits 350 ms for a second one, and a
//     double tap locks the recording hands-free until the next press
//   - Tocar: one press starts, the next stops
//   - Esc, while listening, drops the audio and pastes nothing
import AppKit
import AVFoundation
import Foundation

enum DictationMode: String { case transcribe, translate }

enum Activity: Equatable { case idle, listening, processing }

enum OverlayState: Equatable {
    case hidden
    case listening(translate: Bool, locked: Bool)
    case transcribing, refining
    case translating(target: String)
    case pasted(text: String, words: Int)
    case nothing, cancelled, needsPermission
    case error(String)
}

@MainActor
final class Dictation: ObservableObject {
    let settings: AppSettings
    let history: History
    let recorder: Recorder
    let transcriber = Transcriber()

    @Published private(set) var overlay: OverlayState = .hidden
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var listeningSince: Date?
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var isModelLoaded = false
    /// 0–1 while the model downloads.
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var downloadMessage: String?

    /// Asks the app for the Esc shortcut while listening, and to show the window.
    var onEscapeNeeded: (Bool) -> Void = { _ in }
    var openWindow: (Pane) -> Void = { _ in }

    private var mode: DictationMode = .transcribe
    private var isRecording = false
    private var isLocked = false
    private var isTapPending = false
    private var tapGeneration = 0
    private var pressedAt: Date?
    private var overlayGeneration = 0
    private var downloadTask: Task<Void, Never>?

    private static let tapMax: TimeInterval = 0.25
    private static let doubleTapWindow: TimeInterval = 0.35

    init(settings: AppSettings, history: History, recorder: Recorder) {
        self.settings = settings
        self.history = history
        self.recorder = recorder
    }

    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }

    func pause(for seconds: TimeInterval) {
        pausedUntil = seconds > 0 ? Date().addingTimeInterval(seconds) : nil
        if seconds > 0 {
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if let until = pausedUntil, until <= Date() { pausedUntil = nil }
            }
        }
    }

    // MARK: - The shortcut

    func pressed(_ mode: DictationMode) {
        guard !isPaused else { return }
        if !isRecording {
            pressedAt = Date()
            start(mode)
            return
        }
        guard self.mode == mode else { return }
        if settings.triggerMode == .toggle || isLocked {
            stop()
        } else if isTapPending {
            // Second tap inside the window: keep recording, hands-free.
            isTapPending = false
            tapGeneration += 1
            isLocked = true
            setOverlay(.listening(translate: mode == .translate, locked: true))
        }
    }

    func released(_ mode: DictationMode) {
        guard isRecording, settings.triggerMode == .hold, self.mode == mode, !isLocked else { return }
        let isQuick = pressedAt.map { Date().timeIntervalSince($0) < Self.tapMax } ?? false
        guard isQuick else { stop(); return }
        // A tap: wait briefly for a second one before treating it as a stop.
        isTapPending = true
        tapGeneration += 1
        let generation = tapGeneration
        Task {
            try? await Task.sleep(for: .seconds(Self.doubleTapWindow))
            if tapGeneration == generation, isTapPending {
                isTapPending = false
                stop()
            }
        }
    }

    func cancel() {
        guard isRecording else { return }
        isRecording = false
        isLocked = false
        isTapPending = false
        tapGeneration += 1
        recorder.cancel()
        NSLog("[dictation] cancelled")
        onEscapeNeeded(false)
        if settings.muteWhileDictating { SystemAudio.restore() }
        if settings.sounds { Tones.play(440) }
        flash(.cancelled, for: 0.7)
        activity = .idle
        listeningSince = nil
    }

    private func start(_ mode: DictationMode) {
        guard Recorder.isAuthorized else {
            Permissions.requestMicrophone { _ in }
            flash(.error(L("hud.noMicrophone")), for: 2.5)
            openWindow(.permissions)
            return
        }
        guard Transcriber.isInstalled else {
            flash(.error(L("hud.noModel")), for: 2.5)
            openWindow(.transcription)
            return
        }
        isRecording = true
        isLocked = false
        isTapPending = false
        self.mode = mode
        recorder.begin()
        // A closed microphone takes about 0.2 s to deliver: the overlay says "preparing" and the
        // start tone waits for the first real audio, so it means "speak now". Without "keep the
        // microphone ready" it always plays, since it is the signal; kept ready, it follows the setting.
        let hasTone = settings.sounds || !settings.keepMicrophoneWarm
        if recorder.isReady {
            if hasTone { Tones.play(880) }
            muteAfterTone(hasTone)
        } else {
            recorder.onReady = { [weak self] in
                guard let self, self.isRecording else { return }
                Tones.play(880)
                self.listeningSince = Date()
                self.muteAfterTone(true)
            }
        }
        setOverlay(.listening(translate: mode == .translate, locked: false))
        activity = .listening
        listeningSince = Date()
        if settings.escCancels { onEscapeNeeded(true) }
        // The model loads while the person speaks, if it isn't already.
        Task { try? await transcriber.load(); isModelLoaded = await transcriber.isLoaded }
    }

    /// Muting the Mac before the tone silenced the tone itself: it waits for the tone's 100 ms.
    private func muteAfterTone(_ hasTone: Bool) {
        guard settings.muteWhileDictating else { return }
        guard hasTone else { SystemAudio.mute(); return }
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if isRecording { SystemAudio.mute() }
        }
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        isLocked = false
        isTapPending = false
        let mode = self.mode
        var samples = recorder.end()
        Diagnostics.save(samples, note: recorder.lastBegin)
        if let wav = E2E.wavOverride, !samples.isEmpty { samples = E2E.samples(wav) ?? samples }
        onEscapeNeeded(false)
        if settings.muteWhileDictating { SystemAudio.restore() }
        if settings.sounds { Tones.play(660) }
        listeningSince = nil
        activity = .processing
        setOverlay(.transcribing)
        Task { await process(samples, mode: mode) }
    }

    // MARK: - From audio to pasted text

    private func process(_ samples: [Float], mode: DictationMode) async {
        let started = Date()
        let audioSecs = Double(samples.count) / 16000
        defer { activity = .idle }

        // Shorter than a quarter second: a slip of the key, not a dictation.
        guard samples.count >= 4000 else { flash(.nothing, for: 0.7); return }

        let original: String
        do {
            let raw = try await transcriber.transcribe(samples, language: settings.language)
            original = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        } catch {
            NSLog("[parakeet] \(error)")
            flash(.error(L("hud.transcriptionFailed")), for: 2.5)
            return
        }
        if !settings.keepModelLoaded { await transcriber.unload() }
        isModelLoaded = await transcriber.isLoaded
        let sttMs = Date().timeIntervalSince(started) * 1000

        if original.isEmpty {
            flash(.nothing, for: 0.7)
            history.add(HistoryEntry(at: Date().epochMs, text: "", original: "", kind: "nothing", words: 0,
                                     audioSecs: audioSecs, latencyMs: Int64(sttMs), model: Transcriber.modelName), days: settings.historyDays)
            return
        }

        var text = original
        var aiError: String?
        if settings.refine {
            setOverlay(.refining)
            do {
                let refined = try await OpenRouter.refine(original, language: settings.language, glossary: settings.glossary,
                                                          level: settings.refineLevel, model: settings.openRouterModel, key: settings.openRouterKey)
                if !refined.isEmpty { text = refined }
            } catch {
                NSLog("[refine] \(error.localizedDescription)")
                aiError = L("hud.refineFailed")
            }
        }
        if mode == .translate {
            setOverlay(.translating(target: settings.targetLanguage))
            do {
                let translated = try await OpenRouter.translate(text, to: settings.targetLanguage, model: settings.openRouterModel, key: settings.openRouterKey)
                if !translated.isEmpty { text = translated }
            } catch {
                NSLog("[translate] \(error.localizedDescription)")
                aiError = L("hud.translateFailed")
            }
        }

        let words = text.split(whereSeparator: \.isWhitespace).count
        let outcome: Paster.Outcome
        if settings.autoPaste {
            outcome = await Paster.paste(text)
        } else {
            Paster.copy(text)
            outcome = .pasted
        }
        if outcome == .needsPermission {
            flash(.needsPermission, for: 4)
        } else if let aiError {
            flash(.error(aiError), for: 2.5)
        } else {
            flash(.pasted(text: text, words: words), for: 0.9)
        }

        let kind = mode == .translate && aiError == nil ? "translated" : settings.refine && aiError == nil ? "refined" : "local"
        history.add(HistoryEntry(at: Date().epochMs, text: text, original: original, kind: kind, words: words,
                                 audioSecs: audioSecs, latencyMs: Int64(Date().timeIntervalSince(started) * 1000),
                                 model: Transcriber.modelName), days: settings.historyDays)
        NSLog("[timing] audio=%.1fs stt=%.0fms total=%.0fms", audioSecs, sttMs, Date().timeIntervalSince(started) * 1000)
    }

    func pasteLast() {
        guard let text = history.lastText else { return }
        Task {
            if await Paster.paste(text) == .needsPermission { flash(.needsPermission, for: 4) }
        }
    }

    // MARK: - The model

    /// Loads Parakeet and runs one throwaway inference, so the first dictation is warm.
    func preload() {
        guard settings.keepModelLoaded, Transcriber.isInstalled else { return }
        Task {
            let started = Date()
            _ = try? await transcriber.transcribe([Float](repeating: 0, count: 16000), language: "pt")
            isModelLoaded = await transcriber.isLoaded
            NSLog("[parakeet] preloaded in %.0fms", Date().timeIntervalSince(started) * 1000)
        }
    }

    func applyKeepLoaded() {
        if settings.keepModelLoaded { preload() } else { Task { await transcriber.unload(); isModelLoaded = false } }
    }

    func downloadModel() {
        guard downloadTask == nil else { return }
        downloadProgress = 0
        downloadMessage = nil
        downloadTask = Task {
            do {
                try await Transcriber.download { fraction in
                    Task { @MainActor in if self.downloadProgress != nil { self.downloadProgress = fraction } }
                }
                if !Task.isCancelled {
                    downloadMessage = L("model.downloaded")
                    preload()
                }
            } catch is CancellationError {
                downloadMessage = L("model.cancelled")
            } catch {
                downloadMessage = Task.isCancelled ? L("model.cancelled") : L("model.failed", error.localizedDescription)
            }
            if Task.isCancelled { try? FileManager.default.removeItem(at: Transcriber.modelDirectory) }
            downloadProgress = nil
            downloadTask = nil
        }
    }

    /// The line clears at once; FluidAudio finishes the file it is on, then the folder goes.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadProgress = nil
        downloadMessage = L("model.cancelled")
    }

    // MARK: - Overlay

    private func setOverlay(_ state: OverlayState) {
        overlayGeneration += 1
        overlay = state
    }

    private func flash(_ state: OverlayState, for seconds: TimeInterval) {
        setOverlay(state)
        let generation = overlayGeneration
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if overlayGeneration == generation { overlay = .hidden }
        }
    }
}

/// End-to-end tests drive the app without a keyboard or a voice: STT_E2E_TRIGGER names a file
/// whose lines run the shortcut's handlers ("press transcribe", "release transcribe", "escape",
/// "paste-last"), and STT_E2E_WAV replaces what the microphone captured. Off unless set.
@MainActor
enum E2E {
    static let wavOverride = ProcessInfo.processInfo.environment["STT_E2E_WAV"]
    static let isOn = ProcessInfo.processInfo.environment["STT_E2E_TRIGGER"] != nil

    static func samples(_ path: String) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: input)) != nil,
              let converter = AVAudioConverter(from: file.processingFormat, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(file.length) * 16000 / file.processingFormat.sampleRate) + 16)
        else { return nil }
        var fed = false
        converter.convert(to: output, error: nil) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    static func watch(_ run: @escaping @MainActor (String) -> Void) {
        guard let path = ProcessInfo.processInfo.environment["STT_E2E_TRIGGER"] else { return }
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else { return }
            try? "".write(toFile: path, atomically: true, encoding: .utf8)
            MainActor.assumeIsolated { run(command) }
        }
    }
}

/// Off unless asked for (STT_DEBUG_AUDIO_DIR, or `defaults write click.ciromaciel.speech-to-text
/// debugAudioFolder <path>`): the last dictation's audio as it reached the model, and what the
/// microphone was doing when it began. Audio stays on this Mac, in the folder given.
enum Diagnostics {
    static func save(_ samples: [Float], note: String) {
        guard let folder = ProcessInfo.processInfo.environment["STT_DEBUG_AUDIO_DIR"]
                ?? UserDefaults.standard.string(forKey: "debugAudioFolder") else { return }
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().epochMs
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        var header = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: "RIFF".utf8); u32(UInt32(36 + pcm.count)); header.append(contentsOf: "WAVEfmt ".utf8)
        u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        header.append(contentsOf: "data".utf8); u32(UInt32(pcm.count))
        try? (header + pcm).write(to: dir.appendingPathComponent("\(stamp).wav"))
        try? "\(note) samples=\(samples.count)\n".write(to: dir.appendingPathComponent("\(stamp).txt"), atomically: true, encoding: .utf8)
    }
}
