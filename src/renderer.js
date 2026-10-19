/**
 * Renderer — the settings window and the recording side of the pipeline.
 *
 * This window never closes (on macOS it shrinks to a 1×1 stub) because it
 * owns the warm microphone. Rust drives recording through events
 * (start/stop/cancel-recording); every setting goes through `setSetting`,
 * and `config-changed` keeps this window in sync with the tray menu.
 */

import {
  warmUpMicrophone,
  startAudioRecording,
  stopAudioRecording,
  cancelAudioRecording,
  setLogCallback,
  setPreferredDevice,
  getAvailableMicrophones,
  setLevelMonitor,
} from "./renderer/audio.js";

import {
  log,
  glyph,
  IS_MAC,
  updateHeldModifiers,
  clearHeldModifiers,
  getEventDisplayString,
  buildAcceleratorString,
} from "./renderer/ui.js";

import { LOCALE, t, tn, applyI18n, formatInt, formatDecimal, formatTime } from "./i18n.js";

const api = window.api;
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

setLogCallback((msg, type) => log(msg, type === "error" ? "error" : "info"));

applyI18n();
$$("[data-i18n-days]").forEach((b) => { b.textContent = t("sys.history.days", { n: formatInt(Number(b.dataset.i18nDays)) }); });

let config = null;
let appInfo = { version: "", platform: "" };
let historyCache = [];
let currentPane = "inicio";

const kindLabel = (kind) => (kind === "nothing" ? "—" : ["local", "refined", "translated"].includes(kind) ? t(`kind.${kind}`) : "");
// Mid-sentence: Portuguese writes language names in lower case, English capitalizes them.
const languageName = (code) => {
  const name = t(`lang.${code}`) || t("lang.en");
  return LOCALE === "pt-BR" ? name.toLowerCase() : name;
};
const MODEL_SIZE = { tiny: 77691713, base: 147951465, small: 487601967, medium: 1533763059, "large-v3-turbo": 1624555275 };
const MODEL_NOTE = { tiny: "model.tiny", "large-v3-turbo": "model.large" };

// ─────────────────────────────────────────────────────────────────
// Formatting
// ─────────────────────────────────────────────────────────────────
const formatSeconds = (ms) => `${formatDecimal(ms / 1000)}s`;
const formatBytes = (b) => (b >= 1e9 ? `${formatDecimal(b / 1e9)} GB` : `${formatInt(Math.round(b / 1e6))} MB`);
const escapeHtml = (t) => String(t ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function keyLabel(part) {
  const p = part.trim();
  const named = { space: t("key.space"), enter: "↵", escape: "Esc", esc: "Esc", tab: "Tab", arrowup: "↑", arrowdown: "↓", arrowleft: "←", arrowright: "→" }[p.toLowerCase()];
  if (named) return named;
  const g = glyph(p);
  return g === p ? p.toUpperCase() : g;
}

// Apple's modifier order is ⌃ ⌥ ⇧ ⌘; Windows/Linux read Ctrl, Alt, Shift.
const MODIFIER_ORDER = ["control", "ctrl", "leftcontrol", "rightcontrol", "alt", "option", "leftoption", "rightoption", "rightalt",
  "shift", "leftshift", "rightshift", "commandorcontrol", "cmdorctrl", "command", "leftcommand", "rightcommand", "meta", "super"];
function orderedParts(accelerator) {
  const rank = (p) => { const i = MODIFIER_ORDER.indexOf(p.trim().toLowerCase()); return i === -1 ? 99 : i; };
  return accelerator.split("+").sort((a, b) => rank(a) - rank(b));
}

function kbdHtml(accelerator) {
  if (!accelerator) return `<span class="note">${t("hotkey.none")}</span>`;
  return orderedParts(accelerator).map((p) => `<span class="kbd">${escapeHtml(keyLabel(p))}</span>`).join("");
}

function hotkeyText(accelerator) {
  if (!accelerator) return t("hotkey.none");
  return orderedParts(accelerator).map(keyLabel).join(IS_MAC ? "" : "+");
}

// ─────────────────────────────────────────────────────────────────
// Navigation
// ─────────────────────────────────────────────────────────────────
function showPane(name) {
  if (!$(`.pane[data-pane="${name}"]`)) name = "inicio";
  currentPane = name;
  $$(".groups button[data-pane]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.pane === name)));
  $$(".pane").forEach((p) => { p.hidden = p.dataset.pane !== name; });
  $(".main").scrollTop = 0;
  syncLevelMonitor();
  if (name === "permissoes") startPermissionPolling();
  if (name === "transcricao") renderModels();
  if (name === "inicio") refreshHistory();
}

$$(".groups button[data-pane]").forEach((b) => b.addEventListener("click", () => showPane(b.dataset.pane)));
api.onNavigate((p) => {
  if (!$("#onboarding").hidden) return;
  showPane(p?.pane || "inicio");
});

// ─────────────────────────────────────────────────────────────────
// Generic setting controls: [data-setting] on switches, segments, selects
// ─────────────────────────────────────────────────────────────────
async function save(key, value) {
  try {
    applyConfig(await api.setSetting(key, value));
  } catch (err) {
    log(`setting ${key} failed: ${err}`, "error");
    applyConfig(await api.getConfig());
  }
}

function renderControls() {
  $$(".sw[data-setting]").forEach((sw) => sw.setAttribute("aria-checked", String(!!config[sw.dataset.setting])));
  $$(".seg[data-setting]").forEach((seg) => {
    const value = String(config[seg.dataset.setting]);
    $$("button", seg).forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.value === value)));
  });
  $$("select[data-setting]").forEach((sel) => { sel.value = config[sel.dataset.setting]; });
}

