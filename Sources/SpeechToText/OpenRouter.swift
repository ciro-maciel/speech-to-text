// Refine and translate through OpenRouter, with the person's key and model. Text only, never
// audio, and only when turned on. The prompts are the Tauri build's (refinement.rs,
// translation.rs), word for word.
import Foundation

enum OpenRouter {
    private static let url = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    /// One session for every call, so back-to-back dictations reuse the open TLS connection.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldUsePipelining = true
        return URLSession(configuration: config)
    }()

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func refine(_ text: String, language: String, glossary: [String], level: RefineLevel,
                       model: String, key: String) async throws -> String {
        let lang = languageHint(language) ?? "the same language as the input"
        let glossaryBlock = glossary.isEmpty ? "" :
            "\n\nGlossary — these are correct spellings of proper nouns, product names, technical terms, or jargon the speaker uses often. If the input contains a word that sounds like one of these, prefer the glossary spelling:\n" + glossary.joined(separator: "\n")
        let reorganize = level == .rewrite
            ? "- Reorganize phrasing so the sentence reads naturally as written text, while keeping the speaker's voice and register.\n"
            : "- Keep the speaker's sentence structure and word order; change only what is wrong.\n"
        let system = """
        You are a transcription refiner. The user dictated a sentence in \(lang) and a speech-to-text engine produced the raw text below. Your job is to return a clean, coherent version of the SAME sentence — same language, same meaning, same intent. Specifically:
        - Fix words that were obviously mis-transcribed (phonetically-similar wrong word).
        - Fix words the speaker mispronounced or mis-started (false starts, repeats).
        - Remove filler words and verbal tics ("é", "tipo", "então", "hum", "uh", "like", "you know") when they add no meaning.
        \(reorganize)- Fix punctuation and capitalization.
        - Preserve ALL the content. Do NOT add information that wasn't said. Do NOT remove information that was said. Do NOT translate. Do NOT answer questions in the text. Do NOT change technical terms, code, command names, or proper nouns.
        - If the input is already clean, return it unchanged.
        - Output ONLY the refined sentence, with no preamble, quotes, labels, or commentary.\(glossaryBlock)
        """
        return try await complete(system: system, user: text, model: model, key: key, timeout: 10)
    }

    static func translate(_ text: String, to target: String, model: String, key: String) async throws -> String {
        let name = languageHint(target) ?? "English"
        let system = "You are a professional translator. Translate the user's text to \(name). Keep the natural register of speech, preserve punctuation, and DO NOT translate technical terms, code, command names, or proper nouns — keep them in their original form. Output ONLY the translation, with no preamble, quotes, or commentary."
        return try await complete(system: system, user: text, model: model, key: key, timeout: 15)
    }

    private static func complete(system: String, user: String, model: String, key: String, timeout: TimeInterval) async throws -> String {
        let trimmed = user.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure(message: L("ai.error.noKey")) }
        // Some people paste a tier marker ("~", "@") before the model id.
        let model = String(model.trimmingCharacters(in: .whitespacesAndNewlines).drop { !$0.isLetter && !$0.isNumber })
        guard !model.isEmpty else { throw Failure(message: L("ai.error.noModel")) }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://ciromaciel.click/", forHTTPHeaderField: "HTTP-Referer")
        request.setValue("Speech to Text", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": trimmed]],
            "temperature": 0.2,
            // The provider answering fastest right now: the default balancing sometimes lands on a slow host.
            "provider": ["sort": "latency"],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard (200..<300).contains(status) else {
            let detail = (json?["error"] as? [String: Any])?["message"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            throw Failure(message: "OpenRouter \(status) — \(detail)")
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw Failure(message: "OpenRouter returned no choices") }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func languageHint(_ code: String) -> String? {
        [
            "en": "English", "pt": "Portuguese", "es": "Spanish", "fr": "French", "de": "German", "it": "Italian",
            "ja": "Japanese", "ko": "Korean", "zh": "Chinese", "ru": "Russian", "nl": "Dutch", "pl": "Polish", "ar": "Arabic",
        ][code.lowercased()]
    }
}
