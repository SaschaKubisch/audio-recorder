import AVFoundation
import CoreAudio
import Foundation

enum CaptureError: LocalizedError {
    case noInputFormat
    case cannotSelectDevice(OSStatus)
    case engine(Error)

    var errorDescription: String? {
        switch self {
        case .noInputFormat:
            return "The input device did not report a usable audio format. Check that it is connected and that microphone access is allowed."
        case let .cannotSelectDevice(status):
            return "The input device could not be selected (CoreAudio error \(status))."
        case let .engine(error):
            return "The audio engine could not start: \(error.localizedDescription)"
        }
    }
}

enum CaptureStopReason {
    case user
    case deviceDisconnected
    case configurationChanged
    case writeFailed(String)
}

/// Records from one input device with AVAudioEngine and hands every buffer to a `RecordingWriter`.
///
/// The tap callback copies each buffer into the writer and returns at once; all disk and encoder
/// work happens on the writer's serial queue. The file is created from the first buffer, so its
/// sample rate and channel count are always those of the data that really arrives, and nothing
/// is resampled.
final class AudioCapture {
    /// Linear peak and RMS per channel for each buffer. Called on the main queue.
    var onLevels: ((LevelReading) -> Void)?
    /// The real format of the incoming audio, reported once with the first buffer. Main queue.
    var onFormat: ((AVAudioFormat, Int) -> Void)?
    /// The capture cannot continue: device unplugged, configuration changed or a write failed.
    /// Main queue. The owner must call `stop()` to finalize the file.
    var onInterrupted: ((CaptureStopReason) -> Void)?

    private var engine: AVAudioEngine?
    private var deviceID: AudioDeviceID = 0
    private var fileURL: URL?
    private var fileFormat: RecordingFormat = .wav24

    // Shared between the tap thread and the main thread.
    private let lock = NSLock()
    private var writer: RecordingWriter?
    private var paused = false
    private var stopped = true
    private var reportedFormat = false
    private var interrupted = false
    private var writerCreationFailed = false

    private var aliveWatch: AudioDevices.Watch?
    private var listWatch: AudioDevices.Watch?
    private var configObserver: NSObjectProtocol?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !stopped
    }

    var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return paused }
        set { lock.lock(); paused = newValue; lock.unlock() }
    }

    /// Seconds of audio written to the file so far.
    var elapsed: TimeInterval {
        lock.lock(); let current = writer; lock.unlock()
        return current?.elapsed ?? 0
    }

    // MARK: Start and stop

    func start(device: InputDevice, url: URL, format: RecordingFormat) throws {
        precondition(!isRunning, "already recording")

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Record from exactly the chosen device, not whatever the system default is later.
        if let unit = input.audioUnit {
            var id = device.id
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw CaptureError.cannotSelectDevice(status) }
        }

        // Without microphone permission or with a broken device the hardware format is empty,
        // and installing a tap on it would raise an Objective-C exception.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw CaptureError.noInputFormat }

        lock.lock()
        writer = nil
        paused = false
        stopped = false
        reportedFormat = false
        interrupted = false
        writerCreationFailed = false
        lock.unlock()

        fileURL = url
        fileFormat = format
        deviceID = device.id

        // Format nil: the tap takes the input node's own format, which is the device format.
        input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            lock.lock(); stopped = true; lock.unlock()
            throw CaptureError.engine(error)
        }
        self.engine = engine

        // Device loss: the device stops being alive, the device list changes, or the engine
        // reports a configuration change and is no longer running.
        aliveWatch = AudioDevices.watchAlive(device.id) { [weak self] in
            if !AudioDevices.isAlive(device.id) { self?.interrupt(.deviceDisconnected) }
        }
        listWatch = AudioDevices.watchDeviceList { [weak self] in
            guard let self else { return }
            if !AudioDevices.inputDevices().contains(where: { $0.id == device.id }) {
                self.interrupt(.deviceDisconnected)
            }
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, let engine = self.engine, !engine.isRunning else { return }
            if AudioDevices.isAlive(device.id) && AudioDevices.inputDevices().contains(where: { $0.id == device.id }) {
                self.interrupt(.configurationChanged)
            } else {
                self.interrupt(.deviceDisconnected)
            }
        }
    }

    /// Stops the engine, writes out everything still queued and closes the file. Returns the file
    /// URL and the length written, or nil for the URL when nothing was recorded. Safe to call twice.
    @discardableResult
    func stop() -> (url: URL?, seconds: TimeInterval) {
        lock.lock()
        stopped = true
        lock.unlock()

        aliveWatch?.cancel(); aliveWatch = nil
        listWatch?.cancel(); listWatch = nil
        if let observer = configObserver { NotificationCenter.default.removeObserver(observer) }
        configObserver = nil

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil

        lock.lock()
        let finished = writer
        writer = nil
        lock.unlock()

        guard let finished else { return (nil, 0) }
        let frames = finished.finish()
        let seconds = Double(frames) / finished.sampleRate
        if frames == 0 {
            try? FileManager.default.removeItem(at: finished.url)
            return (nil, 0)
        }
        return (finished.url, seconds)
    }

    // MARK: Tap thread

    private func handle(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }

        lock.lock()
        if stopped || writerCreationFailed { lock.unlock(); return }
        var current = writer
        let isPaused = paused
        let needsFormatReport = !reportedFormat
        lock.unlock()

        if current == nil, let url = fileURL {
            do {
                let created = try RecordingWriter(
                    url: url,
                    format: fileFormat,
                    sampleRate: buffer.format.sampleRate,
                    sourceChannels: Int(buffer.format.channelCount)
                )
                created.onFailure = { [weak self] error in
                    DispatchQueue.main.async { self?.interrupt(.writeFailed(error.localizedDescription)) }
                }
                lock.lock()
                writer = created
                lock.unlock()
                current = created
            } catch {
                lock.lock(); writerCreationFailed = true; lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    self?.interrupt(.writeFailed(error.localizedDescription))
                }
                return
            }
        }

        if needsFormatReport, let current {
            lock.lock(); reportedFormat = true; lock.unlock()
            let format = buffer.format
            let channels = current.channelCount
            DispatchQueue.main.async { [weak self] in self?.onFormat?(format, channels) }
        }

        let reading = LevelMeasure.measure(buffer)
        DispatchQueue.main.async { [weak self] in self?.onLevels?(reading) }

        if !isPaused { current?.append(buffer) }
    }

    // MARK: Interruptions

    private func interrupt(_ reason: CaptureStopReason) {
        lock.lock()
        let first = !interrupted && !stopped
        if first { interrupted = true }
        lock.unlock()
        guard first else { return }
        onInterrupted?(reason)
    }
}
