//! Child processes that must not flash a console window.
//!
//! On Windows the app is a GUI program (windows_subsystem = "windows"), and a
//! console program it starts — `reg`, `cmd`, `taskkill` — opens its own black
//! console window unless told not to. The sidecars go through the shell
//! plugin, which already sets this flag.

pub fn command(program: &str) -> std::process::Command {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let mut cmd = std::process::Command::new(program);
    cmd.creation_flags(CREATE_NO_WINDOW);
    cmd
}
