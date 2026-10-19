use std::sync::atomic::{AtomicU64, Ordering};
use tauri::{Emitter, Manager, Monitor, PhysicalPosition};

/// Bumped on every state change so a delayed hide from a finished dictation
/// never hides the overlay of the next one.
static OVERLAY_GENERATION: AtomicU64 = AtomicU64::new(0);

pub fn show_overlay(app: &tauri::AppHandle) {
    if let Some(overlay) = app.get_webview_window("overlay") {
        let anchor = {
            let state = app.state::<crate::AppState>();
            let cfg = state.config.lock().unwrap();
            cfg.overlay_position.clone()
        };
        position_overlay(app, &overlay, &anchor);
        let _ = overlay.show();
    }
}

pub fn hide_overlay(app: &tauri::AppHandle) {
    OVERLAY_GENERATION.fetch_add(1, Ordering::SeqCst);
    // Clear the HUD before hiding it. A hidden webview keeps its last frame,
    // and the next show painted it — the previous "Colado" and its text —
    // for an instant before "Ouvindo" arrived.
    let _ = app.emit_to("overlay", "overlay-state", serde_json::json!({ "state": "hidden" }));
    if let Some(overlay) = app.get_webview_window("overlay") {
        let _ = overlay.hide();
    }
}

/// Send a state to the overlay. `extra` carries what the state shows
/// (pasted text, word count, error message...). The overlay also learns the
/// anchor so it can hug the screen edge it sits on.
pub fn overlay_state(app: &tauri::AppHandle, state: &str, extra: serde_json::Value) {
    OVERLAY_GENERATION.fetch_add(1, Ordering::SeqCst);
    let (anchor, show_text, show_timer) = {
        let st = app.state::<crate::AppState>();
        let cfg = st.config.lock().unwrap();
        (cfg.overlay_position.clone(), cfg.overlay_show_text, cfg.overlay_show_timer)
    };
    let mut payload = serde_json::json!({
        "state": state,
        "anchor": anchor,
        "showText": show_text,
        "showTimer": show_timer,
    });
    if let (Some(obj), Some(more)) = (payload.as_object_mut(), extra.as_object()) {
        for (k, v) in more {
            obj.insert(k.clone(), v.clone());
        }
    }
    // The overlay window is wider than the HUD; let clicks fall through to
    // the app underneath, except when the HUD has a button to press.
    if let Some(overlay) = app.get_webview_window("overlay") {
        let _ = overlay.set_ignore_cursor_events(state != "nopaste");
    }
    let _ = app.emit_to("overlay", "overlay-state", payload);
}

/// Show a final state (pasted, nothing heard, error...) and hide it after
/// `ms`, unless another state replaced it in the meantime.
pub fn flash_overlay(app: &tauri::AppHandle, state: &str, extra: serde_json::Value, ms: u64) {
    // State first, then the window: the HUD is drawn before it is seen.
    overlay_state(app, state, extra);
    show_overlay(app);
    let generation = OVERLAY_GENERATION.load(Ordering::SeqCst);
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
        if OVERLAY_GENERATION.load(Ordering::SeqCst) == generation {
            hide_overlay(&app);
        }
    });
}

/// Pick the monitor that currently contains the mouse cursor. Falls back to
/// the overlay's last-known monitor, then the primary monitor.
fn monitor_under_cursor(app: &tauri::AppHandle, overlay: &tauri::WebviewWindow) -> Option<Monitor> {
    if let Ok(Some(pos)) = app.cursor_position().map(Some) {
        let monitors = app.available_monitors().ok()?;
        for m in monitors {
            let mp = m.position();
            let ms = m.size();
            let x = pos.x as i32;
            let y = pos.y as i32;
            if x >= mp.x
                && x < mp.x + ms.width as i32
                && y >= mp.y
                && y < mp.y + ms.height as i32
            {
                return Some(m);
            }
        }
    }
    overlay.current_monitor().ok().flatten()
        .or_else(|| overlay.primary_monitor().ok().flatten())
}

