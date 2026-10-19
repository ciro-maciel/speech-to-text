/**
 * Audio Module — Microphone capture
 *
 * Design notes:
 * - When `preferredDeviceId` is empty/null/"default", uses no `deviceId`
 *   constraint so the OS picks the system default mic. The OS default
 *   automatically follows the user changing it in System Settings → Sound.
 * - When a specific device id is given, requests that device. If it's
 *   unavailable, falls back to the system default instead of throwing.
 * - Re-acquires the stream lazily if it stopped (device disconnected,
 *   AudioContext suspended, etc.).
 * - Listens to `devicechange` so the stream is refreshed after the user
 *   plugs/unplugs a mic while pre-heat is on.
 */

import { t } from "../i18n.js";

let audioContext = null;
let mediaStreamSource = null;
let scriptProcessor = null;
let highPassFilter = null;
let compressor = null;
let gainNode = null;
let warmStream = null;
let audioBuffers = [];
let isRecording = false;
let currentPreferredDeviceId = null;
// Settings-window level meter; receives levels even when not recording.
let monitorCallback = null;

/** Feed `cb(level)` with the live input level (0–1); null stops it. */
export function setLevelMonitor(cb) { monitorCallback = cb; }

let logCallback = null;
export function setLogCallback(cb) { logCallback = cb; }
function log(msg, type) {
  if (logCallback) logCallback(msg, type);
  else console.log(msg);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Persist the user's preferred device id without acquiring a stream.
 * Used to make sure a lazy warm-up on first record uses the right device,
 * even when pre-heat is off.
 */
export function setPreferredDevice(deviceId) {
  const normalized = (!deviceId || deviceId === "default") ? null : deviceId;
  currentPreferredDeviceId = normalized;
}

export async function getAvailableMicrophones() {
  const devices = await navigator.mediaDevices.enumerateDevices();
  return devices
    .filter((d) => d.kind === "audioinput")
    .map((d) => ({
      deviceId: d.deviceId,
      label: d.label || `${t("dict.mic")} ${d.deviceId.slice(0, 8)}`,
    }));
}

/**
 * Acquire the mic and build the processing graph.
 *
 * @param {string|null} preferredDeviceId
 *   - null / "" / "default" → use the OS default (no deviceId constraint)
 *   - any other id → try that device, fall back to default if unavailable
 *
 * Idempotent: if a healthy stream already exists for the same preference,
 * returns immediately.
 */
export async function warmUpMicrophone(preferredDeviceId = null) {
  const normalizedPref =
    !preferredDeviceId || preferredDeviceId === "default" ? null : preferredDeviceId;

  if (isStreamHealthy() && currentPreferredDeviceId === normalizedPref) return true;

  await teardownStream();
  currentPreferredDeviceId = normalizedPref;

  const baseConstraints = {
    echoCancellation: false,
    noiseSuppression: true,
    autoGainControl: true,
    channelCount: 1,
  };

  try {
    let constraints;
    if (normalizedPref) {
      // Request the specific device but allow fallback if unavailable
      constraints = { audio: { ...baseConstraints, deviceId: { ideal: normalizedPref } } };
    } else {
      // No deviceId -> OS picks the system default mic
      constraints = { audio: baseConstraints };
    }
    warmStream = await navigator.mediaDevices.getUserMedia(constraints);

    const track = warmStream.getAudioTracks()[0];
    const labelSuffix = normalizedPref ? "" : " (Default do Sistema)";
    log(`Microphone warmed up: ${track?.label || "default"}${labelSuffix}`);
    log(`Track state: enabled=${track?.enabled} muted=${track?.muted} readyState=${track?.readyState}`);
    try {
      const settings = track?.getSettings?.();
      if (settings) log(`Track settings: sampleRate=${settings.sampleRate} channels=${settings.channelCount}`);
    } catch (e) {}

    // Recover from the OS device changing under us
    track?.addEventListener("ended", () => {
      log("Stream do microfone encerrado pelo sistema. Reaquecendo...");
      warmStream = null;
      warmUpMicrophone(currentPreferredDeviceId).catch(() => {});
    });

    // IMPORTANT: do NOT force a specific sampleRate on macOS WKWebView —
    // when the AudioContext rate differs from the mic's native rate, WebKit
    // can silently emit empty buffers. We let the context match the device
    // and resample to 16kHz in JS at the end (whisper-cli accepts 16kHz).
    audioContext = new (window.AudioContext || window.webkitAudioContext)();
    if (audioContext.state === "suspended") await audioContext.resume();
    log(`AudioContext sampleRate=${audioContext.sampleRate}`);

    mediaStreamSource = audioContext.createMediaStreamSource(warmStream);

    // Use a minimal pipeline: source -> ScriptProcessor -> destination.
    // (Filter chain removed — was silencing audio on macOS WKWebView.)
    scriptProcessor = audioContext.createScriptProcessor(4096, 1, 1);
    let firstNonZeroSeen = false;
    let zeroTickCounter = 0;
    scriptProcessor.onaudioprocess = (event) => {
      const inputData = event.inputBuffer.getChannelData(0);

      // Detect a stream that's persistently silent (likely a muted device
      // at the OS level) and warn the user once.
      if (!firstNonZeroSeen) {
        for (let i = 0; i < inputData.length; i++) {
          if (inputData[i] !== 0) { firstNonZeroSeen = true; break; }
        }
        if (!firstNonZeroSeen) {
          zeroTickCounter++;
          if (zeroTickCounter === 50) {
            log("The selected microphone is not picking up audio. Check the input volume in the system sound settings.", "error");
          }
        }
      }

      if (!isRecording && !monitorCallback) return;

      let sum = 0;
      let allZero = true;
      for (let i = 0; i < inputData.length; i++) {
        const v = inputData[i];
        sum += v * v;
        if (v !== 0) allZero = false;
      }
      const level = Math.min(1, Math.sqrt(sum / inputData.length) * 5);
      monitorCallback?.(level);
      if (!isRecording) return;

      audioBuffers.push(new Float32Array(inputData));
      // -1 tells the overlay this chunk was pure digital silence: a muted or
      // disconnected device, not a quiet room.
      window.api?.sendAudioLevel?.(allZero ? -1 : level);
    };

    mediaStreamSource.connect(scriptProcessor);
    scriptProcessor.connect(audioContext.destination);

    log("Microphone ready for instant recording");
    return true;
  } catch (err) {
    console.error("warmUpMicrophone failed:", err);
    log(`Falha ao acessar microfone: ${err.name || err.message}`, "error");
    await teardownStream();
    return false;
  }
}

export async function stopMicrophone() {
  await teardownStream();
  return true;
}

export async function startAudioRecording() {
  // Make absolutely sure the stream is healthy before recording starts.
  if (!isStreamHealthy()) {
    log("Stream not ready, warming up the microphone again...");
    const ok = await warmUpMicrophone(currentPreferredDeviceId);
    if (!ok) return false;
  }
  if (audioContext?.state === "suspended") {
    try { await audioContext.resume(); } catch (e) {}
  }
  audioBuffers = [];
  isRecording = true;
  return true;
}

/** Drop the current recording without producing audio (Esc). */
export function cancelAudioRecording() {
  isRecording = false;
  audioBuffers = [];
}

export async function stopAudioRecording(shouldCoolDown = false) {
  isRecording = false;

  if (audioBuffers.length === 0) {
    if (shouldCoolDown) await teardownStream();
    return null;
  }

  const totalLength = audioBuffers.reduce((acc, buf) => acc + buf.length, 0);
  const merged = new Float32Array(totalLength);
  let offset = 0;
  for (const buf of audioBuffers) {
    merged.set(buf, offset);
    offset += buf.length;
  }
  audioBuffers = [];

  let sum = 0;
  for (let i = 0; i < merged.length; i++) sum += merged[i] * merged[i];
  const avgRms = Math.sqrt(sum / merged.length);
  log(`Average volume: ${avgRms.toFixed(4)}`);
  if (avgRms < 0.001) log("Audio is almost pure silence.");

  const targetSampleRate = 16000;
  const downsampled = downsampleBuffer(merged, audioContext.sampleRate, targetSampleRate);
  const wav = encodeWAV(downsampled, targetSampleRate);

  if (shouldCoolDown) await teardownStream();
  return wav;
}

// ---------------------------------------------------------------------------
// Auto-recover on device hot-swap (when pre-heat is on)
// ---------------------------------------------------------------------------

if (typeof navigator !== "undefined" && navigator.mediaDevices?.addEventListener) {
  navigator.mediaDevices.addEventListener("devicechange", () => {
    if (warmStream || audioContext) {
      log("Audio device changed. Warming up the microphone again...");
      warmUpMicrophone(currentPreferredDeviceId).catch(() => {});
    }
  });
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

function isStreamHealthy() {
  // We do NOT reject on `track.muted` — that flag is transient on macOS and
  // a muted track will start producing audio again on its own. Rejecting on
  // muted causes spurious teardown/reacquire cycles.
  if (!audioContext || audioContext.state === "closed") return false;
  if (!warmStream || !warmStream.active) return false;
  const track = warmStream.getAudioTracks()[0];
  if (!track || track.readyState !== "live") return false;
  return true;
}

async function teardownStream() {
  try {
    if (warmStream) warmStream.getTracks().forEach((t) => t.stop());
  } catch (e) {}
  try {
    if (scriptProcessor) scriptProcessor.disconnect();
    if (gainNode) gainNode.disconnect();
    if (compressor) compressor.disconnect();
    if (highPassFilter) highPassFilter.disconnect();
    if (mediaStreamSource) mediaStreamSource.disconnect();
  } catch (e) {}
  try {
    if (audioContext && audioContext.state !== "closed") await audioContext.close();
  } catch (e) {}

  warmStream = null;
  audioContext = null;
  mediaStreamSource = null;
  scriptProcessor = null;
  highPassFilter = null;
  compressor = null;
  gainNode = null;
  audioBuffers = [];
  isRecording = false;
}

function downsampleBuffer(buffer, sampleRate, outSampleRate) {
  if (outSampleRate === sampleRate) return buffer;
  if (outSampleRate > sampleRate) return buffer;
  const ratio = sampleRate / outSampleRate;
  const newLength = Math.round(buffer.length / ratio);
  const result = new Float32Array(newLength);
  let outIdx = 0;
  let inIdx = 0;
  while (outIdx < result.length) {
    const nextIn = Math.round((outIdx + 1) * ratio);
    let acc = 0, count = 0;
    for (let i = inIdx; i < nextIn && i < buffer.length; i++) { acc += buffer[i]; count++; }
    result[outIdx++] = count === 0 ? 0 : acc / count;
    inIdx = nextIn;
  }
  return result;
}

function encodeWAV(samples, sampleRate) {
  const buffer = new ArrayBuffer(44 + samples.length * 2);
  const view = new DataView(buffer);
  writeString(view, 0, "RIFF");
  view.setUint32(4, 36 + samples.length * 2, true);
  writeString(view, 8, "WAVE");
  writeString(view, 12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeString(view, 36, "data");
  view.setUint32(40, samples.length * 2, true);
  floatTo16BitPCM(view, 44, samples);
  return buffer;
}

function floatTo16BitPCM(view, offset, input) {
  for (let i = 0; i < input.length; i++, offset += 2) {
    const s = Math.max(-1, Math.min(1, input[i]));
    view.setInt16(offset, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
}

function writeString(view, offset, string) {
  for (let i = 0; i < string.length; i++) view.setUint8(offset + i, string.charCodeAt(i));
}
