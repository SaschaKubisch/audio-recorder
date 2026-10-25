import AppKit
import SwiftUI

/// Entry point. With `--self-test <folder>` the file writer is checked without any window or
/// microphone. Otherwise the normal app starts.
@main
struct Launcher {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--self-test") {
            guard index + 1 < args.count else {
                FileHandle.standardError.write(Data("Usage: Recorder --self-test <output folder>\n".utf8))
                exit(2)
            }
            exit(SelfTest.run(outputDirectory: args[index + 1]))
        }
        RecorderApp.main()
    }
}

struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var recorder = RecorderModel.shared
    @StateObject private var library = LibraryModel.shared

    var body: some Scene {
        Window("Recorder", id: "main") {
            ContentView(recorder: recorder, library: library)
                .onAppear { wireModels() }
        }
        .defaultSize(width: 580, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            RecordingCommands(recorder: recorder, library: library)
        }
    }

    /// Connects the recorder to the list: playback stops when recording starts, the file that is
    /// being written stays out of the list, and the finished file is selected.
    private func wireModels() {
        recorder.onWillStart = { library.stopPlayback() }
        recorder.onStarted = { url in library.recordingInProgress = url }
        recorder.onFinished = { url in
            library.recordingInProgress = nil
            if let url { library.selection = url.standardizedFileURL }
        }
    }
}

struct RecordingCommands: Commands {
    @ObservedObject var recorder: RecorderModel
    @ObservedObject var library: LibraryModel

    var body: some Commands {
        CommandMenu("Recording") {
            Button(recorder.isActive ? "Stop Recording" : "Start Recording") {
                recorder.toggleRecording()
            }
            .keyboardShortcut("r", modifiers: .command)

            Button(recorder.state == .paused ? "Resume Recording" : "Pause Recording") {
                recorder.togglePause()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .disabled(!recorder.isActive)

            Divider()

            Button("Show Recordings Folder") { library.openFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `Recorder --snapshot <file.png>` writes a picture of the window two seconds after launch and
    /// quits. It captures the app's own window, so it needs no Screen Recording permission. Used to
    /// check the layout from a script. `--appearance light` or `dark` forces the look for that run.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--appearance"), index + 1 < args.count {
            switch args[index + 1] {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            default: break
            }
        }
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return }
        let path = args[index + 1]
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            let ok = WindowSnapshot.write(to: path)
            if !ok { FileHandle.standardError.write(Data("Could not write the snapshot to \(path)\n".utf8)) }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting while recording stops the recording first, so the file is closed and valid.
    func applicationWillTerminate(_ notification: Notification) {
        RecorderModel.shared.shutdown()
        LibraryModel.shared.stopPlayback()
    }
}

enum WindowSnapshot {
    static func write(to path: String) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }),
              let image = CGWindowListCreateImage(
                  .null, .optionIncludingWindow, CGWindowID(window.windowNumber), [.boundsIgnoreFraming, .bestResolution]
              ),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        return (try? data.write(to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))) != nil
    }
}
