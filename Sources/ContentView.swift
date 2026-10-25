import SwiftUI

struct ContentView: View {
    @ObservedObject var recorder: RecorderModel
    @ObservedObject var library: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            RecorderPanel(recorder: recorder, folder: recorder.folder)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)
            Divider()
            LibraryView(library: library, folder: library.folder)
        }
        .frame(minWidth: 540, minHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The top part of the window: record button, time, meter and settings.
struct RecorderPanel: View {
    @ObservedObject var recorder: RecorderModel
    @ObservedObject var folder: RecordingFolderStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if recorder.permissionProblem {
                PermissionBanner(restricted: recorder.authorization == .restricted) {
                    recorder.openPrivacySettings()
                }
            }
            if let notice = recorder.notice {
                NoticeBanner(notice: notice) { recorder.notice = nil }
            }

            HStack(spacing: 20) {
                RecordButton(isRecording: recorder.isActive) { recorder.toggleRecording() }

                VStack(alignment: .leading, spacing: 2) {
                    Text(TimeFormat.clock(recorder.elapsedSeconds))
                        .font(.system(size: 46, weight: .light).monospacedDigit())
                        .accessibilityLabel("Elapsed time")
                    Text(recorder.statusLine)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if recorder.isActive {
                    Button { recorder.togglePause() } label: {
                        Label(recorder.state == .paused ? "Resume" : "Pause",
                              systemImage: recorder.state == .paused ? "play.fill" : "pause.fill")
                    }
                    .controlSize(.large)
                }
            }

            LevelMeterView(model: recorder.meter)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    label("Input")
                    Picker("Input", selection: $recorder.selectedInputUID) {
                        Text(defaultInputTitle).tag("")
                        ForEach(recorder.devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                        if recorder.selectedInputMissing {
                            Text("Saved input (not connected)").tag(recorder.selectedInputUID)
                        }
                    }
                    .labelsHidden()
                    .disabled(recorder.isActive)
                }
                GridRow {
                    label("Format")
                    Picker("Format", selection: $recorder.format) {
                        ForEach(RecordingFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .labelsHidden()
                    .disabled(recorder.isActive)
                }
                GridRow {
                    label("Save to")
                    HStack(spacing: 8) {
                        Text(folder.displayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder.url.path)
                        Spacer(minLength: 0)
                        Button("Choose...") { recorder.chooseFolder() }
                            .disabled(recorder.isActive)
                    }
                }
                if let message = folder.notice {
                    GridRow {
                        Color.clear.frame(width: 0, height: 0)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private var defaultInputTitle: String {
        if let name = recorder.defaultDeviceName { return "System Default (\(name))" }
        return "System Default"
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }
}

/// Big round record button. Space bar toggles it.
struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 3)
                    .frame(width: 76, height: 76)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 29, style: .continuous)
                    .fill(Color.red)
                    .frame(width: isRecording ? 30 : 58, height: isRecording ? 30 : 58)
            }
            .frame(width: 80, height: 80)
            .contentShape(Circle())
            .animation(.easeInOut(duration: 0.18), value: isRecording)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .keyboardShortcut(.space, modifiers: [])
        .help(isRecording ? "Stop recording (Space)" : "Start recording (Space)")
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }
}

struct PermissionBanner: View {
    let restricted: Bool
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "mic.slash.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text("Microphone access is off")
                    .font(.headline)
                Text(restricted
                     ? "This Mac restricts microphone access for apps, for example through a device management profile. Recorder cannot record until that changes."
                     : "Recorder cannot record without permission. Allow it in System Settings under Privacy & Security, Microphone, then come back here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !restricted {
                    Button("Open System Settings", action: openSettings)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.14)))
    }
}

struct NoticeBanner: View {
    let notice: RecorderModel.Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: notice.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(notice.kind == .error ? Color.red : Color.blue)
            Text(notice.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((notice.kind == .error ? Color.red : Color.blue).opacity(0.10))
        )
    }
}
