// SPDX-License-Identifier: MIT
import SwiftUI

/// Level meter: one bar per channel (up to two) with a scale in dBFS, and a numeric readout.
/// The solid bar is RMS, the lighter bar behind it is the peak, the thin line is the peak hold.
struct LevelMeterView: View {
    @ObservedObject var model: LevelMeterModel

    private static let floorDB = LevelMeterModel.floorDB
    private static let ticks: [Float] = [-60, -48, -36, -24, -12, -6, 0]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0 ..< model.peakDB.count, id: \.self) { channel in
                MeterBar(peak: model.peakDB[channel], rms: model.rmsDB[channel], hold: model.holdDB[channel])
                    .frame(height: 12)
            }
            Scale()
                .frame(height: 14)
            HStack(spacing: 16) {
                readout("Peak", value: model.readoutPeakDB)
                readout("RMS", value: model.readoutRMSDB)
                Spacer(minLength: 0)
                if model.clipped {
                    Button { model.clearClip() } label: {
                        Text("CLIP")
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .foregroundColor(.white)
                            .background(Capsule().fill(Color.red))
                    }
                    .buttonStyle(.plain)
                    .help("A sample reached full scale. Click to clear.")
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Input level")
        .accessibilityValue("Peak \(format(model.readoutPeakDB)) dBFS, RMS \(format(model.readoutRMSDB)) dBFS")
    }

    private func readout(_ label: String, value: Float) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(format(value)).monospacedDigit()
            Text("dBFS").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func format(_ db: Float) -> String {
        db <= -99 ? "--" : String(format: "%.1f", db)
    }

    private static func position(_ db: Float, width: CGFloat) -> CGFloat {
        let clamped = min(0, max(floorDB, db))
        return CGFloat((clamped - floorDB) / -floorDB) * width
    }

    private struct MeterBar: View {
        let peak: Float
        let rms: Float
        let hold: Float

        var body: some View {
            Canvas { context, size in
                let track = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3)
                context.fill(track, with: .color(Color.primary.opacity(0.09)))

                let gradient = Gradient(stops: [
                    .init(color: Color(red: 0.20, green: 0.78, blue: 0.35), location: 0.0),
                    .init(color: Color(red: 0.20, green: 0.78, blue: 0.35), location: 0.70),
                    .init(color: Color(red: 1.00, green: 0.80, blue: 0.00), location: 0.88),
                    .init(color: Color(red: 1.00, green: 0.23, blue: 0.19), location: 1.0),
                ])
                let shading = GraphicsContext.Shading.linearGradient(
                    gradient, startPoint: .zero, endPoint: CGPoint(x: size.width, y: 0)
                )

                context.clip(to: track)

                let peakWidth = LevelMeterView.position(peak, width: size.width)
                var lighter = context
                lighter.opacity = 0.35
                lighter.fill(Path(CGRect(x: 0, y: 0, width: peakWidth, height: size.height)), with: shading)

                let rmsWidth = LevelMeterView.position(rms, width: size.width)
                context.fill(Path(CGRect(x: 0, y: 0, width: rmsWidth, height: size.height)), with: shading)

                if hold > LevelMeterModel.floorDB {
                    let x = LevelMeterView.position(hold, width: size.width)
                    let color: Color = hold >= -1 ? .red : Color.primary.opacity(0.85)
                    context.fill(Path(CGRect(x: max(0, x - 2), y: 0, width: 2, height: size.height)), with: .color(color))
                }
            }
        }
    }

    private struct Scale: View {
        var body: some View {
            Canvas { context, size in
                for tick in LevelMeterView.ticks {
                    let x = LevelMeterView.position(tick, width: size.width)
                    context.fill(Path(CGRect(x: min(max(x - 0.5, 0), size.width - 1), y: 0, width: 1, height: 3)),
                                 with: .color(Color.primary.opacity(0.35)))
                    let label = Text(tick == 0 ? "0" : String(Int(tick)))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    let anchor: UnitPoint = tick == 0 ? .topTrailing : (tick == LevelMeterModel.floorDB ? .topLeading : .top)
                    context.draw(label, at: CGPoint(x: x, y: 4), anchor: anchor)
                }
            }
        }
    }
}
