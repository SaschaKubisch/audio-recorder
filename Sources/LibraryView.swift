import SwiftUI

/// The list of past recordings with playback and file actions.
struct LibraryView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var folder: RecordingFolderStore

    var body: some View {
        VStack(spacing: 0) {
            header
            if library.items.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            actionBar
        }
        .sheet(item: $library.renaming) { item in
            RenameSheet(library: library, item: item)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text("Recordings")
                .font(.headline)
            Text("\(library.items.count)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button { library.openFolder() } label: {
                Label("Open Folder", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open \(folder.displayPath) in Finder")
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No recordings yet")
                .font(.headline)
            Text("Press the red button or the space bar to start.\nFinished recordings appear here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var list: some View {
        List(selection: $library.selection) {
            ForEach(library.items) { item in
                RecordingRow(library: library, progress: library.progress, item: item)
                    .tag(item.url)
                    .onDrag {
                        NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
                    }
                    .simultaneousGesture(TapGesture(count: 2).onEnded { library.togglePlay(item) })
                    .contextMenu { contextMenu(for: item) }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func contextMenu(for item: RecordingItem) -> some View {
        Button(library.playingURL == item.url ? "Stop" : "Play") { library.togglePlay(item) }
        Button("Reveal in Finder") { library.reveal(item) }
        Button("Rename...") { library.renaming = item }
        Divider()
        Button("Move to Trash") { library.moveToTrash(item) }
    }

    private var actionBar: some View {
        let item = library.selectedItem
        let playing = item != nil && library.playingURL == item?.url
        return HStack(spacing: 10) {
            Button {
                if let item { library.togglePlay(item) }
            } label: {
                Label(playing ? "Stop" : "Play", systemImage: playing ? "stop.fill" : "play.fill")
            }
            Button {
                if let item { library.reveal(item) }
            } label: {
                Label("Reveal in Finder", systemImage: "magnifyingglass")
            }
            Button {
                if let item { library.renaming = item }
            } label: {
                Label("Rename...", systemImage: "pencil")
            }
            Spacer(minLength: 0)
            Button {
                if let item { library.moveToTrash(item) }
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
        .labelStyle(.titleAndIcon)
        .disabled(item == nil)
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

struct RecordingRow: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var progress: PlaybackProgress
    let item: RecordingItem

    private var isPlaying: Bool { library.playingURL == item.url }

    var body: some View {
        HStack(spacing: 12) {
            Button { library.togglePlay(item) } label: {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(isPlaying ? Color.red : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Stop playback" : "Play")
            .accessibilityLabel(isPlaying ? "Stop \(item.name)" : "Play \(item.name)")

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.kind)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
                }
                if isPlaying {
                    ProgressView(value: progress.fraction)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                } else {
                    Text(item.created.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(durationText)
                    .monospacedDigit()
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private var durationText: String {
        if isPlaying {
            return "\(TimeFormat.clock(Int(progress.currentTime))) / \(TimeFormat.clock(duration: item.duration))"
        }
        return TimeFormat.clock(duration: item.duration)
    }
}

struct RenameSheet: View {
    @ObservedObject var library: LibraryModel
    let item: RecordingItem

    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(library: LibraryModel, item: RecordingItem) {
        self.library = library
        self.item = item
        _name = State(initialValue: item.name)
    }

    private var cleaned: String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = "." + item.url.pathExtension.lowercased()
        if value.lowercased().hasSuffix(suffix) { value = String(value.dropLast(suffix.count)) }
        return value
    }

    private var problem: String? {
        library.validateName(cleaned, for: item)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Recording")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Text(problem ?? "The extension .\(item.url.pathExtension) is kept.")
                    .font(.caption)
                    .foregroundStyle(problem == nil ? Color.secondary : Color.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func commit() {
        guard problem == nil else { return }
        library.rename(item, to: cleaned)
        dismiss()
    }
}
