// The microphone, through AVAudioEngine: converted to 16 kHz mono floats, what Parakeet takes.
// Cold (the default since 2.1, 28/10/2026), it opens on the key and is closed between dictations,
// so the orange dot is off while nobody dictates; `isReady` turns on with the first real audio,
// which is when the person hears the signal and starts. Warm, the engine runs between dictations
// and keeps the last 300 ms, so the first syllable said with the key is not lost.
import AVFoundation
import CoreAudio
import Foundation

struct Microphone: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Written on the audio thread, read on the main one.
private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var isRecording = false
    private var samples: [Float] = []
    private var preRoll: [Float] = []
    private static let preRollCount = 4800 // 300 ms at 16 kHz
    /// The device is live for this recording: a buffer that is not exact silence came, or about a
    /// second of buffers from a device that only sends silence (muted: the overlay says so).
    private var isLive = false
    private var buffersSinceBegin = 0
    /// Called once per recording, on the audio thread, the moment it is live.
    var onLive: @Sendable () -> Void = {}
    var level: Double = 0
    var isZero = false
    /// When the last buffer arrived: a running engine that stops delivering has stalled.
    var lastBuffer = Date.distantPast

    func append(_ chunk: [Float]) {
        var peak: Float = 0, sum: Float = 0
        for s in chunk { peak = max(peak, abs(s)); sum += s * s }
        let rms = chunk.isEmpty ? 0 : (sum / Float(chunk.count)).squareRoot()
        lock.lock()
        level = min(1, Double(rms) * 12)
        isZero = peak == 0
        lastBuffer = Date()
        var becameLive = false
        if isRecording {
            samples.append(contentsOf: chunk)
            buffersSinceBegin += 1
            if !isLive, peak > 0 || buffersSinceBegin > 45 { isLive = true; becameLive = true }
        } else {
            preRoll.append(contentsOf: chunk)
            if preRoll.count > Self.preRollCount { preRoll.removeFirst(preRoll.count - Self.preRollCount) }
        }
        lock.unlock()
        if becameLive { onLive() }
    }

    /// Returns how many pre-roll samples went in.
    func begin(withPreRoll: Bool) -> Int {
        lock.lock(); defer { lock.unlock() }
        samples = withPreRoll ? preRoll : []
        preRoll = []
        isRecording = true
        isLive = false
        buffersSinceBegin = 0
        return samples.count
    }

    func end() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        isRecording = false
        let out = samples
        samples = []
        return out
    }

    func reading() -> (level: Double, isZero: Bool, lastBuffer: Date) {
        lock.lock(); defer { lock.unlock() }
        return (level, isZero, lastBuffer)
    }
}

/// One converter to 16 kHz mono, rebuilt when the buffers' format changes. Only the tap uses it.
private final class Converter: @unchecked Sendable {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) { self.target = target }

    func `for`(_ format: AVAudioFormat) -> AVAudioConverter? {
        if converter?.inputFormat != format { converter = AVAudioConverter(from: format, to: target) }
        return converter
    }
}

/// The AVAudioEngine, touched only on its own queue. Starting a microphone usually takes the
/// system about 0.3 s, and now and then over a second (measured 28/10/2026 on a USB microphone,
/// 1 open in 5): on the main thread that froze the app, "preparing" included. Between dictations
/// the graph is kept built and prepared, not started, so the microphone stays off.
private final class Engine: @unchecked Sendable {
    let queue = DispatchQueue(label: "speech-to-text.microphone", qos: .userInteractive)
    private var engine: AVAudioEngine?
    private var uid: String?
    private var isPrepared = false

    func prepare(uid: String?, capture: Capture) {
        if engine == nil || uid != self.uid { build(uid: uid, capture: capture) }
        guard let engine, !engine.isRunning, !isPrepared else { return }
        engine.prepare()
        isPrepared = true
    }

