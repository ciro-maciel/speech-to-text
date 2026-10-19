//! Translation via OpenRouter.
//!
//! OpenRouter is an OpenAI-compatible gateway for many LLM providers
//! (Anthropic, OpenAI, Google, Meta, Mistral, etc). One API key, one schema,
//! pick the model per request.
//!
//! Endpoint: POST https://openrouter.ai/api/v1/chat/completions

use serde::{Deserialize, Serialize};

const OPENROUTER_URL: &str = "https://openrouter.ai/api/v1/chat/completions";
const APP_REFERER: &str = "https://ciromaciel.click/";
const APP_TITLE: &str = "Speech to Text";

/// One client for every OpenRouter call, so back-to-back dictations reuse the
/// open TLS connection instead of paying a fresh handshake each time.
pub(crate) fn http_client() -> &'static reqwest::Client {
    static CLIENT: std::sync::OnceLock<reqwest::Client> = std::sync::OnceLock::new();
    CLIENT.get_or_init(|| {
        reqwest::Client::builder()
            .tcp_keepalive(std::time::Duration::from_secs(60))
            .build()
            .expect("Failed to build HTTP client")
    })
}

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

/// Map a language code (or full name) to a human-readable English name for the prompt.
fn language_name(code_or_name: &str) -> &str {
    match code_or_name.to_lowercase().as_str() {
        "en" | "english"      => "English",
        "pt" | "portuguese"   => "Portuguese",
        "es" | "spanish"      => "Spanish",
        "fr" | "french"       => "French",
        "de" | "german"       => "German",
        "it" | "italian"      => "Italian",
        "ja" | "japanese"     => "Japanese",
        "ko" | "korean"       => "Korean",
        "zh" | "chinese"      => "Chinese",
        "ru" | "russian"      => "Russian",
        "nl" | "dutch"        => "Dutch",
        "pl" | "polish"       => "Polish",
        "ar" | "arabic"       => "Arabic",
        _ => "English",
    }
}

/// Translate `text` to `target_language` using `model` via OpenRouter.
///
/// Returns the translated text on success, or a human-readable error.
/// Sanitize a model identifier — strip leading punctuation/whitespace some
/// users copy-paste from OpenRouter docs (e.g. tier markers like `~`, `:free`
/// suffixes, etc.).
fn sanitize_model(model: &str) -> String {
    model
        .trim()
        .trim_start_matches(|c: char| !c.is_alphanumeric())
        .to_string()
}

fn sanitize_api_key(key: &str) -> String {
    key.trim().to_string()
}

pub async fn translate(
    text: &str,
    target_language: &str,
    model: &str,
    api_key: &str,
) -> Result<String, String> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Ok(String::new());
    }
    let api_key_owned = sanitize_api_key(api_key);
    if api_key_owned.is_empty() {
        return Err("API key vazia — configure em Configurações → Tradução".to_string());
    }
    let model_owned = sanitize_model(model);
    if model_owned.is_empty() {
        return Err("Modelo OpenRouter vazio — ex: google/gemini-flash-latest".to_string());
    }
    let model = model_owned.as_str();
    let api_key = api_key_owned.as_str();

    let target = language_name(target_language);
    let system_prompt = format!(
        "You are a professional translator. Translate the user's text to {target}. \
         Keep the natural register of speech, preserve punctuation, and DO NOT translate \
         technical terms, code, command names, or proper nouns — keep them in their original \
         form. Output ONLY the translation, with no preamble, quotes, or commentary."
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
        .timeout(std::time::Duration::from_secs(15))
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
        // Try to extract the API error message; fall back to raw body
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
