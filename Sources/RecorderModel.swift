// SPDX-License-Identifier: MIT
import AppKit
import AVFoundation
import Foundation

/// State and actions of the recorder part of the window.
final class RecorderModel: ObservableObject {
    static let shared = RecorderModel()

    enum State { case idle, recording, paused }

    struct Notice: Identifiable {
        enum Kind { case info, error }
        let id = UUID()
        let kind: Kind
        let text: String
    }

    // UserDefaults keys (domain `io.github.saschakubisch.recorder`).
    static let inputKey = "inputDeviceUID"
    static let formatKey = "recordingFormat"
    private static let privacySettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var devices: [InputDevice] = []
    @Published private(set) var defaultDeviceName: String?
    @Published private(set) var authorization: AVAuthorizationStatus
    @Published private(set) var activeDeviceName = ""
    /// Sample rate and channels of the audio that actually arrives, known after the first buffer.
    @Published private(set) var activeFormatText = ""
    @Published var notice: Notice?

    /// UID of the chosen input device. Empty means the system default input.
    @Published var selectedInputUID: String {
        didSet { UserDefaults.standard.set(selectedInputUID, forKey: Self.inputKey) }
    }

    @Published var format: RecordingFormat {
        didSet { UserDefaults.standard.set(format.rawValue, forKey: Self.formatKey) }
    }

    let meter = LevelMeterModel()
    let folder: RecordingFolderStore

    /// Called just before a recording starts (the library stops playback here).
    var onWillStart: (() -> Void)?
    /// Called when recording has started, with the file that is being written.
    var onStarted: ((URL) -> Void)?
    /// Called after the file is closed. The URL is nil when nothing was recorded.
    var onFinished: ((URL?) -> Void)?

    private let capture = AudioCapture()
    private var timer: Timer?
    private var lastTick = Date()
    private var requestingAccess = false
    private var activity: NSObjectProtocol?
    private var deviceListWatch: AudioDevices.Watch?
    private var defaultInputWatch: AudioDevices.Watch?

    init(folder: RecordingFolderStore = .shared) {
        self.folder = folder
        let defaults = UserDefaults.standard
        selectedInputUID = defaults.string(forKey: Self.inputKey) ?? ""
        format = RecordingFormat(rawValue: defaults.string(forKey: Self.formatKey) ?? "") ?? .wav24
        authorization = AVCaptureDevice.authorizationStatus(for: .audio)

        refreshDevices()
        deviceListWatch = AudioDevices.watchDeviceList { [weak self] in self?.refreshDevices() }
        defaultInputWatch = AudioDevices.watchDefaultInput { [weak self] in self?.refreshDevices() }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshAuthorization()
            self?.refreshDevices()
        }

