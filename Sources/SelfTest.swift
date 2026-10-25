// SPDX-License-Identifier: MIT
import AVFoundation
import Foundation

/// Headless check of the file-writing code path. It needs no microphone.
///
/// It generates a 1 kHz sine for 2 seconds, pushes it through `RecordingWriter` (the class the
/// recorder uses) in tap-sized buffers, for WAV and for M4A, then reads each file back and checks
/// the format, length, level and frequency. Run it with `Recorder --self-test <folder>`.
enum SelfTest {
    private static let frequency = 1000.0
    private static let amplitude: Float = 0.5
    private static let seconds = 2.0
    private static let chunk = 4096

    private static var failures = 0

    static func run(outputDirectory: String) -> Int32 {
        failures = 0
        let root = URL(fileURLWithPath: (outputDirectory as NSString).expandingTildeInPath, isDirectory: true)
        let extra = root.appendingPathComponent("extra", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        } catch {
            report(false, "create output folder: \(error.localizedDescription)")
            return 1
        }

        let now = Date()

        // Main files: stereo, 48 kHz, one per format, in the folder given on the command line.
        for format in RecordingFormat.allCases {
            let url = RecordingNaming.uniqueURL(in: root, date: now, format: format)
            check(format: format, url: url, sampleRate: 48000, sourceChannels: 2, expectedChannels: 2)
        }

        // Extra files in a sub folder: native sample rate other than 48 kHz, mono, and a
        // multichannel interface that must be reduced to two channels.
        check(format: .wav24, url: RecordingNaming.uniqueURL(in: extra, date: now, format: .wav24),
              sampleRate: 44100, sourceChannels: 1, expectedChannels: 1)
        check(format: .m4a, url: RecordingNaming.uniqueURL(in: extra, date: now, format: .m4a),
              sampleRate: 44100, sourceChannels: 1, expectedChannels: 1)
        check(format: .wav24, url: RecordingNaming.uniqueURL(in: extra, date: now.addingTimeInterval(1), format: .wav24),
              sampleRate: 96000, sourceChannels: 4, expectedChannels: 2)

        checkLevelMeasure()
        checkNaming()
        checkLibrary(in: extra)
        checkFolderStore()

        print(failures == 0 ? "SELF-TEST PASSED" : "SELF-TEST FAILED (\(failures) failure(s))")
        return failures == 0 ? 0 : 1
    }

    // MARK: Checks

    private static func check(format: RecordingFormat, url: URL, sampleRate: Double, sourceChannels: Int, expectedChannels: Int) {
        let label = "\(format.fileExtension) \(Int(sampleRate)) Hz, \(sourceChannels) in -> \(expectedChannels) out"
        do {
            let writer = try RecordingWriter(url: url, format: format, sampleRate: sampleRate, sourceChannels: sourceChannels)
            var writeError: Error?
            writer.onFailure = { writeError = $0 }
            try feedSine(into: writer, sampleRate: sampleRate, channels: sourceChannels)
            let frames = writer.finish()
            report(writeError == nil, "\(label): no write errors \(writeError.map { "(\($0))" } ?? "")")
            report(writer.channelCount == expectedChannels, "\(label): writer uses \(writer.channelCount) channel(s)")
            report(frames == Int64(sampleRate * seconds), "\(label): \(frames) frames written, expected \(Int64(sampleRate * seconds))")
            try verify(format: format, url: url, sampleRate: sampleRate, channels: expectedChannels, label: label)
        } catch {
            report(false, "\(label): \(error.localizedDescription)")
        }
    }

