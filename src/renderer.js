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

const api = window.api;
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];

setLogCallback((msg, type) => log(msg, type === "error" ? "error" : "info"));

let config = null;
let appInfo = { version: "", platform: "" };
let historyCache = [];
let currentPane = "inicio";

const KIND_LABEL = { local: "Local", refined: "Refinado", translated: "Traduzido", nothing: "—" };
const LANGUAGE_NAME = { en: "inglês", pt: "português", es: "espanhol", fr: "francês", de: "alemão", it: "italiano", ja: "japonês", ko: "coreano", zh: "chinês", ru: "russo" };
const MODEL_SIZE = { tiny: 77691713, base: 147951465, small: 487601967, medium: 1533763059, "large-v3-turbo": 1624555275 };
const MODEL_NOTE = { tiny: "rascunho rápido", "large-v3-turbo": "o mais preciso" };

// ─────────────────────────────────────────────────────────────────
// Formatting
// ─────────────────────────────────────────────────────────────────
const decimal = (n, digits = 1) => n.toFixed(digits).replace(".", ",");
const formatSeconds = (ms) => `${decimal(ms / 1000)}s`;
const formatBytes = (b) => (b >= 1e9 ? `${decimal(b / 1e9)} GB` : `${Math.round(b / 1e6)} MB`);
const formatInt = (n) => n.toLocaleString("pt-BR");
const escapeHtml = (t) => String(t ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

function keyLabel(part) {
  const p = part.trim();
  const named = { space: "Espaço", enter: "↵", escape: "Esc", esc: "Esc", tab: "Tab", arrowup: "↑", arrowdown: "↓", arrowleft: "←", arrowright: "→" }[p.toLowerCase()];
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
  if (!accelerator) return `<span class="note">sem atalho</span>`;
  return orderedParts(accelerator).map((p) => `<span class="kbd">${escapeHtml(keyLabel(p))}</span>`).join("");
}

function hotkeyText(accelerator) {
  if (!accelerator) return "sem atalho";
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
    $('[data-role="edit"]', el).textContent = "Editar";
  });
}