$$(".sw[data-setting]").forEach((sw) => sw.addEventListener("click", () => {
  const key = sw.dataset.setting;
  save(key, !config[key]);
}));
$$(".seg[data-setting]").forEach((seg) => $$("button", seg).forEach((b) => b.addEventListener("click", () => {
  const raw = b.dataset.value;
  save(seg.dataset.setting, seg.dataset.type === "number" ? Number(raw) : raw);
})));
$$("select[data-setting]").forEach((sel) => sel.addEventListener("change", () => save(sel.dataset.setting, sel.value)));

function applyConfig(next) {
  const previous = config;
  config = next;
  renderControls();
  renderHotkeys();
  renderHome();
  renderGlossary();
  renderOverlayPane();
  renderProvider();
  if (previous && previous.selectedMicrophone !== next.selectedMicrophone) {
    setPreferredDevice(next.selectedMicrophone || null);
    warmUpMicrophone(next.selectedMicrophone || null).then(() => loadMicrophones());
  }
  if (previous && previous.model !== next.model) renderModels();
}

api.onConfigChanged((next) => applyConfig(next));

// ─────────────────────────────────────────────────────────────────
// Hotkey capture (dictation and translation)
// ─────────────────────────────────────────────────────────────────
const HOTKEYS = [
  { el: $("#hk-transcribe"), key: "hotkey" },
  { el: $("#hk-translate"), key: "translateHotkey" },
];
let capturing = null; // { el, key, pending }

function renderHotkeys() {
  HOTKEYS.forEach(({ el, key }) => {
    if (capturing?.el === el) return;
    $('[data-role="keys"]', el).innerHTML = kbdHtml(config[key]);
    $('[data-role="keys"]', el).hidden = false;
    $('[data-role="capture"]', el).hidden = true;
    $('[data-role="edit"]', el).textContent = t("hotkey.edit");
  });
}

function startCapture(entry) {
  if (capturing) finishCapture(false);
  capturing = { ...entry, pending: null };
  $('[data-role="keys"]', entry.el).hidden = true;
  const cap = $('[data-role="capture"]', entry.el);
  cap.hidden = false;
  cap.textContent = t("hotkey.type");
  $('[data-role="edit"]', entry.el).textContent = t("hotkey.save");
  clearHeldModifiers();
  api.setRecordingHotkey(true);
}