    func start(uid: String?, capture: Capture) -> (engine: AVAudioEngine, sampleRate: Double, device: String)? {
        prepare(uid: uid, capture: capture)
        guard let engine else { return nil }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("[recorder] engine failed: \(error)")
                discard()
                return nil
            }
        }
        isPrepared = false
        return (engine, engine.inputNode.outputFormat(forBus: 0).sampleRate, deviceName(engine))
    }

    func stop() {
        engine?.stop()
        isPrepared = false
    }

    /// The next prepare builds a new graph: a device that came or went changes the format.
    func discard() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isPrepared = false
    }

    private func build(uid: String?, capture: Capture) {
        discard()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid, let id = Recorder.deviceID(uid: uid), let unit = input.audioUnit {
            var device = id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return }
        // The tap takes the node's own format (nil) and converts from whatever each buffer carries:
        // a Bluetooth headset changes format as its microphone opens, and a tap given the format
        // read a moment before raised an exception that took the app down (28/10/2026).
        let converter = Converter(target: target)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let converter = converter.for(buffer.format) else { return }
            let ratio = 16000 / buffer.format.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, let data = out.floatChannelData else { return }
            capture.append(Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))))
        }
        self.engine = engine
        self.uid = uid
    }

    /// The device the input unit really has, by name: what a choice did, not what was asked.
    private func deviceName(_ engine: AVAudioEngine) -> String {
        guard let unit = engine.inputNode.audioUnit else { return "none" }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr else { return "?" }
        return Recorder.string(id, kAudioObjectPropertyName) ?? "#\(id)"
    }
}

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var level: Double = 0
    /// Exact digital silence for a while: a muted or disconnected device.
    @Published private(set) var isSignalDead = false
    @Published private(set) var microphones: [Microphone] = []
    @Published private(set) var isRunning = false
    /// While recording: the microphone is delivering, so what is said now is kept.
    @Published private(set) var isReady = false
    /// Called once per recording, when `isReady` turns on after the microphone opened.
    var onReady: () -> Void = {}

    private let engine = Engine()
    private let capture = Capture()
    private var deviceUID: String?
    private var isWarm = true
    private var isRecording = false
    private var meter: Timer?
    private var zeroSince: Date?
    private var configObserver: NSObjectProtocol?
    private var engineStartedAt: Date?
    /// An open in flight; a close bumps the generation, so an open that lands after it is dropped.
    private var openGeneration = 0
    private var isOpening = false
    private var beganAt = Date()
    private var openedDevice = "none"

    nonisolated static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    nonisolated static var isDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    init() {
        refreshMicrophones()
        capture.onLive = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.markReady() } }
        }
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Applies the chosen device and warmth; opens the microphone now if warm.
    func configure(deviceUID: String?, warm: Bool) {
        let changed = deviceUID != self.deviceUID
        self.deviceUID = deviceUID
        isWarm = warm
        if changed || (!warm && !isRecording) { stopEngine() }
        if warm { startEngine() }
    }

    /// What the microphone was doing when the last dictation began, for the diagnostic dump.
    private(set) var lastBegin = ""

    func begin() {
        isRecording = true
        let wasRunning = isRunning
        let quietMs = Int(Date().timeIntervalSince(capture.reading().lastBuffer) * 1000)
        beganAt = Date()
        // An open microphone that delivered just now is live already; anything else waits for audio.
        isReady = wasRunning && quietMs < 200
        if !isRunning { startEngine() }
        // An open microphone has a pre-roll only if it ran long enough to fill it.
        let hasPreRoll = isRunning && (engineStartedAt.map { Date().timeIntervalSince($0) > 0.3 } ?? false)
        let preRoll = capture.begin(withPreRoll: hasPreRoll)
        lastBegin = "device=\(wasRunning ? openedDevice : "opening") engineWasRunning=\(wasRunning) msSinceLastBuffer=\(quietMs) preRollSamples=\(preRoll)"
    }

    func end() -> [Float] {
        isRecording = false
        isReady = false
        let samples = capture.end()
        if !isWarm { stopEngine() }
        return samples
    }

    func cancel() { _ = end() }

    private func markReady() {
        guard isRecording, !isReady else { return }
        isReady = true
        NSLog("[recorder] ready after %.0fms", Date().timeIntervalSince(beganAt) * 1000)
        onReady()
    }

    private func tick() {
        let reading = capture.reading()
        // An open microphone that went quiet (sleep, a device that came or went, the system taking
        // the input) is reopened now, not when the shortcut needs it: a USB microphone takes about
        // a second to deliver after it opens, and that second was the start of the dictation.
        // While dictating too: a Bluetooth headset switches to its microphone profile as it opens,
        // which changes the format and stops the engine before the first buffer.
        if isRunning, let started = engineStartedAt, Date().timeIntervalSince(started) > 1,
           Date().timeIntervalSince(reading.lastBuffer) > 0.5 {
            NSLog("[recorder] stalled, reopening")
            stopEngine(rebuild: true)
            startEngine()
            return
        }
        level = isRunning ? reading.level : 0
        if isRunning && reading.isZero {
            if zeroSince == nil { zeroSince = Date() }
            isSignalDead = Date().timeIntervalSince(zeroSince!) > 1.5
        } else {
            zeroSince = nil
            isSignalDead = false
        }
    }

    // MARK: - Engine

    private func startEngine() {
        guard Self.isAuthorized, !isRunning, !isOpening else { return }
        isOpening = true
        let generation = openGeneration
        let uid = deviceUID, capture = capture, engine = engine
        let asked = Date()
        engine.queue.async {
            let opened = engine.start(uid: uid, capture: capture)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self, generation == self.openGeneration else { return }
                    self.isOpening = false
                    guard let opened else { return }
                    self.isRunning = true
                    self.engineStartedAt = Date()
                    self.openedDevice = opened.device
                    NSLog("[recorder] microphone open in %.0fms (%.0f Hz, warm: %@)", Date().timeIntervalSince(asked) * 1000,
                          opened.sampleRate, self.isWarm ? "yes" : "no")
                    self.observeConfiguration(of: opened.engine)
                }
            }
        }
    }

    /// A device that comes or goes rebuilds the engine on the new configuration. Choosing a
    /// device posts this notice too, right after the engine opens; rebuilding then posted it
    /// again, and a chosen microphone never delivered a sample. So: not in the first two
    /// seconds, and only if the engine really stopped (the stall watchdog covers the rest).
    private func observeConfiguration(of avEngine: AVAudioEngine) {
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: avEngine, queue: .main) { [weak self, weak avEngine] _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.engineStartedAt, Date().timeIntervalSince(started) > 2,
                      avEngine?.isRunning == false else { return }
                self.stopEngine(rebuild: true)
                self.refreshMicrophones()
                if self.isWarm || self.isRecording { self.startEngine() }
            }
        }
    }

    /// Closes the microphone and prepares the graph again, off the main thread.
    func stopEngine(rebuild: Bool = false) {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        openGeneration += 1
        isOpening = false
        isRunning = false
        engineStartedAt = nil
        guard Self.isAuthorized else { return }
        let uid = deviceUID, capture = capture, engine = engine
        engine.queue.async {
            if rebuild { engine.discard() } else { engine.stop() }
            engine.prepare(uid: uid, capture: capture)
        }
    }

    /// For quitting: waits until the microphone is closed.
    func closeNow() {
        stopEngine()
        engine.queue.sync { engine.discard() }
    }

    // MARK: - Devices

    func refreshMicrophones() {
        microphones = Self.inputDevices()
    }

    private static func inputDevices() -> [Microphone] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            return Microphone(uid: uid, name: name)
        }
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    nonisolated static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    nonisolated static func deviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), pointer, &size, &id)
        }
        return status == noErr && id != 0 ? id : nil
    }
}
