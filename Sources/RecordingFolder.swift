import AppKit
import Foundation

/// Where recordings are saved. The default is `~/Music/Recordings`.
///
/// The choice is stored in UserDefaults as a plain path. The app is not sandboxed, so no
/// security-scoped bookmark is needed. If the stored folder is gone at launch, the default is
/// used and `notice` says so.
final class RecordingFolderStore: ObservableObject {
    static let shared = RecordingFolderStore()

    /// UserDefaults key (domain `local.recorder`). Holds a folder path.
    static let defaultsKey = "recordingsFolderPath"

    static var defaultFolder: URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music")
        return music.appendingPathComponent("Recordings", isDirectory: true)
    }

    @Published private(set) var url: URL
    /// A one-line explanation shown under the folder row, for example after a fallback to the default.
    @Published private(set) var notice: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.string(forKey: Self.defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stored.isEmpty {
            url = Self.defaultFolder
            notice = nil
        } else {
            let path = (stored as NSString).expandingTildeInPath
            if Self.isDirectory(path) {
                url = URL(fileURLWithPath: path, isDirectory: true)
                notice = nil
            } else {
                url = Self.defaultFolder
                notice = "The folder \((path as NSString).abbreviatingWithTildeInPath) no longer exists. Using \(Self.abbreviated(Self.defaultFolder)) instead."
            }
        }
    }

    /// The folder as shown in the window, for example `~/Music/Recordings`.
    var displayPath: String { Self.abbreviated(url) }

    var isDefault: Bool { url.standardizedFileURL.path == Self.defaultFolder.standardizedFileURL.path }

    /// Creates the folder if it is missing. Call before writing a file.
    func ensureExists() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Switches to a folder the user picked and remembers it.
    func choose(_ folder: URL) {
        let picked = folder.standardizedFileURL
        if FileManager.default.fileExists(atPath: picked.path), !FileManager.default.isWritableFile(atPath: picked.path) {
            notice = "The folder \(Self.abbreviated(picked)) is not writable. Still saving to \(displayPath)."
            return
        }
        url = picked
        notice = nil
        defaults.set(url.path, forKey: Self.defaultsKey)
    }

    /// Opens the folder picker. Does nothing else; the caller is responsible for not calling it while recording.
    func presentChooser() {
        let panel = NSOpenPanel()
        panel.title = "Choose Recordings Folder"
        panel.message = "Recordings are saved in this folder."
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        panel.begin { [weak self] response in
            guard response == .OK, let picked = panel.url else { return }
            self?.choose(picked)
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