async function finishCapture(keep) {
  if (!capturing) return;
  const { key, pending } = capturing;
  capturing = null;
  clearHeldModifiers();
  api.setRecordingHotkey(false);
  if (keep && pending) await save(key, pending);
  else renderHotkeys();
}

HOTKEYS.forEach((entry) => {
  $('[data-role="edit"]', entry.el).addEventListener("click", (e) => {
    e.stopPropagation();
    capturing?.el === entry.el ? finishCapture(true) : startCapture(entry);
  });
});
document.addEventListener("click", (e) => {
  if (capturing && !capturing.el.contains(e.target)) finishCapture(true);
});
document.addEventListener("keydown", (event) => {
  if (!capturing) return;
  event.preventDefault();
  event.stopPropagation();
  updateHeldModifiers(event);
  if (event.key === "Escape") { finishCapture(false); return; }
  const display = getEventDisplayString(event);
  if (display) $('[data-role="capture"]', capturing.el).textContent = display;
  // A shortcut needs a main key: modifier-only combos can't be registered.
  const accelerator = buildAcceleratorString(event);
  const modifierOnly = ["Meta", "Control", "Shift", "Alt", "OS"].includes(event.key);
  if (accelerator && !modifierOnly) capturing.pending = accelerator;
}, true);
document.addEventListener("keyup", (event) => {
  if (!capturing) return;
  event.preventDefault();
  updateHeldModifiers(event);
}, true);

// ─────────────────────────────────────────────────────────────────
// Home: status, today's numbers, recent transcriptions
// ─────────────────────────────────────────────────────────────────
function renderHome() {
  let sub = t(config.triggerMode === "hold" ? "home.sub.hold" : "home.sub.toggle", { keys: kbdHtml(config.hotkey) });
  if (config.translateEnabled && config.translateHotkey) {
    sub += t("home.sub.translate", { keys: kbdHtml(config.translateHotkey), language: escapeHtml(languageName(config.targetLanguage)) });
  }
  $("#home-sub").innerHTML = `${sub}.`;
  $("#paste-last-hint").textContent = t("home.pasteLast", { keys: hotkeyText(appInfo.pasteLastHotkey || "CommandOrControl+Alt+V") });
  $("#history-note").textContent = config.historyDays === 0
    ? t("home.historyOff")
    : t("home.historyKept", { days: formatInt(config.historyDays) });
}

async function refreshHistory() {
  try { historyCache = await api.getHistory(); } catch (e) { historyCache = []; }
  const startOfDay = new Date(); startOfDay.setHours(0, 0, 0, 0);
  const today = historyCache.filter((e) => e.at >= startOfDay.getTime() && e.kind !== "nothing");
  $("#stat-count").textContent = formatInt(today.length);
  $("#stat-words").textContent = formatInt(today.reduce((n, e) => n + e.words, 0));
  $("#stat-latency").textContent = today.length
    ? formatSeconds(today.reduce((n, e) => n + e.latencyMs, 0) / today.length)
    : "—";

  const list = $("#history-list");
  const recent = historyCache.slice(0, 5);
  if (!recent.length) {
    list.innerHTML = `<p class="empty">${t("home.empty")}</p>`;
    return;
  }
  list.innerHTML = recent.map((e, i) => {
    const time = formatTime(new Date(e.at));
    if (e.kind === "nothing") {
      return `<div class="hrow" data-i="${i}"><span class="ht">${time}</span><span class="hx muted">${t("home.nothing")}</span><span class="ha">—</span></div>`;
    }
    const original = e.original && e.original !== e.text ? `<small>${t("home.original", { text: escapeHtml(e.original) })}</small>` : "";
    return `<button type="button" class="hrow" data-i="${i}"><span class="ht">${time}</span><span class="hx">${escapeHtml(e.text)}${original}</span><span class="ha">${kindLabel(e.kind)}</span></button>`;
  }).join("");
  $$("button.hrow", list).forEach((row) => row.addEventListener("click", async () => {
    const entry = recent[Number(row.dataset.i)];
    await api.copyToClipboard(entry.text);
    row.classList.add("copied");
    $(".ha", row).textContent = t("copied");
    setTimeout(() => { row.classList.remove("copied"); $(".ha", row).textContent = kindLabel(entry.kind); }, 1400);
  }));
}

