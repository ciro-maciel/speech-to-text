// NVIDIA Parakeet (FluidAudio's "ultra" build) on the Neural Engine, in this process. On 17
// minutes of Brazilian Portuguese (FLEURS) it made fewer errors than Whisper large-v3-turbo
// (3.6% against 3.7% on short sentences, 3.5% against 21.6% on two-minute clips, where
// whisper.cpp dropped whole sentences) in ~80 MB instead of ~2 GB. It returns nothing on
// silence and noise, so it needs no voice detector.
//
// The model lives where the Tauri build keeps it, ~/Library/Application Support/speech-to-text/
// models/parakeet-ultra, with the same "ready" marker: a model either build downloaded serves both.
import FluidAudio
import Foundation

actor Transcriber {
    static let modelName = "parakeet"
    /// The download, for the progress line; FluidAudio reports only a fraction.
    static let downloadBytes: Int64 = 643_000_000
    private static let version: AsrModelVersion = .ultra

    static var modelDirectory: URL {
        DataFolder.root.appendingPathComponent("speech-to-text/models/parakeet-ultra", isDirectory: true)
    }

    nonisolated static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("ready").path)
    }

    private var manager: AsrManager?
    private var layers = 0
    private var loading: Task<Void, Error>?

    var isLoaded: Bool { manager != nil }

    /// Loads once; concurrent callers wait for the same load.
    func load() async throws {
        if manager != nil { return }
        if let loading { return try await loading.value }
        let task = Task {
            let manager = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: Self.version.blankId)))
            try await manager.loadModels(AsrModels.load(from: Self.modelDirectory, version: Self.version))
            self.layers = await manager.decoderLayerCount
            self.manager = manager
        }
        loading = task
        defer { loading = nil }
        try await task.value
    }

    func unload() {
        manager = nil
    }

    /// 16 kHz mono samples to text.
    func transcribe(_ samples: [Float], language: String) async throws -> String {
        try await load()
        guard let manager else { throw TranscriberError.notLoaded }
        var state = TdtDecoderState.make(decoderLayers: layers)
        let result = try await manager.transcribe(samples, decoderState: &state, language: Language(rawValue: language))
        return result.text
    }

    /// Downloads and compiles the model, then writes the marker. `progress` gets 0–1.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let dir = modelDirectory
        try await AsrModels.download(to: dir, version: version) { p in progress(p.fractionCompleted) }
        // Loading once compiles the models for this Mac and proves the download is whole.
        _ = try await AsrModels.load(from: dir, version: version)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("ready").path, contents: nil)
    }

    static func installedSize() -> Int64 {
        guard let walker = FileManager.default.enumerator(at: modelDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    enum TranscriberError: Error { case notLoaded }
}
