import AVFoundation
import Foundation

/// The two file formats the recorder can write.
enum RecordingFormat: String, CaseIterable, Identifiable {
    case wav24
    case m4a

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .wav24: return "wav"
        case .m4a: return "m4a"
        }
    }

    /// Name shown in the format picker.
    var title: String {
        switch self {
        case .wav24: return "WAV, 24-bit lossless"
        case .m4a: return "M4A, AAC 256 kbps"
        }
    }

    /// Short form used in the status line.
    var shortTitle: String {
        switch self {
        case .wav24: return "WAV 24-bit"
        case .m4a: return "M4A AAC 256 kbps"
        }
    }

    /// Settings for AVAudioFile. The sample rate is always the source rate, so nothing is resampled.
    func fileSettings(sampleRate: Double, channels: Int) -> [String: Any] {
        switch self {
        case .wav24:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 24,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        case .m4a:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: 256_000,
                AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
                AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
            ]
        }
    }
}

/// File names for new recordings.
enum RecordingNaming {
    static func baseName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Recording " + formatter.string(from: date)
    }

    /// `Recording YYYY-MM-DD HH.mm.ss.wav`, with a counter added when that name is taken.
    static func uniqueURL(in directory: URL, date: Date, format: RecordingFormat) -> URL {
        let base = baseName(for: date)
        var url = directory.appendingPathComponent(base).appendingPathExtension(format.fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(counter)").appendingPathExtension(format.fileExtension)
            counter += 1
        }
        return url
    }
}

enum RecordingWriterError: LocalizedError {
    case unsupportedBuffer
    case sampleRateChanged(expected: Double, got: Double)

    var errorDescription: String? {
        switch self {
        case .unsupportedBuffer:
            return "The audio buffer had an unsupported format."
        case let .sampleRateChanged(expected, got):
            return "The input sample rate changed from \(Int(expected)) Hz to \(Int(got)) Hz."
        }
    }
}

/// Writes audio buffers to one file on its own serial queue.
///
/// `append` is cheap: it copies the samples (keeping at most two channels) and hands the copy to the
/// queue. The caller can reuse its buffer at once and is never blocked by disk or encoder work.
/// The recorder and the self-test both use this class, so they share one code path.
final class RecordingWriter {
    let url: URL
    let format: RecordingFormat
    let sampleRate: Double
    let channelCount: Int

    /// Called once, on an arbitrary thread, when a write fails (disk full, encoder error).
    var onFailure: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "local.recorder.writer", qos: .userInitiated)
    private let processingFormat: AVAudioFormat
    private var file: AVAudioFile? // only touched on `queue`
    private var failed = false // only touched on `queue`

    private let lock = NSLock()
    private var framesWrittenValue: Int64 = 0

    init(url: URL, format: RecordingFormat, sampleRate: Double, sourceChannels: Int) throws {
        self.url = url
        self.format = format
        self.sampleRate = sampleRate
        self.channelCount = max(1, min(2, sourceChannels))
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.fileSettings(sampleRate: sampleRate, channels: channelCount)
        )
        self.file = file
        self.processingFormat = file.processingFormat
    }

    /// Frames written to the file so far.
    var framesWritten: Int64 {
        lock.lock(); defer { lock.unlock() }
        return framesWrittenValue
    }

    var elapsed: TimeInterval { Double(framesWritten) / sampleRate }

    /// Copies the buffer and queues it for writing. Safe to call from the audio tap thread.
    func append(_ source: AVAudioPCMBuffer) {
        guard source.frameLength > 0, let sourceData = source.floatChannelData else { return }
        guard source.format.sampleRate == sampleRate else {
            fail(RecordingWriterError.sampleRateChanged(expected: sampleRate, got: source.format.sampleRate))
            return
        }
        let sourceChannels = Int(source.format.channelCount)
        guard sourceChannels > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: source.frameLength),
              let target = copy.floatChannelData else {
            fail(RecordingWriterError.unsupportedBuffer)
            return
        }
        let frames = Int(source.frameLength)
        copy.frameLength = source.frameLength
        let stride = source.stride
        for channel in 0 ..< channelCount {
            let from = sourceData[min(channel, sourceChannels - 1)]
            if stride == 1 {
                memcpy(target[channel], from, frames * MemoryLayout<Float>.size)
            } else {
                for i in 0 ..< frames { target[channel][i] = from[i * stride] }
            }
        }
        queue.async { [self] in write(copy) }
    }

    /// Writes everything still queued, closes the file and returns the number of frames written.
    /// After this the file is complete and valid. Calling it again does nothing.
    @discardableResult
    func finish() -> Int64 {
        queue.sync { file = nil } // AVAudioFile finalizes the header when it is released
        return framesWritten
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let file = file, !failed else { return }
        do {
            try file.write(from: buffer)
            lock.lock(); framesWrittenValue += Int64(buffer.frameLength); lock.unlock()
        } catch {
            failed = true
            self.file = nil
            onFailure?(error)
        }
    }

    private func fail(_ error: Error) {
        queue.async { [self] in
            guard !failed else { return }
            failed = true
            file = nil
            onFailure?(error)
        }
    }
}

/// Peak and RMS of a buffer, per channel, as linear values (1.0 is full scale).
struct LevelReading {
    var peak: [Float]
    var rms: [Float]
}

enum LevelMeasure {
    static func measure(_ buffer: AVAudioPCMBuffer, maxChannels: Int = 2) -> LevelReading {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else {
            return LevelReading(peak: [0], rms: [0])
        }
        let channels = max(1, min(maxChannels, Int(buffer.format.channelCount)))
        let frames = Int(buffer.frameLength)
        let stride = buffer.stride
        var peaks = [Float](repeating: 0, count: channels)
        var rmss = [Float](repeating: 0, count: channels)
        for channel in 0 ..< channels {
            let samples = data[channel]
            var peak: Float = 0
            var sum: Float = 0
            var i = 0
            for _ in 0 ..< frames {
                let value = samples[i]
                let magnitude = abs(value)
                if magnitude > peak { peak = magnitude }
                sum += value * value
                i += stride
            }
            peaks[channel] = peak
            rmss[channel] = (sum / Float(frames)).squareRoot()
        }
        return LevelReading(peak: peaks, rms: rmss)
    }

    /// Converts a linear value to dBFS. Silence returns -120.
    static func decibels(_ linear: Float) -> Float {
        guard linear > 1e-6 else { return -120 }
        return 20 * log10(linear)
    }
}