api.onHistoryChanged(() => {
  refreshHistory();
  if (currentPane === "transcricao") renderModels();
});

// ─────────────────────────────────────────────────────────────────
// Microphones and level meters
// ─────────────────────────────────────────────────────────────────
function buildMeter(el, bars) {
  el.innerHTML = "<i></i>".repeat(bars);
  return $$("i", el);
}
const micMeterBars = buildMeter($("#mic-meter"), 8);
const obMeterBars = buildMeter($("#ob-meter"), 14);

function drawMeter(bars, level, max) {
  bars.forEach((b, i) => {
    const wobble = 0.55 + 0.45 * Math.abs(Math.sin(Date.now() / 130 + i));
    b.style.height = `${Math.round(2 + Math.min(1, level * 1.4) * wobble * max)}px`;
  });
}

function syncLevelMonitor() {
  const onboardingVoice = !$("#onboarding").hidden && !$('.ob-step[data-step="2"]').hidden;
  if (onboardingVoice) setLevelMonitor((l) => drawMeter(obMeterBars, l, 22));
  else if (currentPane === "ditado") setLevelMonitor((l) => drawMeter(micMeterBars, l, 12));
  else setLevelMonitor(null);
}

async function loadMicrophones() {
  let mics = [];
  try { mics = await getAvailableMicrophones(); } catch (e) { log(`microphones: ${e}`, "error"); }
  mics = mics.filter((m) => m.deviceId !== "default" && m.deviceId !== "communications");
  const select = $("#mic-select");
  select.innerHTML = `<option value="">${t("dict.mic.default")}</option>` +
    mics.map((m) => `<option value="${escapeHtml(m.deviceId)}">${escapeHtml(m.label)}</option>`).join("");
  select.value = mics.some((m) => m.deviceId === config.selectedMicrophone) ? config.selectedMicrophone : "";
  api.setMicrophones(mics.map((m) => ({ deviceId: m.deviceId, label: m.label })));
}

$("#mic-select").addEventListener("change", (e) => save("selectedMicrophone", e.target.value));
navigator.mediaDevices?.addEventListener?.("devicechange", () => loadMicrophones());

// ─────────────────────────────────────────────────────────────────
// Recording (driven by Rust)
// ─────────────────────────────────────────────────────────────────
let audioCtx = null;
function beep(freq) {
  if (!config?.sounds) return;
  try {
    audioCtx = audioCtx || new AudioContext();
    const osc = audioCtx.createOscillator();
    const gain = audioCtx.createGain();
    osc.frequency.value = freq;
    gain.gain.setValueAtTime(0.06, audioCtx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.0001, audioCtx.currentTime + 0.09);
    osc.connect(gain).connect(audioCtx.destination);
    osc.start();
    osc.stop(audioCtx.currentTime + 0.1);
  } catch (e) {}
}

api.onStartRecording(async (payload) => {
  beep(880);
  log(`recording started (${payload?.mode || "transcribe"})`);
  await startAudioRecording();
});

api.onStopRecording(async (payload) => {
  const mode = payload?.mode || "transcribe";
  beep(660);
  const audio = await stopAudioRecording(false);
  api.sendAudioForTranscription(audio || new ArrayBuffer(0), mode).catch((e) => log(`transcription: ${e}`, "error"));
});

api.onCancelRecording(() => {
  cancelAudioRecording();
  beep(440);
  log("recording cancelled");
});

// ─────────────────────────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────────────────────────
let downloading = null;

