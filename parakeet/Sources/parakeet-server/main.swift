// parakeet-server — NVIDIA Parakeet (FluidAudio's "ultra" build) kept loaded on the
// Neural Engine, so each dictation pays only for inference. About 80 MB resident, against
// ~2 GB for large-v3-turbo in whisper-server, and it doesn't drop sentences in long audio.
//
// One JSON object per line on stdin and stdout:
//
//   parakeet-server --model-dir <dir>
//     out  {"event":"ready","ms":812}                      once the model is loaded
//     in   {"id":1,"wav":"/tmp/x.wav","language":"pt"}
//     out  {"id":1,"text":"…","ms":120}  or  {"id":1,"error":"…"}
//
//   parakeet-server --download --model-dir <dir>
//     out  {"event":"progress","fraction":0.42}           while downloading and compiling
//     out  {"event":"done"}                                then exits 0
//
// <dir> ends in "parakeet-ultra": FluidAudio keeps each model in a folder named after its
// Hugging Face repo. After a complete download a `ready` file is written there; the app
// treats the model as installed only when it exists.

import FluidAudio
import Foundation

let version: AsrModelVersion = .ultra
let readyMarker = "ready"

func emit(_ object: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
    data.append(0x0A)
    FileHandle.standardOutput.write(data)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("parakeet-server: \(message)\n".utf8))
    exit(1)
}

func milliseconds(since start: Date) -> Int {
    Int(Date().timeIntervalSince(start) * 1000)
}

func download(to directory: URL) async throws {
    // Throttled: FluidAudio reports per chunk, the app only needs whole percents.
    let last = LastFraction()
    try await AsrModels.download(to: directory, version: version) { progress in
        let fraction = (progress.fractionCompleted * 100).rounded() / 100
        if last.advance(to: fraction) {
            emit(["event": "progress", "fraction": fraction])
        }
    }
    // Loading once compiles the models for this Mac and proves the download is whole.
    _ = try await AsrModels.load(from: directory, version: version)
    FileManager.default.createFile(atPath: directory.appendingPathComponent(readyMarker).path, contents: nil)
    emit(["event": "done"])
}

func serve(from directory: URL) async throws {
    guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(readyMarker).path) else {
        fail("model not downloaded at \(directory.path)")
    }
    let start = Date()
    let manager = AsrManager(config: ASRConfig(tdtConfig: TdtConfig(blankId: version.blankId)))
    try await manager.loadModels(AsrModels.load(from: directory, version: version))
    let layers = await manager.decoderLayerCount
    emit(["event": "ready", "ms": milliseconds(since: start)])

    for try await line in FileHandle.standardInput.bytes.lines {
        guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let id = request["id"] as? Int,
            let wav = request["wav"] as? String
        else { continue }
        let started = Date()
        do {
            var state = TdtDecoderState.make(decoderLayers: layers)
            let language = (request["language"] as? String).flatMap(Language.init(rawValue:))
            let result = try await manager.transcribe(URL(fileURLWithPath: wav), decoderState: &state, language: language)
            emit(["id": id, "text": result.text, "ms": milliseconds(since: started)])
        } catch {
            emit(["id": id, "error": "\(error)"])
        }
    }
}

final class LastFraction: @unchecked Sendable {
    private let lock = NSLock()
    private var value = -1.0

    func advance(to fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard fraction > value else { return false }
        value = fraction
        return true
    }
}

let arguments = CommandLine.arguments
guard let index = arguments.firstIndex(of: "--model-dir"), index + 1 < arguments.count else {
    fail("usage: parakeet-server [--download] --model-dir <dir>")
}
let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)

do {
    if arguments.contains("--download") {
        try await download(to: directory)
    } else {
        try await serve(from: directory)
    }
} catch {
    fail("\(error)")
}
