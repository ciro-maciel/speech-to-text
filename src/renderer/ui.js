/**
 * UI helpers — platform key glyphs, hotkey capture state and logging.
 */

// ============================================================================
// PLATFORM
// ============================================================================
// macOS users expect ⌘⇧⌃⌥ glyphs; Windows/Linux users expect spelled-out
// modifiers ("Ctrl", "Shift", "Alt"). Detect once at module load.
export const IS_MAC = typeof navigator !== "undefined"
  && /Mac|iPhone|iPad/i.test(navigator.platform || navigator.userAgent || "");

/** Convert a Tauri-accelerator modifier name to its display string. */
export function glyph(mod) {
  const lower = String(mod).toLowerCase();
  if (IS_MAC) {
    switch (lower) {
      case "commandorcontrol":
      case "command":
      case "leftcommand":
      case "meta":            return "⌘";
      case "rightcommand":    return "R-⌘";
      case "control":
      case "ctrl":
      case "leftcontrol":     return "⌃";
      case "rightcontrol":    return "R-⌃";
      case "shift":
      case "leftshift":       return "⇧";
      case "rightshift":      return "R-⇧";
      case "option":
      case "alt":
      case "leftoption":      return "⌥";
      case "rightoption":     return "R-⌥";
      case "super":           return "⌘";
      default:                return mod;
    }
  }
  // Windows / Linux — plain names with a "+" separator handled by callers.
  switch (lower) {
    case "commandorcontrol":
    case "control":
    case "ctrl":
    case "leftcontrol":     return "Ctrl";
    case "rightcontrol":    return "R-Ctrl";
    case "command":
    case "leftcommand":
    case "meta":
    case "super":           return "Win";
    case "rightcommand":    return "R-Win";
    case "shift":
    case "leftshift":       return "Shift";
    case "rightshift":      return "R-Shift";
    case "option":
    case "alt":
    case "leftoption":      return "Alt";
    case "rightoption":     return "R-Alt";
    default:                return mod;
  }
}

/** Per-platform separator between modifiers in a hotkey display. */
export const HOTKEY_SEP = IS_MAC ? " " : "+";

// ============================================================================
// LOGGING
// ============================================================================

const logData = [];

export function getLogData() {
  return logData;
}

/** Log to the console and to the Rust stdout (dev); type: info | error. */
export function log(msg, type = "info") {
  const timestamp = new Date().toLocaleTimeString();
  logData.push({ timestamp, message: msg, type });
  if (logData.length > 500) logData.shift();
  console.log(`[${type}] ${msg}`);
  try { window.api?.logToMain?.(`[${type}] ${msg}`); } catch (e) {}
}

// ============================================================================
// HOTKEY RECORDING STATE
// ============================================================================

const heldModifiers = new Set();

export function updateHeldModifiers(event) {
  const code = event.code;
  if (event.type === "keydown") {
    if (code === "MetaLeft") heldModifiers.add("Command");
    if (code === "MetaRight") heldModifiers.add("RightCommand");
    if (code === "ControlLeft") heldModifiers.add("Control");
    if (code === "ControlRight") heldModifiers.add("RightControl");
    if (code === "AltLeft") heldModifiers.add("Option");
    if (code === "AltRight") heldModifiers.add("RightOption");
    if (code === "ShiftLeft") heldModifiers.add("Shift");
    if (code === "ShiftRight") heldModifiers.add("RightShift");
  } else if (event.type === "keyup") {
    if (code === "MetaLeft") heldModifiers.delete("Command");
    if (code === "MetaRight") heldModifiers.delete("RightCommand");
    if (code === "ControlLeft") heldModifiers.delete("Control");
    if (code === "ControlRight") heldModifiers.delete("RightControl");
    if (code === "AltLeft") heldModifiers.delete("Option");
    if (code === "AltRight") heldModifiers.delete("RightOption");
    if (code === "ShiftLeft") heldModifiers.delete("Shift");
    if (code === "ShiftRight") heldModifiers.delete("RightShift");

    if (!event.metaKey) {
      heldModifiers.delete("Command");
      heldModifiers.delete("RightCommand");
    }
    if (!event.ctrlKey) {
      heldModifiers.delete("Control");
      heldModifiers.delete("RightControl");
    }
    if (!event.altKey) {
      heldModifiers.delete("Option");
      heldModifiers.delete("RightOption");
    }
    if (!event.shiftKey) {
      heldModifiers.delete("Shift");
      heldModifiers.delete("RightShift");
    }
  }
}

export function clearHeldModifiers() {
  heldModifiers.clear();
}

export function getEventDisplayString(event) {
  const parts = [];

  if (heldModifiers.size > 0) {
    for (const mod of ["Command", "RightCommand", "Control", "RightControl",
                       "Option", "RightOption", "Shift", "RightShift"]) {
      if (heldModifiers.has(mod)) parts.push(glyph(mod));
    }
  } else {
    if (event.ctrlKey)  parts.push(glyph("Control"));
    if (event.altKey)   parts.push(glyph("Alt"));
    if (event.shiftKey) parts.push(glyph("Shift"));
    if (event.metaKey)  parts.push(glyph("Command"));
  }

  const key = event.key;
  const code = event.code;

  if (!["Meta", "Control", "Shift", "Alt", "Ctrl", "Command"].includes(key)) {
    let keyName = key.toUpperCase();
    if (code === "Space") keyName = "Space";
    else if (key === " ") keyName = "Space";
    else if (code.startsWith("Key")) keyName = code.replace("Key", "");
    else if (code.startsWith("Digit")) keyName = code.replace("Digit", "");
    parts.push(keyName);
  }

  return parts.join(HOTKEY_SEP);
}

export function buildAcceleratorString(event) {
  const parts = [];

  if (heldModifiers.has("Command")) parts.push("Command");
  if (heldModifiers.has("RightCommand")) parts.push("RightCommand");
  if (heldModifiers.has("Control")) parts.push("Control");
  if (heldModifiers.has("RightControl")) parts.push("RightControl");
  if (heldModifiers.has("Option")) parts.push("Option");
  if (heldModifiers.has("RightOption")) parts.push("RightOption");
  if (heldModifiers.has("Shift")) parts.push("Shift");
  if (heldModifiers.has("RightShift")) parts.push("RightShift");

  if (parts.length === 0) {
    if (event.metaKey) parts.push("CommandOrControl");
    if (event.ctrlKey) parts.push("Control");
    if (event.altKey) parts.push("Alt");
    if (event.shiftKey) parts.push("Shift");
  }

  const key = event.key;
  const code = event.code;

  if (["Meta", "Control", "Shift", "Alt", "Ctrl", "Command"].includes(key)) {
    return parts.length > 0 ? parts.join("+") : null;
  }

  let keyName = key;
  if (code.startsWith("Key")) keyName = code.replace("Key", "");
  else if (code.startsWith("Digit")) keyName = code.replace("Digit", "");
  else if (code === "Space" || key === " ") keyName = "Space";
  else if (code.startsWith("F") && code.length <= 3) keyName = code;
  else if (["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(key))
    keyName = key;
  else keyName = key.toUpperCase();

  parts.push(keyName);
  return parts.join("+");
}