async function renderModels() {
  let models = [];
  try { models = await api.getModels(); } catch (e) { log(`models: ${e}`, "error"); }
  const timing = {};
  historyCache.filter((e) => e.kind !== "nothing" && e.model).forEach((e) => {
    (timing[e.model] = timing[e.model] || []).push(e.latencyMs);
  });
  $("#model-list").innerHTML = models.map((m) => {
    const size = formatBytes(m.exists ? m.size : MODEL_SIZE[m.name] || 0);
    const times = timing[m.name];
    const time = times?.length ? formatSeconds(times.reduce((a, b) => a + b, 0) / times.length) : "—";
    const active = m.name === config.model;
    let action;
    if (active) action = `<span class="tag on">${t("model.inUse")}</span>`;
    else if (downloading === m.name) action = `<button class="lnk" type="button" data-cancel="${m.name}">${t("model.cancel")}</button>`;
    else if (m.exists) action = `<button class="lnk" type="button" data-use="${m.name}">${t("model.use")}</button>`;
    else action = `<button class="lnk" type="button" data-download="${m.name}" ${downloading ? "disabled" : ""}>${t("model.download")}</button>`;
    const note = MODEL_NOTE[m.name] ? `<small>${t(MODEL_NOTE[m.name])}</small>` : "";
    return `<div class="mr${active ? " on" : ""}"><span><b>${m.name}</b>${note}</span><span>${size}</span><span>${time}</span>${action}</div>`;
  }).join("");
  $$("[data-use]").forEach((b) => b.addEventListener("click", () => save("model", b.dataset.use)));
  $$("[data-download]").forEach((b) => b.addEventListener("click", () => downloadModel(b.dataset.download)));
  $$("[data-cancel]").forEach((b) => b.addEventListener("click", () => api.cancelDownloadModel(b.dataset.cancel)));
}

async function downloadModel(name) {
  downloading = name;
  $("#download-progress").hidden = false;
  $("#download-bar").style.width = "0%";
  $("#download-text").textContent = t("model.downloading", { model: name });
  renderModels();
  try {
    await api.downloadModel(name);
    $("#download-text").textContent = t("model.downloaded", { model: name });
  } catch (err) {
    $("#download-text").textContent = String(err).includes("cancel") ? t("model.cancelled") : t("model.failed", { error: err });
  } finally {
    downloading = null;
    $("#download-progress").hidden = true;
    renderModels();
  }
}

api.onModelDownloadProgress((d) => {
  $("#download-bar").style.width = `${d.progress}%`;
  $("#download-text").textContent = t("model.progress", { model: d.model, percent: formatInt(Math.round(d.progress)), total: formatBytes(d.total) });
});

// ─────────────────────────────────────────────────────────────────
// Glossary
// ─────────────────────────────────────────────────────────────────
const glossaryTerms = () => (config.refinementGlossary || "").split(/[\n,;]/).map((t) => t.trim()).filter(Boolean);

function renderGlossary() {
  const terms = glossaryTerms();
  $("#term-list").innerHTML = terms.map((term, i) =>
    `<span class="term">${escapeHtml(term)}<button type="button" data-remove="${i}" aria-label="${t("gl.remove", { term: escapeHtml(term) })}">×</button></span>`).join("");
  $$("[data-remove]").forEach((b) => b.addEventListener("click", () => {
    const next = glossaryTerms().filter((_, i) => i !== Number(b.dataset.remove));
    save("refinementGlossary", next.join("\n"));
  }));
  $("#term-note").textContent = terms.length
    ? tn("gl.count", terms.length)
    : t("gl.empty");
}

$("#term-form").addEventListener("submit", (e) => {
  e.preventDefault();
  const input = $("#term-input");
  const value = input.value.trim();
  if (!value) return;
  const terms = glossaryTerms();
  if (!terms.some((t) => t.toLowerCase() === value.toLowerCase())) terms.push(value);
  input.value = "";
  save("refinementGlossary", terms.join("\n"));
});

