// The microphone, through AVAudioEngine: converted to 16 kHz mono floats, what Parakeet takes.
// Warm (the default, as in the Tauri build), the engine runs between dictations and keeps the
// last 300 ms, so the first syllable said with the key is not lost; cold, it opens on the key.
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
    var level: Double = 0
    var isZero = false
    /// When the last buffer arrived: a running engine that stops delivering has stalled.
    var lastBuffer = Date.distantPast

    func append(_ chunk: [Float]) {
        var peak: Float = 0, sum: Float = 0
        for s in chunk { peak = max(peak, abs(s)); sum += s * s }
        let rms = chunk.isEmpty ? 0 : (sum / Float(chunk.count)).squareRoot()
        lock.lock()
        defer { lock.unlock() }
        level = min(1, Double(rms) * 12)
        isZero = peak == 0
        lastBuffer = Date()
        if isRecording {
            samples.append(contentsOf: chunk)
        } else {
            preRoll.append(contentsOf: chunk)
            if preRoll.count > Self.preRollCount { preRoll.removeFirst(preRoll.count - Self.preRollCount) }
        }
    }

    /// Returns how many pre-roll samples went in.
    func begin(withPreRoll: Bool) -> Int {
        lock.lock(); defer { lock.unlock() }
        samples = withPreRoll ? preRoll : []
        preRoll = []
        isRecording = true
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

@MainActor
final class Recorder: ObservableObject {
    @Published private(set) var level: Double = 0
    /// Exact digital silence for a while: a muted or disconnected device.
    @Published private(set) var isSignalDead = false
    @Published private(set) var microphones: [Microphone] = []
    @Published private(set) var isRunning = false

    private var engine = AVAudioEngine()
    private let capture = Capture()
    private var deviceUID: String?
    private var isWarm = true
    private var isRecording = false
    private var meter: Timer?
    private var zeroSince: Date?
    private var configObserver: NSObjectProtocol?
    private var engineStartedAt: Date?

    nonisolated static var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    nonisolated static var isDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        return status == .denied || status == .restricted
    }

    init() {
        refreshMicrophones()
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Applies the chosen device and warmth; opens the engine now if warm.
    func configure(deviceUID: String?, warm: Bool) {
        let changed = deviceUID != self.deviceUID
        self.deviceUID = deviceUID
        isWarm = warm
        if changed { stopEngine() }
        if warm { startEngine() } else if !isRecording { stopEngine() }
    }

    /// What the microphone was doing when the last dictation began, for the diagnostic dump.
    private(set) var lastBegin = ""

    func begin() {
        isRecording = true
        let wasRunning = isRunning
        let quietMs = Int(Date().timeIntervalSince(capture.reading().lastBuffer) * 1000)
        let started = Date()
        if !isRunning { startEngine() }
        // A warm engine has a pre-roll only if it ran long enough to fill it.
        let hasPreRoll = engineStartedAt.map { Date().timeIntervalSince($0) > 0.3 } ?? false
        let preRoll = capture.begin(withPreRoll: hasPreRoll)
        lastBegin = "device=\(currentDeviceName) engineWasRunning=\(wasRunning) msSinceLastBuffer=\(quietMs) startMs=\(Int(Date().timeIntervalSince(started) * 1000)) preRollSamples=\(preRoll)"
    }

    func end() -> [Float] {
        isRecording = false
        let samples = capture.end()
        if !isWarm { stopEngine() }
        return samples
    }

    func cancel() { _ = end() }

    private func tick() {
        let reading = capture.reading()
        // A warm engine that went quiet (sleep, a device that came or went, the system taking the
        // input) is reopened now, not when the shortcut needs it: a USB microphone takes about a
        // second to deliver after it opens, and that second was the start of the dictation.
        if isRunning, !isRecording, let started = engineStartedAt, Date().timeIntervalSince(started) > 1,
           Date().timeIntervalSince(reading.lastBuffer) > 0.5 {
            NSLog("[recorder] stalled, reopening")
            stopEngine()
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
        guard Self.isAuthorized, !isRunning else { return }
        engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = deviceUID, let id = Self.deviceID(uid: uid), let unit = input.audioUnit {
            var device = id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &device, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { return }
        let capture = self.capture
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            let ratio = 16000 / format.sampleRate
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
        do {
            try engine.start()
            isRunning = true
            engineStartedAt = Date()
            NSLog("[recorder] microphone open (%.0f Hz, warm: %@)", format.sampleRate, isWarm ? "yes" : "no")
        } catch {
            input.removeTap(onBus: 0)
            NSLog("[recorder] engine failed: \(error)")
        }
        // A device that comes or goes rebuilds the engine on the new configuration. Choosing a
        // device posts this notice too, right after the engine opens; rebuilding then posted it
        // again, and a chosen microphone never delivered a sample. So: not in the first two
        // seconds, and only if the engine really stopped (the stall watchdog covers the rest).
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.engineStartedAt, Date().timeIntervalSince(started) > 2,
                      !self.engine.isRunning else { return }
                self.stopEngine()
                self.refreshMicrophones()
                if self.isWarm || self.isRecording { self.startEngine() }
            }
        }
    }

    func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        engineStartedAt = nil
    }

    // MARK: - Devices

    /// The device the engine's input unit really has, by name: what a choice did, not what was asked.
    private var currentDeviceName: String {
        guard isRunning, let unit = engine.inputNode.audioUnit else { return "none" }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size) == noErr else { return "?" }
        return Self.string(id, kAudioObjectPropertyName) ?? "#\(id)"
    }

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

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func deviceID(uid: String) -> AudioDeviceID? {
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