        capture.onLevels = { [weak self] reading in self?.meter.feed(reading) }
        capture.onFormat = { [weak self] format, channels in self?.describe(format: format, channels: channels) }
        capture.onInterrupted = { [weak self] reason in self?.stopRecording(reason: reason) }
    }

    // MARK: Derived state

    var isActive: Bool { state != .idle }

    var permissionProblem: Bool { authorization == .denied || authorization == .restricted }

    /// The saved input device is not connected right now.
    var selectedInputMissing: Bool {
        !selectedInputUID.isEmpty && !devices.contains { $0.uid == selectedInputUID }
    }

    var statusLine: String {
        switch state {
        case .idle:
            if permissionProblem { return "Microphone access is off" }
            if devices.isEmpty { return "No input device found" }
            return "Ready"
        case .recording:
            return activeFormatText.isEmpty ? "Starting" : "Recording from \(activeDeviceName), \(activeFormatText)"
        case .paused:
            return "Paused. \(activeDeviceName), \(activeFormatText)"
        }
    }

    // MARK: Actions

    func toggleRecording() {
        if state == .idle { startRecording() } else { stopRecording() }
    }

    func togglePause() {
        switch state {
        case .recording:
            capture.isPaused = true
            state = .paused
        case .paused:
            capture.isPaused = false
            state = .recording
        case .idle:
            break
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: Self.privacySettingsURL) { NSWorkspace.shared.open(url) }
    }

    func chooseFolder() {
        guard !isActive else { return }
        folder.presentChooser()
    }

    func shutdown() {
        if isActive { stopRecording() }
    }

    // MARK: Permission and devices

    func refreshAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status != authorization { authorization = status }
    }

    func refreshDevices() {
        let list = AudioDevices.inputDevices()
        devices = list
        if let id = AudioDevices.defaultInputDeviceID() {
            defaultDeviceName = list.first(where: { $0.id == id })?.name
        } else {
            defaultDeviceName = nil
        }
    }

    // MARK: Recording

    private func startRecording() {
        guard !requestingAccess else { return }
        refreshAuthorization()
        switch authorization {
        case .authorized:
            beginCapture()
        case .notDetermined:
            requestingAccess = true
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.requestingAccess = false
                    self.refreshAuthorization()
                    if granted { self.beginCapture() }
                }
            }
        default:
            notice = nil // the permission banner explains what to do
        }
    }

    private func resolveDevice() -> InputDevice? {
        refreshDevices()
        if !selectedInputUID.isEmpty, let chosen = devices.first(where: { $0.uid == selectedInputUID }) {
            return chosen
        }
        if let id = AudioDevices.defaultInputDeviceID(), let fallback = devices.first(where: { $0.id == id }) {
            return fallback
        }
        return devices.first
    }

    private func beginCapture() {
        guard state == .idle else { return }
        notice = nil

        guard let device = resolveDevice() else {
            notice = Notice(kind: .error, text: "No audio input device is available.")
            return
        }
        if selectedInputMissing {
            notice = Notice(kind: .info, text: "The saved input device is not connected. Recording from \(device.name) instead.")
        }

        do {
            try folder.ensureExists()
        } catch {
            notice = Notice(kind: .error, text: "The folder \(folder.displayPath) could not be created: \(error.localizedDescription)")
            return
        }
        let url = RecordingNaming.uniqueURL(in: folder.url, date: Date(), format: format)

        onWillStart?()
        meter.reset()
        activeFormatText = ""
        do {
            try capture.start(device: device, url: url, format: format)
        } catch {
            notice = Notice(kind: .error, text: error.localizedDescription)
            return
        }

        activeDeviceName = device.name
        state = .recording
        elapsedSeconds = 0
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Recording audio"
        )
        startTimer()
        onStarted?(url)
    }

    func stopRecording(reason: CaptureStopReason = .user) {
        guard state != .idle else { return }
        timer?.invalidate()
        timer = nil
        let result = capture.stop()
        state = .idle
        elapsedSeconds = 0
        meter.reset()
        activeDeviceName = ""
        activeFormatText = ""
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil

        let saved = result.url.map { "The recording up to that point was saved as \($0.lastPathComponent)." }
            ?? "Nothing had been recorded yet."
        switch reason {
        case .user:
            notice = nil
        case .deviceDisconnected:
            notice = Notice(kind: .error, text: "The input device was disconnected. \(saved)")
        case .configurationChanged:
            notice = Notice(kind: .error, text: "The audio setup changed, for example the input device or its sample rate. \(saved)")
        case .inputStalled:
            notice = Notice(kind: .error, text: "No audio arrived from the input device for 4 seconds. \(saved)")
        case let .writeFailed(message):
            notice = Notice(kind: .error, text: "Writing the file failed: \(message) \(saved)")
        }
        onFinished?(result.url)
    }

    private func describe(format: AVAudioFormat, channels: Int) {
        guard isActive else { return }
        let rate = format.sampleRate
        let rateText = rate.truncatingRemainder(dividingBy: 1000) == 0
            ? "\(Int(rate / 1000)) kHz" : String(format: "%.1f kHz", rate / 1000)
        let channelText = channels == 1 ? "mono" : "stereo"
        let sourceNote = Int(format.channelCount) > 2 ? " (first 2 of \(format.channelCount) inputs)" : ""
        activeFormatText = "\(rateText), \(channelText)\(sourceNote), \(self.format.shortTitle)"
    }

    // MARK: Timer

    private func startTimer() {
        lastTick = Date()
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        let dt = Float(now.timeIntervalSince(lastTick))
        lastTick = now
        meter.tick(dt: dt)
        let whole = Int(capture.elapsed)
        if whole != elapsedSeconds { elapsedSeconds = whole }
    }
}
