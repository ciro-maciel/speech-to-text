//! Refinement via OpenRouter.
//!
//! Takes raw STT output and asks an LLM to fix mis-transcribed words, fix
//! words the speaker mispronounced, remove filler ("é", "tipo", "então…"),
//! and reorganize the sentence so it reads coherently — without adding,
//! removing, or reinterpreting content.
//!
//! Same HTTP shape as `translation.rs` (OpenAI-compatible chat completions).

use serde::{Deserialize, Serialize};

use crate::translation::http_client;

const OPENROUTER_URL: &str = "https://openrouter.ai/api/v1/chat/completions";
const APP_REFERER: &str = "https://ciromaciel.click/";
const APP_TITLE: &str = "Speech to Text";

#[derive(Serialize)]
struct ChatRequest<'a> {
    model: &'a str,
    messages: Vec<Message<'a>>,
    temperature: f32,
    provider: Provider,
}

/// Route to whichever provider is answering fastest right now. Without it,
/// OpenRouter's default load balancing sometimes lands on a slow host and a
/// ~0.7s call becomes 2s+.
#[derive(Serialize)]
struct Provider {
    sort: &'static str,
}

#[derive(Serialize)]
struct Message<'a> {
    role: &'a str,
    content: &'a str,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<Choice>,
}

#[derive(Deserialize)]
struct Choice {
    message: AssistantMessage,
}

#[derive(Deserialize)]
struct AssistantMessage {
    content: String,
}

#[derive(Deserialize)]
struct ApiError {
    error: ErrorDetail,
}

#[derive(Deserialize)]
struct ErrorDetail {
    message: String,
}

fn sanitize_model(model: &str) -> String {
    model
        .trim()
        .trim_start_matches(|c: char| !c.is_alphanumeric())
        .to_string()
}

fn sanitize_api_key(key: &str) -> String {
    key.trim().to_string()
}

fn language_hint(code_or_name: &str) -> &str {
    match code_or_name.to_lowercase().as_str() {
        "en" | "english"    => "English",
        "pt" | "portuguese" => "Portuguese",
        "es" | "spanish"    => "Spanish",
        "fr" | "french"     => "French",
        "de" | "german"     => "German",
        "it" | "italian"    => "Italian",
        "ja" | "japanese"   => "Japanese",
        "ko" | "korean"     => "Korean",
        "zh" | "chinese"    => "Chinese",
        "ru" | "russian"    => "Russian",
        "nl" | "dutch"      => "Dutch",
        "pl" | "polish"     => "Polish",
        "ar" | "arabic"     => "Arabic",
        _ => "the same language as the input",
    }
}

/// Refine `text` (raw STT output) via OpenRouter.
///
/// `source_language` is the language the user spoke in (used as a hint —
/// the output must stay in the same language). `glossary` is an optional
/// free-form list of proper nouns / jargon / spellings to preserve.
pub async fn refine(
    text: &str,
    source_language: &str,
    glossary: &str,
    level: &str,
    model: &str,
    api_key: &str,
) -> Result<String, String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Ok(String::new());
    }

    let api_key_owned = sanitize_api_key(api_key);
    if api_key_owned.is_empty() {
        return Err(crate::i18n::tr(
            "Empty API key — set it in Settings → AI",
            "API key vazia — configure em Configurações → Refinamento",
        )
        .to_string());
    }
    let model_owned = sanitize_model(model);
    if model_owned.is_empty() {
        return Err(crate::i18n::tr(
            "Empty OpenRouter model — e.g. google/gemini-flash-latest",
            "Modelo OpenRouter vazio — ex: google/gemini-flash-latest",
        )
        .to_string());
    }
    let model = model_owned.as_str();
    let api_key = api_key_owned.as_str();

    let lang = language_hint(source_language);
    let glossary_trimmed = glossary.trim();
    let glossary_block = if glossary_trimmed.is_empty() {
        String::new()
    } else {
        format!(
            "\n\nGlossary — these are correct spellings of proper nouns, product names, \
             technical terms, or jargon the speaker uses often. If the input contains a \
             word that sounds like one of these, prefer the glossary spelling:\n{glossary_trimmed}"
        )
    };

    // "light" keeps the speaker's sentence structure; "rewrite" may reorder it.
    let reorganize = if level == "rewrite" {
        "- Reorganize phrasing so the sentence reads naturally as written text, while keeping \
         the speaker's voice and register.\n"
    } else {
        "- Keep the speaker's sentence structure and word order; change only what is wrong.\n"
    };

    let system_prompt = format!(
        "You are a transcription refiner. The user dictated a sentence in {lang} and a \
         speech-to-text engine produced the raw text below. Your job is to return a clean, \
         coherent version of the SAME sentence — same language, same meaning, same intent. \
         Specifically:\n\
         - Fix words that were obviously mis-transcribed (phonetically-similar wrong word).\n\
         - Fix words the speaker mispronounced or mis-started (false starts, repeats).\n\
         - Remove filler words and verbal tics (\"é\", \"tipo\", \"então\", \"hum\", \"uh\", \
         \"like\", \"you know\") when they add no meaning.\n\
         {reorganize}\
         - Fix punctuation and capitalization.\n\
         - Preserve ALL the content. Do NOT add information that wasn't said. Do NOT remove \
         information that was said. Do NOT translate. Do NOT answer questions in the text. \
         Do NOT change technical terms, code, command names, or proper nouns.\n\
         - If the input is already clean, return it unchanged.\n\
         - Output ONLY the refined sentence, with no preamble, quotes, labels, or commentary.{glossary_block}"
    );

    let body = ChatRequest {
        model,
        messages: vec![
            Message { role: "system", content: &system_prompt },
            Message { role: "user", content: trimmed },
        ],
        temperature: 0.2,
        provider: Provider { sort: "latency" },
    };

    let response = http_client()
        .post(OPENROUTER_URL)
        .timeout(std::time::Duration::from_secs(10))
        .bearer_auth(api_key)
        .header("HTTP-Referer", APP_REFERER)
        .header("X-Title", APP_TITLE)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("OpenRouter request failed: {e}"))?;

    let status = response.status();
    let raw = response
        .text()
        .await
        .map_err(|e| format!("Failed to read OpenRouter response: {e}"))?;

    if !status.is_success() {
        if let Ok(api_err) = serde_json::from_str::<ApiError>(&raw) {
            return Err(format!("OpenRouter {} — {}", status, api_err.error.message));
        }
        return Err(format!("OpenRouter {}: {}", status, raw));
    }

    let parsed: ChatResponse = serde_json::from_str(&raw)
        .map_err(|e| format!("Bad OpenRouter response: {e} — body: {raw}"))?;

    parsed
        .choices
        .into_iter()
        .next()
        .map(|c| c.message.content.trim().to_string())
        .ok_or_else(|| "OpenRouter returned no choices".to_string())
}
