import AppKit
import AVFoundation
import Combine
import Foundation

struct RecordingItem: Identifiable, Equatable {
    let url: URL
    let created: Date
    let size: Int64
    let duration: TimeInterval?

    var id: URL { url }
    /// File name without the extension.
    var name: String { url.deletingPathExtension().lastPathComponent }
    var kind: String { url.pathExtension.uppercased() }
}

/// Playback position of the file that is playing. Kept apart from `LibraryModel` so that the
/// ten updates per second redraw only the progress bar, not the whole list.
final class PlaybackProgress: ObservableObject {
    @Published var fraction: Double = 0
    @Published var currentTime: TimeInterval = 0
}

/// The list of recordings in the chosen folder, plus playback and file actions.
final class LibraryModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = LibraryModel()
    static let supportedExtensions: Set<String> = ["wav", "m4a", "aiff", "aif", "caf", "mp3", "flac"]

    @Published private(set) var items: [RecordingItem] = []
    @Published var selection: URL?
    @Published private(set) var playingURL: URL?
    @Published var renaming: RecordingItem?
    @Published var errorMessage: String?

    let progress = PlaybackProgress()
    let folder: RecordingFolderStore

    /// The file being recorded right now. It is left out of the list until it is finished.
    var recordingInProgress: URL? {
        didSet { reload() }
    }

    private var player: AVAudioPlayer?
    private var progressTimer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var pendingReload: DispatchWorkItem?
    private var reloadGeneration = 0
    private var folderSubscription: AnyCancellable?
    private let loadQueue = DispatchQueue(label: "local.recorder.library", qos: .utility)
    private var durationCache: [String: TimeInterval] = [:] // only touched on loadQueue

    init(folder: RecordingFolderStore = .shared) {
        self.folder = folder
        super.init()
        startWatching()
        reload()
        folderSubscription = folder.$url.dropFirst().removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.folderChanged() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    var selectedItem: RecordingItem? {
        guard let selection else { return nil }
        return items.first { $0.url == selection }
    }

    // MARK: Loading

    private func folderChanged() {
        stopPlayback()
        selection = nil
        items = []
        startWatching()
        reload()
    }

    func reload() {
        let directory = folder.url
        reloadGeneration += 1
        let generation = reloadGeneration
        let excluded = recordingInProgress?.standardizedFileURL.path
        loadQueue.async { [weak self] in
            guard let self else { return }
            let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            )) ?? []
            var found: [RecordingItem] = []
            for url in urls where Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
                if url.standardizedFileURL.path == excluded { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                let created = values.creationDate ?? values.contentModificationDate ?? Date.distantPast
                let size = Int64(values.fileSize ?? 0)
                let cacheKey = "\(url.path)|\(size)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                let duration: TimeInterval?
                if let cached = self.durationCache[cacheKey] {
                    duration = cached
                } else {
                    duration = Self.duration(of: url)
                    if let duration { self.durationCache[cacheKey] = duration }
                }
                found.append(RecordingItem(url: url.standardizedFileURL, created: created, size: size, duration: duration))
            }
            found.sort {
                $0.created != $1.created ? $0.created > $1.created : $0.url.lastPathComponent > $1.url.lastPathComponent
            }
            DispatchQueue.main.async {
                // Ignore a result for another folder or one that a newer reload has replaced.
                guard directory == self.folder.url, generation == self.reloadGeneration else { return }
                if found != self.items { self.items = found }
                // Drop the selection only when its file is really gone.
                if let selection = self.selection, !found.contains(where: { $0.url == selection }),
                   !FileManager.default.fileExists(atPath: selection.path) {
                    self.selection = nil
                }
            }
        }
    }

    private static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let rate = file.processingFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : nil
    }

    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func startWatching() {
        watcher?.cancel()
        watcher = nil
        // The folder may not exist yet (it is created on the first recording). Watch its parent then.
        var target = folder.url
        if !FileManager.default.fileExists(atPath: target.path) { target = target.deletingLastPathComponent() }
        watchedPath = target.path
        let descriptor = open(target.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // If the watched folder was moved or removed, watch again from scratch.
            let event = source.data
            let folderPath = self.folder.url.path
            if event.contains(.rename) || event.contains(.delete)
                || (self.watchedPath != folderPath && FileManager.default.fileExists(atPath: folderPath)) {
                self.startWatching()
            }
            self.scheduleReload()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    // MARK: Playback

    func togglePlay(_ item: RecordingItem) {
        if playingURL == item.url {
            stopPlayback()
            return
        }
        stopPlayback()
        do {
            let player = try AVAudioPlayer(contentsOf: item.url)
            player.delegate = self
            player.prepareToPlay()
            guard player.play() else {
                errorMessage = "\(item.url.lastPathComponent) could not be played."
                return
            }
            self.player = player
            playingURL = item.url
            progress.fraction = 0
            progress.currentTime = 0
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateProgress() }
            RunLoop.main.add(timer, forMode: .common)
            progressTimer = timer
        } catch {
            errorMessage = "\(item.url.lastPathComponent) could not be played: \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        progressTimer?.invalidate()
        progressTimer = nil
        player?.stop()
        player = nil
        if playingURL != nil { playingURL = nil }
        progress.fraction = 0
        progress.currentTime = 0
    }

    private func updateProgress() {
        guard let player, player.duration > 0 else { return }
        progress.currentTime = player.currentTime
        progress.fraction = min(1, player.currentTime / player.duration)
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            self.stopPlayback()
        }
    }

    // MARK: File actions

    func reveal(_ item: RecordingItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    func openFolder() {
        try? folder.ensureExists()
        NSWorkspace.shared.open(folder.url)
    }

    func moveToTrash(_ item: RecordingItem) {
        if playingURL == item.url { stopPlayback() }
        do {
            try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
            if selection == item.url { selection = nil }
            reload()
        } catch {
            errorMessage = "\(item.url.lastPathComponent) could not be moved to the Trash: \(error.localizedDescription)"
        }
    }

    /// Returns a message when the name is not acceptable, or nil when it is fine.
    func validateName(_ proposed: String, for item: RecordingItem) -> String? {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "The name cannot be empty." }
        if name.contains("/") || name.contains(":") { return "The name cannot contain / or :." }
        if name.hasPrefix(".") { return "The name cannot start with a dot." }
        let target = destination(for: name, item: item)
        if target != item.url, FileManager.default.fileExists(atPath: target.path),
           target.path.lowercased() != item.url.path.lowercased() {
            return "A file with this name already exists."
        }
        return nil
    }

    func rename(_ item: RecordingItem, to proposed: String) {
        let name = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validateName(name, for: item) == nil else { return }
        let target = destination(for: name, item: item)
        guard target != item.url else { return }
        if playingURL == item.url { stopPlayback() }
        do {
            if target.path.lowercased() == item.url.path.lowercased() {
                // Only the case changes. Go through a temporary name so case-insensitive volumes accept it.
                let temporary = item.url.deletingLastPathComponent()
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension(item.url.pathExtension)
                try FileManager.default.moveItem(at: item.url, to: temporary)
                try FileManager.default.moveItem(at: temporary, to: target)
            } else {
                try FileManager.default.moveItem(at: item.url, to: target)
            }
            selection = target.standardizedFileURL
            reload()
        } catch {
            errorMessage = "\(item.url.lastPathComponent) could not be renamed: \(error.localizedDescription)"
        }
    }

    private func destination(for name: String, item: RecordingItem) -> URL {
        item.url.deletingLastPathComponent()
            .appendingPathComponent(name)
            .appendingPathExtension(item.url.pathExtension)
    }
}
