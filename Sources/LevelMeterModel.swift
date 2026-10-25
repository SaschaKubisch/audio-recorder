// SPDX-License-Identifier: MIT
import Foundation

/// Display values for the level meter, in dBFS.
///
/// Levels rise at once and fall at a fixed rate, so the meter is easy to read. `feed` takes the
/// raw per-buffer measurements; `tick` runs on a timer and applies the decay. Peak values also
/// get a short hold marker.
final class LevelMeterModel: ObservableObject {
    static let floorDB: Float = -60
    private static let silence: Float = -120
    private static let peakFallPerSecond: Float = 24
    private static let rmsFallPerSecond: Float = 14
    private static let holdSeconds: Float = 1.5
    private static let clipThreshold: Float = 0.999

    @Published private(set) var peakDB: [Float] = [silence, silence]
    @Published private(set) var rmsDB: [Float] = [silence, silence]
    @Published private(set) var holdDB: [Float] = [silence, silence]
    /// True once any sample reached full scale. Stays on until `clearClip()` or `reset()`.
    @Published private(set) var clipped = false

    private var pendingPeak: [Float] = [silence, silence]
    private var pendingRMS: [Float] = [silence, silence]
    private var holdAge: [Float] = [0, 0]

    /// Highest held peak across channels, for the numeric readout.
    var readoutPeakDB: Float { holdDB.max() ?? Self.silence }
    /// Highest RMS across channels, for the numeric readout.
    var readoutRMSDB: Float { rmsDB.max() ?? Self.silence }

    func feed(_ reading: LevelReading) {
        resize(reading.peak.count)
        for channel in 0 ..< reading.peak.count {
            pendingPeak[channel] = max(pendingPeak[channel], LevelMeasure.decibels(reading.peak[channel]))
            pendingRMS[channel] = LevelMeasure.decibels(reading.rms[channel])
            if reading.peak[channel] >= Self.clipThreshold, !clipped { clipped = true }
        }
    }

    /// Applies the decay. Call about 30 times per second while recording.
    func tick(dt: Float) {
        var peaks = peakDB
        var rmss = rmsDB
        var holds = holdDB
        for channel in 0 ..< peaks.count {
            peaks[channel] = max(pendingPeak[channel], peaks[channel] - Self.peakFallPerSecond * dt)
            rmss[channel] = max(pendingRMS[channel], rmss[channel] - Self.rmsFallPerSecond * dt)
            if pendingPeak[channel] >= holds[channel] {
                holds[channel] = pendingPeak[channel]
                holdAge[channel] = 0
            } else {
                holdAge[channel] += dt
                if holdAge[channel] > Self.holdSeconds {
                    holds[channel] = max(peaks[channel], holds[channel] - Self.peakFallPerSecond * dt)
                }
            }
            pendingPeak[channel] = Self.silence
        }
        peakDB = peaks
        rmsDB = rmss
        holdDB = holds
    }

    func clearClip() { clipped = false }

    func reset() {
        let count = peakDB.count
        peakDB = [Float](repeating: Self.silence, count: count)
        rmsDB = peakDB
        holdDB = peakDB
        pendingPeak = peakDB
        pendingRMS = peakDB
        holdAge = [Float](repeating: 0, count: count)
        clipped = false
    }

    private func resize(_ count: Int) {
        guard count != peakDB.count, count > 0 else { return }
        peakDB = [Float](repeating: Self.silence, count: count)
        rmsDB = peakDB
        holdDB = peakDB
        pendingPeak = peakDB
        pendingRMS = peakDB
        holdAge = [Float](repeating: 0, count: count)
    }
}

enum TimeFormat {
    /// `mm:ss`, or `h:mm:ss` from one hour on.
    static func clock(_ totalSeconds: Int) -> String {
        let seconds = max(0, totalSeconds)
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func clock(duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite else { return "--:--" }
        return clock(Int(duration.rounded()))
    }
}