function startCapture(entry) {
  if (capturing) finishCapture(false);
  capturing = { ...entry, pending: null };
  $('[data-role="keys"]', entry.el).hidden = true;
  const cap = $('[data-role="capture"]', entry.el);
  cap.hidden = false;
  cap.textContent = "Digite o atalho";
  $('[data-role="edit"]', entry.el).textContent = "Salvar";
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
  const verb = config.triggerMode === "hold" ? "Segure" : "Toque";
  let sub = `${verb} ${kbdHtml(config.hotkey)} para ditar`;
  if (config.translateEnabled && config.translateHotkey) {
    sub += `, ${kbdHtml(config.translateHotkey)} para traduzir para ${LANGUAGE_NAME[config.targetLanguage] || "inglês"}`;
  }
  $("#home-sub").innerHTML = `${sub}.`;
  $("#paste-last-hint").textContent = `${hotkeyText(appInfo.pasteLastHotkey || "CommandOrControl+Alt+V")} cola a última em qualquer app`;
  $("#history-note").textContent = config.historyDays === 0
    ? "O histórico não é guardado: estas linhas somem quando o app fecha."
    : `Guardado por ${config.historyDays} dias neste computador. Só o texto, nunca o áudio.`;
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
    list.innerHTML = `<p class="empty">Nenhum ditado ainda. Segure o atalho e fale.</p>`;
    return;
  }
  list.innerHTML = recent.map((e, i) => {
    const time = new Date(e.at).toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });
    if (e.kind === "nothing") {
      return `<div class="hrow" data-i="${i}"><span class="ht">${time}</span><span class="hx muted">Nada ouvido · nada colado</span><span class="ha">—</span></div>`;
    }
    const original = e.original && e.original !== e.text ? `<small>Original: ${escapeHtml(e.original)}</small>` : "";
    return `<button type="button" class="hrow" data-i="${i}"><span class="ht">${time}</span><span class="hx">${escapeHtml(e.text)}${original}</span><span class="ha">${KIND_LABEL[e.kind] || ""}</span></button>`;
  }).join("");
  $$("button.hrow", list).forEach((row) => row.addEventListener("click", async () => {
    const entry = recent[Number(row.dataset.i)];
    await api.copyToClipboard(entry.text);
    row.classList.add("copied");
    $(".ha", row).textContent = "Copiado";
    setTimeout(() => { row.classList.remove("copied"); $(".ha", row).textContent = KIND_LABEL[entry.kind] || ""; }, 1400);
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
  select.innerHTML = `<option value="">Padrão do sistema</option>` +
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
    if (active) action = `<span class="tag on">Em uso</span>`;
    else if (downloading === m.name) action = `<button class="lnk" type="button" data-cancel="${m.name}">Cancelar</button>`;
    else if (m.exists) action = `<button class="lnk" type="button" data-use="${m.name}">Usar</button>`;
    else action = `<button class="lnk" type="button" data-download="${m.name}" ${downloading ? "disabled" : ""}>Baixar</button>`;
    const note = MODEL_NOTE[m.name] ? `<small>${MODEL_NOTE[m.name]}</small>` : "";
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
  $("#download-text").textContent = `Baixando ${name}…`;
  renderModels();
  try {
    await api.downloadModel(name);
    $("#download-text").textContent = `${name} baixado. Clique em "Usar" para trocar.`;
  } catch (err) {
    $("#download-text").textContent = String(err).includes("cancel") ? "Download cancelado." : `Falha ao baixar: ${err}`;
  } finally {
    downloading = null;
    $("#download-progress").hidden = true;
    renderModels();
  }
}

api.onModelDownloadProgress((d) => {
  $("#download-bar").style.width = `${d.progress}%`;
  $("#download-text").textContent = `Baixando ${d.model} · ${Math.round(d.progress)}% de ${formatBytes(d.total)}`;
});

// ─────────────────────────────────────────────────────────────────
// Glossary
// ─────────────────────────────────────────────────────────────────
const glossaryTerms = () => (config.refinementGlossary || "").split(/[\n,;]/).map((t) => t.trim()).filter(Boolean);

function renderGlossary() {
  const terms = glossaryTerms();
  $("#term-list").innerHTML = terms.map((t, i) =>
    `<span class="term">${escapeHtml(t)}<button type="button" data-remove="${i}" aria-label="Remover ${escapeHtml(t)}">×</button></span>`).join("");
  $$("[data-remove]").forEach((b) => b.addEventListener("click", () => {
    const next = glossaryTerms().filter((_, i) => i !== Number(b.dataset.remove));
    save("refinementGlossary", next.join("\n"));
  }));
  $("#term-note").textContent = terms.length
    ? `${terms.length} ${terms.length === 1 ? "palavra" : "palavras"}. Entram no prompt do Whisper e no refinamento.`
    : "Nenhuma palavra ainda. Nomes próprios e termos técnicos são os que mais ganham.";
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
  status.textContent = "Testando…";
  try {
    const ms = await api.testOpenrouter();
    status.textContent = `Respondeu em ${formatSeconds(ms)}.`;
  } catch (err) {
    status.classList.add("error");
    status.textContent = `Não respondeu: ${err}`;
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
    granted: ["LIBERADO", "ok", "O app consegue te ouvir."],
    denied: ["BLOQUEADO", "no", "Libere o app na lista de microfone do sistema."],
    not_determined: ["PENDENTE", "no", "O sistema vai perguntar na primeira vez."],
    unknown: ["LIVRE", "ok", "O sistema não controla o microfone por app."],
  }[s.microphone] || ["—", "ok", ""];
  rows.push({ title: "Microfone", status: mic[0], cls: mic[1], hint: mic[2], missing: mic[1] === "no" });
  if (s.accessibilityRequired) {
    rows.push(s.accessibility
      ? { title: "Colagem automática", status: "LIBERADO", cls: "ok", hint: "Acessibilidade ligada." }
      : { title: "Colagem automática", status: "PENDENTE", cls: "no", hint: "Acessibilidade · ligue a chave do Speech to Text na lista.", missing: true });
  } else if (s.platform === "linux") {
    const session = s.session === "wayland" ? "Wayland" : "X11";
    rows.push(s.missingPasteTool
      ? { title: "Colagem automática", status: "FALTA", cls: "no", hint: `Sessão ${session} · instale: <span class="cmd">${INSTALL[s.missingPasteTool] || s.missingPasteTool}</span>`, missing: true }
      : { title: "Colagem automática", status: "PRONTA", cls: "ok", hint: `Sessão ${session}.` });
  } else {
    rows.push({ title: "Colagem automática", status: "LIBERADO", cls: "ok", hint: "Não precisa de permissão neste sistema." });
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
    ? "Tudo liberado: o app ouve e cola sem pedir nada."
    : `${missing === 1 ? "Falta uma" : "Faltam duas"}. Sem elas o app não te ouve ou o texto fica só na área de transferência.`;
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
  const names = s.accessibilityRequired ? [["Microfone", mic], ["Acessibilidade", s.accessibility]] : [["Microfone", mic]];
  const off = names.filter(([, on]) => !on).map(([name]) => name);
  const line = $("#status-line");
  line.classList.toggle("off", off.length > 0);
  $("use", line).setAttribute("href", `icons.svg#${off.length ? "lock" : "check"}`);
  const list = (off.length ? off : names.map(([name]) => name)).join(" e ");
  const many = (off.length || names.length) > 1;
  const word = off.length
    ? (many ? "desligados" : off[0] === "Microfone" ? "desligado" : "desligada")
    : (many ? "ligados" : "ligado");
  $("span", line).textContent = `${list} ${word}`;
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
  label.textContent = "Verificando…";
  const s = await api.checkForUpdates();
  button.disabled = false;
  const now = new Date().toLocaleTimeString("pt-BR", { hour: "2-digit", minute: "2-digit" });
  if (s.ready) {
    label.innerHTML = `Versão ${escapeHtml(s.latest)} baixada · <a href="#" id="install-update">reiniciar e atualizar</a>`;
    $("#install-update").addEventListener("click", (e) => {
      e.preventDefault();
      api.installUpdate();
    });
  } else if (s.newer) {
    label.innerHTML = `Versão ${escapeHtml(s.latest)} disponível · <a href="${escapeHtml(s.url)}" data-external>baixar</a>`;
  } else if (s.error) {
    label.classList.add("error");
    label.textContent = `Não foi possível verificar: ${s.error}`;
  } else {
    label.textContent = `Você está na mais recente · verificado às ${now}`;
  }
});

$("#copy-diagnostics").addEventListener("click", async () => {
  const button = $("#copy-diagnostics");
  const text = await api.getDiagnostics();
  await api.copyToClipboard(text);
  button.textContent = "Copiado";
  setTimeout(() => { button.textContent = "Copiar"; }, 1400);
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
  $("#ob-step-label").textContent = `${n} de 3`;
  syncLevelMonitor();
  if (n === 1) startPermissionPolling();
  if (n === 3) {
    const verb = config.triggerMode === "hold" ? "Segure" : "Toque";
    $("#ob-hotkey-sub").innerHTML = `${verb} ${kbdHtml(config.hotkey)} com o cursor no campo abaixo e fale. ${config.triggerMode === "hold" ? "Solte" : "Toque de novo"} para colar.`;
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
  result.textContent = "Ouvindo… fale agora.";
  const ok = await startAudioRecording();
  if (!ok) {
    result.className = "ob-result error";
    result.textContent = "O microfone não abriu. Volte e libere a permissão.";
    button.disabled = false;
    return;
  }
  await new Promise((r) => setTimeout(r, 4000));
  const audio = await stopAudioRecording(false);
  result.textContent = "Transcrevendo…";
  try {
    const r = await api.sendAudioForTranscription(audio || new ArrayBuffer(0), "test");
    if (r.text && !r.isNoise) {
      result.className = "ob-result";
      result.textContent = `"${r.text}"`;
    } else {
      result.className = "ob-result error";
      result.textContent = "Nada ouvido. Confira se o microfone certo está escolhido e fale mais perto.";
    }
  } catch (err) {
    result.className = "ob-result error";
    result.textContent = `A transcrição falhou: ${err}`;
  } finally {
    button.disabled = false;
    button.textContent = "Gravar de novo";
  }
});

api.onTranscription((data) => {
  if ($("#onboarding").hidden || $('.ob-step[data-step="3"]').hidden) return;
  const result = $("#ob-hotkey-result");
  if (data.text && !data.isNoise) {
    result.className = "ob-result";
    result.textContent = "Colado. Está tudo pronto.";
  } else {
    result.className = "ob-result muted";
    result.textContent = "Nada ouvido. Tente de novo, falando enquanto segura o atalho.";
  }
});

// ─────────────────────────────────────────────────────────────────
// Init
// ─────────────────────────────────────────────────────────────────
async function init() {
  appInfo = await api.getAppInfo();
  document.body.dataset.platform = appInfo.platform;
  $$("[data-platform]").forEach((el) => { el.hidden = el.dataset.platform !== appInfo.platform; });
  $("#nav-foot").textContent = `Versão ${appInfo.version} · por Ciro Cesar Maciel`;

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