    private static func feedSine(into writer: RecordingWriter, sampleRate: Double, channels: Int) throws {
        // More than two channels need an explicit layout, as a real multichannel interface reports.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
        guard let format = layout.flatMap({
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: $0)
        }) else {
            throw RecordingWriterError.unsupportedBuffer
        }
        let total = Int(sampleRate * seconds)
        var position = 0
        while position < total {
            let frames = min(chunk, total - position)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
                  let data = buffer.floatChannelData else { throw RecordingWriterError.unsupportedBuffer }
            buffer.frameLength = AVAudioFrameCount(frames)
            for channel in 0 ..< channels {
                for i in 0 ..< frames {
                    let phase = 2.0 * Double.pi * frequency * Double(position + i) / sampleRate
                    data[channel][i] = amplitude * Float(sin(phase))
                }
            }
            writer.append(buffer)
            // Overwrite the buffer to prove the writer copied it and does not depend on it afterwards.
            for channel in 0 ..< channels { for i in 0 ..< frames { data[channel][i] = 0 } }
            position += frames
        }
    }

    private static func verify(format: RecordingFormat, url: URL, sampleRate: Double, channels: Int, label: String) throws {
        let file = try AVAudioFile(forReading: url)
        let settings = file.fileFormat.settings
        let fileRate = file.fileFormat.sampleRate
        let duration = Double(file.length) / file.processingFormat.sampleRate

        report(fileRate == sampleRate, "\(label): file sample rate \(fileRate) Hz")
        report(Int(file.fileFormat.channelCount) == channels, "\(label): file has \(file.fileFormat.channelCount) channel(s)")

        switch format {
        case .wav24:
            let bits = settings[AVLinearPCMBitDepthKey] as? Int ?? 0
            let isFloat = settings[AVLinearPCMIsFloatKey] as? Bool ?? true
            report(bits == 24 && !isFloat, "\(label): 24-bit integer PCM (bit depth \(bits), float \(isFloat))")
            report(file.length == Int64(sampleRate * seconds), "\(label): length \(file.length) frames")
        case .m4a:
            let id = settings[AVFormatIDKey] as? UInt32 ?? 0
            report(id == kAudioFormatMPEG4AAC, "\(label): AAC format id")
        }
        report(abs(duration - seconds) < 0.1, "\(label): duration \(String(format: "%.3f", duration)) s, expected \(seconds) s")

        // Read the samples back and check level and frequency of the tone.
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RecordingWriterError.unsupportedBuffer
        }
        try file.read(into: buffer)
        let reading = LevelMeasure.measure(buffer)
        let expectedRMS = amplitude / Float(2).squareRoot()
        let tolerance: Float = format == .wav24 ? 0.01 : 0.08
        for channel in 0 ..< reading.rms.count {
            let rms = reading.rms[channel]
            report(abs(rms - expectedRMS) / expectedRMS < tolerance,
                   "\(label): channel \(channel) RMS \(String(format: "%.4f", rms)), expected \(String(format: "%.4f", expectedRMS))")
        }
        if let data = buffer.floatChannelData {
            var crossings = 0
            let frames = Int(buffer.frameLength)
            for i in 1 ..< frames where (data[0][i - 1] < 0) != (data[0][i] < 0) { crossings += 1 }
            let measured = Double(crossings) / 2.0 / (Double(frames) / sampleRate)
            report(abs(measured - frequency) < 10, "\(label): measured tone \(String(format: "%.1f", measured)) Hz")
        }
    }

    private static func checkLevelMeasure() {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000),
              let data = buffer.floatChannelData else {
            report(false, "level measure: could not create buffer")
            return
        }
        buffer.frameLength = 48000
        for i in 0 ..< 48000 {
            data[0][i] = 0.5 * Float(sin(2.0 * Double.pi * 1000.0 * Double(i) / 48000.0))
            data[1][i] = 0.25 * Float(sin(2.0 * Double.pi * 1000.0 * Double(i) / 48000.0))
        }
        let reading = LevelMeasure.measure(buffer)
        let peak = LevelMeasure.decibels(reading.peak[0])
        let rms = LevelMeasure.decibels(reading.rms[0])
        let peak2 = LevelMeasure.decibels(reading.peak[1])
        report(abs(peak - (-6.02)) < 0.1, "level measure: peak \(String(format: "%.2f", peak)) dBFS, expected -6.02")
        report(abs(rms - (-9.03)) < 0.1, "level measure: RMS \(String(format: "%.2f", rms)) dBFS, expected -9.03")
        report(abs(peak2 - (-12.04)) < 0.1, "level measure: second channel peak \(String(format: "%.2f", peak2)) dBFS, expected -12.04")
    }

    private static func checkNaming() {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.year = 2026; components.month = 3; components.day = 9
        components.hour = 7; components.minute = 5; components.second = 4
        guard let date = components.date else { report(false, "naming: bad date"); return }
        let name = RecordingNaming.baseName(for: date)
        report(name == "Recording 2026-03-09 07.05.04", "naming: \(name)")
    }

    /// The recordings list and the rename rules, on a scratch folder (nothing is trashed).
    private static func checkLibrary(in extra: URL) {
        let folder = extra.deletingLastPathComponent().appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
            report(false, "library: \(error.localizedDescription)"); return
        }
        let suite = "local.recorder.selftest"
        guard let defaults = UserDefaults(suiteName: suite) else { report(false, "library: no defaults suite"); return }
        defaults.removePersistentDomain(forName: suite)
        let store = RecordingFolderStore(defaults: defaults)
        store.choose(folder)

        // One WAV and one M4A from the writer, a copy of the WAV, and a file that must be ignored.
        do {
            for (format, name) in [(RecordingFormat.wav24, "First"), (RecordingFormat.m4a, "Second")] {
                let url = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
                let writer = try RecordingWriter(url: url, format: format, sampleRate: 48000, sourceChannels: 1)
                try feedSine(into: writer, sampleRate: 48000, channels: 1)
                writer.finish()
            }
            try FileManager.default.copyItem(at: folder.appendingPathComponent("First.wav"),
                                             to: folder.appendingPathComponent("Taken.wav"))
            try Data("ignore me".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        } catch {
            report(false, "library: \(error.localizedDescription)"); return
        }

        let library = LibraryModel(folder: store)
        spin(until: { library.items.count == 3 })
        report(library.items.count == 3, "library: lists 3 audio files and ignores other files (found \(library.items.count))")
        report(library.items.allSatisfy { abs(($0.duration ?? 0) - seconds) < 0.1 }, "library: durations are about 2 s")
        report(library.items.allSatisfy { $0.size > 0 }, "library: sizes are known")

        guard let first = library.items.first(where: { $0.name == "First" }) else {
            report(false, "library: First.wav not listed"); return
        }
        report(library.validateName("", for: first) != nil, "library: empty name rejected")
        report(library.validateName("a/b", for: first) != nil, "library: name with slash rejected")
        report(library.validateName("Taken", for: first) != nil, "library: name of an existing file rejected")
        report(library.validateName("Renamed take", for: first) == nil, "library: normal name accepted")

        library.rename(first, to: "Renamed take")
        spin(until: { library.items.contains { $0.name == "Renamed take" } })
        report(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Renamed take.wav").path)
               && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("First.wav").path),
               "library: rename moved the file and kept the extension")
        report(library.items.contains { $0.name == "Renamed take" }, "library: list refreshed after rename")
        defaults.removePersistentDomain(forName: suite)
    }

    private static func checkFolderStore() {
        let suite = "local.recorder.selftest"
        guard let defaults = UserDefaults(suiteName: suite) else { report(false, "folder: no defaults suite"); return }
        defaults.removePersistentDomain(forName: suite)

        let fresh = RecordingFolderStore(defaults: defaults)
        report(fresh.isDefault && fresh.notice == nil && fresh.displayPath == "~/Music/Recordings",
               "folder: default is ~/Music/Recordings (shown as \(fresh.displayPath))")

        defaults.set("/nonexistent/folder/for/self-test", forKey: RecordingFolderStore.defaultsKey)
        let missing = RecordingFolderStore(defaults: defaults)
        report(missing.isDefault && missing.notice != nil, "folder: a missing stored folder falls back to the default with a notice")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-folder-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defaults.set(temporary.path, forKey: RecordingFolderStore.defaultsKey)
        let stored = RecordingFolderStore(defaults: defaults)
        report(stored.url.standardizedFileURL.path == temporary.standardizedFileURL.path && stored.notice == nil,
               "folder: a stored folder is used")
        stored.choose(temporary.appendingPathComponent("sub"))
        report(defaults.string(forKey: RecordingFolderStore.defaultsKey)?.hasSuffix("/sub") == true,
               "folder: choosing a folder stores its path")
        try? FileManager.default.removeItem(at: temporary)
        defaults.removePersistentDomain(forName: suite)
    }

    /// Runs the main run loop until the condition holds or two seconds have passed.
    private static func spin(until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: Output

    private static func report(_ ok: Bool, _ message: String) {
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(message)")
    }
}
