//! The interface language: Brazilian Portuguese when the first of the user's
//! preferred languages starts with `pt`, English for anything else. There is
//! no in-app switch. The settings window decides the same way from
//! `navigator.languages` (src/i18n.js).
//!
//! This is only the interface. The dictation language (Whisper) and the
//! translation target are settings of their own and never follow it.

use std::sync::LazyLock;

static IS_PORTUGUESE: LazyLock<bool> = LazyLock::new(|| {
    sys_locale::get_locales()
        .next()
        .map(|tag| tag.to_lowercase().starts_with("pt"))
        .unwrap_or(false)
});

/// True when the interface is in Brazilian Portuguese.
pub fn is_portuguese() -> bool {
    *IS_PORTUGUESE
}

/// The interface tag, for the diagnostics and the log.
pub fn locale() -> &'static str {
    if is_portuguese() { "pt-BR" } else { "en" }
}

/// Pick the string for the interface language. Both are always given, so a
/// missing translation cannot happen on the Rust side.
pub fn tr(en: &'static str, pt: &'static str) -> &'static str {
    if is_portuguese() { pt } else { en }
}