/// Return the visible work area (menu bar + Dock excluded) for the monitor.
/// On macOS we use NSScreen.visibleFrame via the cocoa bridge; on other
/// platforms we fall back to the full monitor bounds.
///
/// Returns (x, y, width, height) in physical pixels.
#[cfg(target_os = "macos")]
fn monitor_work_area(monitor: &Monitor) -> (i32, i32, i32, i32) {
    use objc2::msg_send;
    use objc2::runtime::AnyObject;
    use objc2::class;

    // Find the NSScreen whose `frame` matches this monitor's physical bounds.
    // Tauri gives us physical pixels; NSScreen gives points. We compare after
    // scaling NSScreen points by scale_factor.
    let monitor_pos = monitor.position();
    let monitor_size = monitor.size();
    let full = (
        monitor_pos.x,
        monitor_pos.y,
        monitor_size.width as i32,
        monitor_size.height as i32,
    );

    unsafe {
        let screens: *mut AnyObject = msg_send![class!(NSScreen), screens];
        if screens.is_null() {
            return full;
        }
        // NSArray.count returns NSUInteger which is `usize` on macOS, but the
        // objc2 type encoding mismatch (q vs Q) trips a panic when using
        // `count` directly via msg_send. We iterate via objectEnumerator and
        // break on nil instead — works regardless of encoding quirks.
        let enumerator: *mut AnyObject = msg_send![screens, objectEnumerator];
        if enumerator.is_null() {
            return full;
        }

        loop {
            let screen: *mut AnyObject = msg_send![enumerator, nextObject];
            if screen.is_null() { break; }

            let frame: objc2_foundation::NSRect = msg_send![screen, frame];
            let visible: objc2_foundation::NSRect = msg_send![screen, visibleFrame];
            let screen_scale: f64 = msg_send![screen, backingScaleFactor];

            // Convert frame (bottom-left origin, points) to top-left physical pixels.
            // For multi-monitor: NSScreen frame.x can be negative or offset; we
            // identify the right screen by checking size match in points.
            let fw = (frame.size.width * screen_scale) as i32;
            let fh = (frame.size.height * screen_scale) as i32;
            if fw != full.2 || fh != full.3 {
                continue;
            }

            // visibleFrame excludes the menu bar (top) and Dock (bottom-or-side).
            // Convert it from points→physical, and from bottom-left→top-left
            // using this screen's own frame as reference.
            let vis_x_points = visible.origin.x - frame.origin.x; // offset within screen, points
            let vis_y_points_from_bottom = visible.origin.y - frame.origin.y;
            let vis_y_points_from_top =
                frame.size.height - vis_y_points_from_bottom - visible.size.height;

            let work_x = monitor_pos.x + (vis_x_points * screen_scale) as i32;
            let work_y = monitor_pos.y + (vis_y_points_from_top * screen_scale) as i32;
            let work_w = (visible.size.width * screen_scale) as i32;
            let work_h = (visible.size.height * screen_scale) as i32;
            return (work_x, work_y, work_w, work_h);
        }
    }

    full
}

#[cfg(not(target_os = "macos"))]
fn monitor_work_area(monitor: &Monitor) -> (i32, i32, i32, i32) {
    let p = monitor.position();
    let s = monitor.size();
    (p.x, p.y, s.width as i32, s.height as i32)
}

/// Position the overlay against one of 9 anchors on the monitor under the
/// cursor. Anchor values match those persisted in config.overlay_position.
/// Uses the visible work area (menu bar + Dock excluded) so the overlay
/// never lands behind system chrome.
fn position_overlay(app: &tauri::AppHandle, overlay: &tauri::WebviewWindow, anchor: &str) {
    let Some(monitor) = monitor_under_cursor(app, overlay) else { return };

    let scale = monitor.scale_factor();
    let (area_x, area_y, area_w, area_h) = monitor_work_area(&monitor);

    let Ok(win_size) = overlay.outer_size() else { return };

    // Cosmetic margin inside the work area on all sides (physical pixels).
    let margin = (12.0 * scale) as i32;

    let ww = win_size.width as i32;
    let wh = win_size.height as i32;

    let left_x = area_x + margin;
    let center_x = area_x + (area_w - ww) / 2;
    let right_x = area_x + area_w - ww - margin;

    let top_y = area_y + margin;
    let middle_y = area_y + (area_h - wh) / 2;
    let bottom_y = area_y + area_h - wh - margin;

    let (x, y) = match anchor {
        "top-left"     => (left_x,   top_y),
        "top"          => (center_x, top_y),
        "top-right"    => (right_x,  top_y),
        "left"         => (left_x,   middle_y),
        "center"       => (center_x, middle_y),
        "right"        => (right_x,  middle_y),
        "bottom-left"  => (left_x,   bottom_y),
        "bottom"       => (center_x, bottom_y),
        "bottom-right" => (right_x,  bottom_y),
        _              => (right_x,  top_y),
    };

    let _ = overlay.set_position(PhysicalPosition::new(x, y));
}

/// The app window's size and floor, the same as the maker's other Mac apps.
pub const WINDOW_SIZE: (f64, f64) = (1040.0, 720.0);
pub const WINDOW_MIN_SIZE: (f64, f64) = (960.0, 640.0);

/// Bring up the app window, optionally on a given pane ("inicio", "ditado",
/// "permissoes"...). The window lives as a 1×1 stub while closed so the
/// renderer keeps the microphone warm (see lib.rs).
pub fn open_settings(app: &tauri::AppHandle, pane: Option<&str>) {
    let Some(window) = app.get_webview_window("main") else { return };
    let _ = window.set_decorations(true);
    let pane = pane.map(str::to_string);
    let app = app.clone();
    // On macOS, turning decorations back on rewrites the window's style mask
    // asynchronously (tao), and that rewrite drops the full-size content view.
    // The transparent title bar over the sidebar is applied once it has landed,
    // and the window grows from the 1×1 stub only then, so it never shows the
    // grey title bar.
    tauri::async_runtime::spawn(async move {
        #[cfg(target_os = "macos")]
        {
            tokio::time::sleep(std::time::Duration::from_millis(80)).await;
            let _ = window.set_title_bar_style(tauri::TitleBarStyle::Overlay);
        }
        use tauri::{LogicalSize, Size};
        let _ = window.set_min_size(Some(Size::Logical(LogicalSize { width: WINDOW_MIN_SIZE.0, height: WINDOW_MIN_SIZE.1 })));
        let _ = window.set_size(Size::Logical(LogicalSize { width: WINDOW_SIZE.0, height: WINDOW_SIZE.1 }));
        let _ = window.center();
        let _ = window.show();
        let _ = window.set_focus();
        if let Some(pane) = pane {
            let _ = app.emit_to("main", "navigate", serde_json::json!({ "pane": pane }));
        }
    });
}
