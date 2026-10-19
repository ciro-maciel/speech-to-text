//! "Mute the Mac while dictating" (macOS only).
//!
//! Muting the output instead of pausing media: there's no public API to
//! pause whatever is playing, and a play/pause key would start playback when
//! nothing was playing. We only unmute if we were the ones who muted.
//!
//! Both operations run on one worker thread, in order, so a very short
//! dictation can't restore before the mute happened and leave the Mac mute.

#[cfg(target_os = "macos")]
mod imp {
    use std::sync::mpsc::{channel, Sender};
    use std::sync::{LazyLock, Mutex};

    enum Op {
        Mute,
        Restore,
    }

    static WORKER: LazyLock<Mutex<Sender<Op>>> = LazyLock::new(|| {
        let (tx, rx) = channel::<Op>();
        std::thread::spawn(move || {
            let mut we_muted = false;
            for op in rx {
                match op {
                    Op::Mute => {
                        let already = osascript("output muted of (get volume settings)")
                            .map(|s| s == "true")
                            .unwrap_or(true);
                        if !already && osascript("set volume output muted true").is_some() {
                            we_muted = true;
                        }
                    }
                    Op::Restore => {
                        if we_muted {
                            let _ = osascript("set volume output muted false");
                            we_muted = false;
                        }
                    }
                }
            }
        });
        Mutex::new(tx)
    });

    fn osascript(script: &str) -> Option<String> {
        let out = std::process::Command::new("osascript").args(["-e", script]).output().ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string())
    }

    pub fn mute_output() {
        let _ = WORKER.lock().unwrap().send(Op::Mute);
    }

    pub fn restore_output() {
        let _ = WORKER.lock().unwrap().send(Op::Restore);
    }
}

#[cfg(target_os = "macos")]
pub use imp::{mute_output, restore_output};

#[cfg(not(target_os = "macos"))]
pub fn mute_output() {}

#[cfg(not(target_os = "macos"))]
pub fn restore_output() {}
