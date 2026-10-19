//! Real permission checks, per platform.
//!
//! macOS: Accessibility via AXIsProcessTrusted (required to post ⌘V) and the
//! microphone via AVCaptureDevice. Windows: the microphone consent stored in
//! the registry; pasting needs nothing. Linux: which paste helper the session
//! needs (xdotool on X11, wtype/ydotool on Wayland) and whether it's installed.

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionStatus {
    pub platform: &'static str,
    /// "granted" | "denied" | "not_determined" | "unknown"
    pub microphone: String,
    /// Whether auto-paste can work. Always true where no permission exists.
    pub accessibility: bool,
    pub accessibility_required: bool,
    /// Linux only: the session type ("x11" / "wayland").
    pub session: Option<String>,
    /// Linux only: the paste helper to install when none is found.
    pub missing_paste_tool: Option<String>,
    pub all_granted: bool,
}

pub fn check_all_permissions() -> PermissionStatus {
    let microphone = microphone_status();
    let (accessibility, accessibility_required) = paste_permission();
    let (session, missing_paste_tool) = linux_paste_tool();
    let all_granted = microphone != "denied" && accessibility && missing_paste_tool.is_none();
    PermissionStatus {
        platform: std::env::consts::OS,
        microphone,
        accessibility,
        accessibility_required,
        session,
        missing_paste_tool,
        all_granted,
    }
}

/// Ask for everything the OS lets an app ask for. On macOS this shows the
/// Accessibility prompt, which also adds the app to the list in System
/// Settings — the user only flips the switch. The microphone prompt comes
/// from the renderer's getUserMedia; when it was already denied, the only
/// way back is the settings pane, so we open it.
pub fn request_all() -> PermissionStatus {
    let status = check_all_permissions();
    #[cfg(target_os = "macos")]
    {
        if !status.accessibility {
            macos::prompt_accessibility();
        }
        if status.microphone == "denied" {
            let _ = request_microphone_access();
        }
    }
    #[cfg(target_os = "windows")]
    {
        if status.microphone == "denied" {
            let _ = request_microphone_access();
        }
    }
    status
}

// ───────────────────────────── macOS ─────────────────────────────
#[cfg(target_os = "macos")]
mod macos {
    use core_foundation::base::TCFType;
    use core_foundation::boolean::CFBoolean;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::{CFString, CFStringRef};
    use objc2::runtime::AnyClass;
    use objc2::msg_send;
    use objc2_foundation::NSString;

    #[link(name = "ApplicationServices", kind = "framework")]
    extern "C" {
        fn AXIsProcessTrusted() -> bool;
        fn AXIsProcessTrustedWithOptions(options: core_foundation::dictionary::CFDictionaryRef) -> bool;
        static kAXTrustedCheckOptionPrompt: CFStringRef;
    }

    #[link(name = "AVFoundation", kind = "framework")]
    extern "C" {}

    pub fn is_trusted() -> bool {
        unsafe { AXIsProcessTrusted() }
    }

    pub fn prompt_accessibility() -> bool {
        unsafe {
            let key = CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt);
            let options = CFDictionary::from_CFType_pairs(&[(key, CFBoolean::true_value())]);
            AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef())
        }
    }

    /// AVAuthorizationStatus for audio capture.
    pub fn microphone() -> &'static str {
        let Some(class) = AnyClass::get("AVCaptureDevice") else { return "unknown" };
        // AVMediaTypeAudio is the string "soun".
        let media = NSString::from_str("soun");
        let status: isize = unsafe { msg_send![class, authorizationStatusForMediaType: &*media] };
        match status {
            0 => "not_determined",
            1 | 2 => "denied",
            3 => "granted",
            _ => "unknown",
        }
    }
}

#[cfg(target_os = "macos")]
pub fn is_paste_trusted() -> bool {
    macos::is_trusted()
}

fn microphone_status() -> String {
    #[cfg(target_os = "macos")]
    return macos::microphone().to_string();

    #[cfg(target_os = "windows")]
    return windows_microphone_consent();

    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    return "unknown".to_string();
}

fn paste_permission() -> (bool, bool) {
    #[cfg(target_os = "macos")]
    return (macos::is_trusted(), true);

    #[cfg(not(target_os = "macos"))]
    return (true, false);
}

/// Windows keeps a global and a desktop-apps ("NonPackaged") switch; either
/// set to "Deny" blocks the microphone for us.
#[cfg(target_os = "windows")]
fn windows_microphone_consent() -> String {
    let base = r"HKCU\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
    let read = |key: &str| -> Option<String> {
        let out = crate::process::command("reg")
            .args(["query", key, "/v", "Value"])
            .output()
            .ok()?;
        let text = String::from_utf8_lossy(&out.stdout).to_string();
        text.split_whitespace().last().map(str::to_string)
    };
    let global = read(base);
    let desktop = read(&format!(r"{base}\NonPackaged"));
    if global.as_deref() == Some("Deny") || desktop.as_deref() == Some("Deny") {
        "denied".to_string()
    } else if global.is_some() {
        "granted".to_string()
    } else {
        "unknown".to_string()
    }
}

fn linux_paste_tool() -> (Option<String>, Option<String>) {
    #[cfg(target_os = "linux")]
    {
        let wayland = std::env::var("XDG_SESSION_TYPE")
            .map(|s| s.eq_ignore_ascii_case("wayland"))
            .unwrap_or_else(|_| std::env::var("WAYLAND_DISPLAY").is_ok());
        if wayland {
            let found = which::which("wtype").is_ok() || which::which("ydotool").is_ok();
            return (Some("wayland".into()), if found { None } else { Some("wtype".into()) });
        }
        let found = which::which("xdotool").is_ok();
        return (Some("x11".into()), if found { None } else { Some("xdotool".into()) });
    }
    #[cfg(not(target_os = "linux"))]
    (None, None)
}

#[cfg(target_os = "macos")]
pub fn request_microphone_access() -> Result<(), String> {
    let _ = std::process::Command::new("open")
        .arg("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")
        .status();
    Ok(())
}

#[cfg(target_os = "macos")]
pub fn request_accessibility_access() -> Result<(), String> {
    macos::prompt_accessibility();
    let _ = std::process::Command::new("open")
        .arg("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
        .status();
    Ok(())
}

#[cfg(target_os = "windows")]
pub fn request_microphone_access() -> Result<(), String> {
    let _ = crate::process::command("cmd")
        .args(["/C", "start", "", "ms-settings:privacy-microphone"])
        .status();
    Ok(())
}

#[cfg(target_os = "windows")]
pub fn request_accessibility_access() -> Result<(), String> {
    // Windows has no permission gate for SendInput; nothing to open.
    Ok(())
}

#[cfg(target_os = "linux")]
pub fn request_microphone_access() -> Result<(), String> {
    // No unified privacy panel on Linux — try the common sound settings.
    let candidates: &[&[&str]] = &[
        &["gnome-control-center", "sound"],
        &["systemsettings5", "kcm_pulseaudio"],
        &["pavucontrol"],
    ];
    for args in candidates {
        if which::which(args[0]).is_ok() {
            let _ = std::process::Command::new(args[0]).args(&args[1..]).spawn();
            return Ok(());
        }
    }
    Err(crate::i18n::tr(
        "No sound settings panel found (install pavucontrol)",
        "Nenhum painel de som encontrado (instale o pavucontrol)",
    )
    .to_string())
}

#[cfg(target_os = "linux")]
pub fn request_accessibility_access() -> Result<(), String> {
    // Paste helpers are installed by the user; the UI shows the command.
    Ok(())
}