// ─────────────────────────────────────────────────────────────────
// AI provider
// ─────────────────────────────────────────────────────────────────
function renderProvider() {
  const model = $("#or-model");
  const key = $("#or-key");
  if (document.activeElement !== model) model.value = config.openrouterModel || "";
  if (document.activeElement !== key) key.value = config.openrouterApiKey || "";
}
$("#or-model").addEventListener("change", (e) => save("openrouterModel", e.target.value.trim()));
$("#or-key").addEventListener("change", (e) => save("openrouterApiKey", e.target.value.trim()));
$("#or-test").addEventListener("click", async () => {
  const status = $("#or-status");
  const button = $("#or-test");
  button.disabled = true;
  status.classList.remove("error");
  status.textContent = t("ai.testing");
  try {
    const ms = await api.testOpenrouter();
    status.textContent = t("ai.replied", { time: formatSeconds(ms) });
  } catch (err) {
    status.classList.add("error");
    status.textContent = t("ai.noReply", { error: err });
  } finally {
    button.disabled = false;
  }
});

// ─────────────────────────────────────────────────────────────────
// Overlay pane
// ─────────────────────────────────────────────────────────────────
function renderOverlayPane() {
  $$("#posgrid button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.position === config.overlayPosition)));
  $("#ov-preview-text").hidden = !config.overlayShowText;
}
$$("#posgrid button").forEach((b) => b.addEventListener("click", () => save("overlayPosition", b.dataset.position)));

// ─────────────────────────────────────────────────────────────────
// Permissions
// ─────────────────────────────────────────────────────────────────
const INSTALL = { xdotool: "sudo apt install xdotool", wtype: "sudo apt install wtype" };

function permissionRows(s) {
  const rows = [];
  const mic = {
    granted: [t("perm.status.granted"), "ok", t("perm.mic.granted")],
    denied: [t("perm.status.blocked"), "no", t("perm.mic.denied")],
    not_determined: [t("perm.status.pending"), "no", t("perm.mic.pending")],
    unknown: [t("perm.status.free"), "ok", t("perm.mic.unknown")],
  }[s.microphone] || ["—", "ok", ""];
  rows.push({ title: t("perm.microphone"), status: mic[0], cls: mic[1], hint: mic[2], missing: mic[1] === "no" });
  const paste = t("perm.autoPaste");
  if (s.accessibilityRequired) {
    rows.push(s.accessibility
      ? { title: paste, status: t("perm.status.granted"), cls: "ok", hint: t("perm.ax.on") }
      : { title: paste, status: t("perm.status.pending"), cls: "no", hint: t("perm.ax.off"), missing: true });
  } else if (s.platform === "linux") {
    const session = s.session === "wayland" ? "Wayland" : "X11";
    rows.push(s.missingPasteTool
      ? { title: paste, status: t("perm.status.missing"), cls: "no", hint: t("perm.linux.missing", { session, command: `<span class="cmd">${INSTALL[s.missingPasteTool] || s.missingPasteTool}</span>` }), missing: true }
      : { title: paste, status: t("perm.status.ready"), cls: "ok", hint: t("perm.linux.ready", { session }) });
  } else {
    rows.push({ title: paste, status: t("perm.status.granted"), cls: "ok", hint: t("perm.notNeeded") });
  }
  return rows;
}

function renderPermissionRows(container, s) {
  container.innerHTML = permissionRows(s).map((r) =>
    `<div class="row"><span>${r.title}<small>${r.hint}</small></span><span class="${r.cls}">${r.status}</span></div>`).join("");
}

function renderPermissions(s) {
  const missing = permissionRows(s).filter((r) => r.missing).length;
  renderPermissionRows($("#perm-rows"), s);
  renderPermissionRows($("#ob-perms"), s);
  $("#perm-sub").textContent = missing === 0
    ? t("perm.sub.ok")
    : t(missing === 1 ? "perm.sub.one" : "perm.sub.two");
  renderStatusLine(s);
  $("#perm-grant").hidden = missing === 0;
  $("#ob-grant").disabled = missing === 0;
  const flag = $("#perm-flag");
  flag.hidden = missing === 0;
  flag.textContent = String(missing);
  return missing;
}

// The sidebar's status line: what the app needs, said as a fact (15-app-mac.md).
function renderStatusLine(s) {
  const mic = !["denied", "not_determined"].includes(s.microphone);
  const names = s.accessibilityRequired
    ? [["microphone", mic], ["accessibility", s.accessibility]]
    : [["microphone", mic]];
  const off = names.filter(([, on]) => !on).map(([id]) => id);
  const line = $("#status-line");
  line.classList.toggle("off", off.length > 0);
  $("use", line).setAttribute("href", `icons.svg#${off.length ? "lock" : "check"}`);
  const shown = off.length ? off : names.map(([id]) => id);
  const list = shown.map((id) => t(`perm.${id}`)).join(t("status.and"));
  const many = shown.length > 1;
  // Portuguese agrees in gender: "Acessibilidade desligada", "Microfone desligado".
  const key = off.length
    ? (many ? "status.off.other" : off[0] === "accessibility" ? "status.off.oneFeminine" : "status.off.one")
    : (many ? "status.on.other" : "status.on.one");
  $("span", line).textContent = t(key, { list });
}
$("#status-line").addEventListener("click", () => {
  if ($("#status-line").classList.contains("off")) showPane("permissoes");
});

async function refreshPermissions() {
  try { return renderPermissions(await api.checkPermissions()); } catch (e) { return 0; }
}

let permissionPoll = null;
function startPermissionPolling(seconds = 120) {
  clearInterval(permissionPoll);
  const until = Date.now() + seconds * 1000;
  refreshPermissions();
  permissionPoll = setInterval(async () => {
    const visible = currentPane === "permissoes" || !$("#onboarding").hidden;
    const missing = await refreshPermissions();
    if (!visible || missing === 0 || Date.now() > until) {
      clearInterval(permissionPoll);
      api.refreshTray?.();
    }
  }, 1000);
}

async function grantPermissions() {
  const status = await api.checkPermissions();
  // The microphone prompt only appears from getUserMedia.
  if (status.microphone === "not_determined") await warmUpMicrophone(config.selectedMicrophone || null);
  await api.requestPermissions();
  startPermissionPolling();
}
$("#perm-grant").addEventListener("click", grantPermissions);
window.addEventListener("focus", () => refreshPermissions());

// ─────────────────────────────────────────────────────────────────
// System
// ─────────────────────────────────────────────────────────────────
const autolaunch = $("#autolaunch");
autolaunch.addEventListener("click", async () => {
  const next = autolaunch.getAttribute("aria-checked") !== "true";
  try {
    await api.setAutoLaunch(next);
    autolaunch.setAttribute("aria-checked", String(next));
  } catch (err) {
    log(`autolaunch: ${err}`, "error");
  }
});

$("#clear-history").addEventListener("click", async () => {
  await api.clearHistory();
  refreshHistory();
});

$("#check-updates").addEventListener("click", async () => {
  const label = $("#update-status");
  const button = $("#check-updates");
  button.disabled = true;
  label.classList.remove("error");
  label.textContent = t("sys.updates.checking");
  const s = await api.checkForUpdates();
  button.disabled = false;
  const now = formatTime(new Date());
  if (s.ready) {
    label.innerHTML = t("sys.updates.ready", { version: escapeHtml(s.latest) });
    $("#install-update").addEventListener("click", (e) => {
      e.preventDefault();
      api.installUpdate();
    });
  } else if (s.newer) {
    label.innerHTML = t("sys.updates.newer", { version: escapeHtml(s.latest), url: escapeHtml(s.url) });
  } else if (s.error) {
    label.classList.add("error");
    label.textContent = t("sys.updates.error", { error: s.error });
  } else {
    label.textContent = t("sys.updates.latest", { time: now });
  }
});

$("#copy-diagnostics").addEventListener("click", async () => {
  const button = $("#copy-diagnostics");
  const text = await api.getDiagnostics();
  await api.copyToClipboard(text);
  button.textContent = t("copied");
  setTimeout(() => { button.textContent = t("sys.copy"); }, 1400);
});
$("#open-logs").addEventListener("click", () => api.openLogFolder());

document.addEventListener("click", (e) => {
  const link = e.target.closest("a[data-external]");
  if (!link) return;
  e.preventDefault();
  api.openUrl(link.getAttribute("href"));
});

// ─────────────────────────────────────────────────────────────────
// First run
// ─────────────────────────────────────────────────────────────────
function showStep(n) {
  $$(".ob-step").forEach((s) => { s.hidden = s.dataset.step !== String(n); });
  $("#ob-step-label").textContent = t("ob.stepOf", { n });
  syncLevelMonitor();
  if (n === 1) startPermissionPolling();
  if (n === 3) {
    $("#ob-hotkey-sub").innerHTML = t(config.triggerMode === "hold" ? "ob.3.sub.hold" : "ob.3.sub.toggle", { keys: kbdHtml(config.hotkey) });
    $("#ob-field").focus();
  }
}

function startOnboarding() {
  $("#onboarding").hidden = false;
  showStep(1);
}

$("#ob-grant").addEventListener("click", grantPermissions);
$("#ob-next-1").addEventListener("click", () => showStep(2));
$("#ob-back-2").addEventListener("click", () => showStep(1));
$("#ob-next-2").addEventListener("click", () => showStep(3));
$("#ob-back-3").addEventListener("click", () => showStep(2));
$("#ob-finish").addEventListener("click", async () => {
  await save("onboarded", true);
  $("#onboarding").hidden = true;
  showPane("inicio");
});

$("#ob-record").addEventListener("click", async () => {
  const button = $("#ob-record");
  const result = $("#ob-result");
  button.disabled = true;
  result.className = "ob-result muted";
  result.textContent = t("ob.listening");
  const ok = await startAudioRecording();
  if (!ok) {
    result.className = "ob-result error";
    result.textContent = t("ob.micFailed");
    button.disabled = false;
    return;
  }
  await new Promise((r) => setTimeout(r, 4000));
  const audio = await stopAudioRecording(false);
  result.textContent = t("ob.transcribing");
  try {
    const r = await api.sendAudioForTranscription(audio || new ArrayBuffer(0), "test");
    if (r.text && !r.isNoise) {
      result.className = "ob-result";
      result.textContent = `"${r.text}"`;
    } else {
      result.className = "ob-result error";
      result.textContent = t("ob.nothingHeard");
    }
  } catch (err) {
    result.className = "ob-result error";
    result.textContent = t("ob.failed", { error: err });
  } finally {
    button.disabled = false;
    button.textContent = t("ob.recordAgain");
  }
});

api.onTranscription((data) => {
  if ($("#onboarding").hidden || $('.ob-step[data-step="3"]').hidden) return;
  const result = $("#ob-hotkey-result");
  if (data.text && !data.isNoise) {
    result.className = "ob-result";
    result.textContent = t("ob.pasted");
  } else {
    result.className = "ob-result muted";
    result.textContent = t("ob.tryAgain");
  }
});

// ─────────────────────────────────────────────────────────────────
// Init
// ─────────────────────────────────────────────────────────────────
async function init() {
  appInfo = await api.getAppInfo();
  document.body.dataset.platform = appInfo.platform;
  $$("[data-platform]").forEach((el) => { el.hidden = el.dataset.platform !== appInfo.platform; });
  $("#nav-foot").textContent = t("nav.foot", { version: appInfo.version });

  applyConfig(await api.getConfig());
  autolaunch.setAttribute("aria-checked", String(await api.getAutoLaunch()));

  // The microphone stays warm for instant recording.
  setPreferredDevice(config.selectedMicrophone || null);
  const permissions = await api.checkPermissions();
  renderPermissions(permissions);
  if (permissions.microphone !== "denied" && config.onboarded) {
    await warmUpMicrophone(config.selectedMicrophone || null);
  }
  await loadMicrophones();
  await refreshHistory();
  renderModels();

  if (!config.onboarded) startOnboarding();
  log("settings window ready");
}

init().catch((err) => log(`init failed: ${err?.message || err}`, "error"));
