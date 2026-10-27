// The transcription history: text only, never audio. Entries always live in memory for the
// session (so "paste last" works with history off); they go to disk only when history is kept
// for some days. Same file and same shape as the Tauri build's history.json, so either build
// reads what the other wrote.
import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    /// Unix epoch, milliseconds.
    var at: Int64
    /// What was pasted.
    var text: String
    /// What the model heard, before refinement or translation.
    var original: String
    /// "local" | "refined" | "translated" | "nothing"
    var kind: String
    var words: Int
    var audioSecs: Double
    /// From the end of speech to the text being ready.
    var latencyMs: Int64
    var model: String

    var id: Int64 { at }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(at) / 1000) }
}

@MainActor
final class History: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    private static let maxEntries = 200
    private var file: URL { TauriSettings.folder.appendingPathComponent("history.json") }

    private struct Stored: Codable { var entries: [HistoryEntry] }

    func load(days: Int) {
        guard days > 0, let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        entries = stored.entries
        prune(days: days)
    }

    func add(_ entry: HistoryEntry, days: Int) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        prune(days: days)
        save(days: days)
    }

    func clear(days: Int) {
        entries = []
        save(days: days)
    }

    /// Off: the file goes, the session keeps its lines. On: what is in memory is written.
    func setRetention(days: Int) {
        prune(days: days)
        save(days: days)
    }

    var lastText: String? { entries.first { $0.kind != "nothing" && !$0.text.isEmpty }?.text }

    func recentTexts(_ count: Int) -> [String] {
        Array(entries.filter { $0.kind != "nothing" && !$0.text.isEmpty }.prefix(count).map(\.text))
    }

    private func prune(days: Int) {
        guard days > 0 else { return }
        let cutoff = Int64((Date().timeIntervalSince1970 - Double(days) * 86400) * 1000)
        entries.removeAll { $0.at < cutoff }
    }

    private func save(days: Int) {
        if days == 0 {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(Stored(entries: entries)) { try? data.write(to: file, options: .atomic) }
    }
}

extension Date {
    var epochMs: Int64 { Int64(timeIntervalSince1970 * 1000) }
}
