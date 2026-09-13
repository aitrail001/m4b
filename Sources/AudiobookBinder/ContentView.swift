import SwiftUI
import AppKit
import AudiobookBinderCore

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        ZStack {
            BinderTheme.paper.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.25)
                if state.books.isEmpty {
                    emptyState
                } else {
                    HSplitView {
                        bookList
                            .frame(minWidth: 280, idealWidth: 340)
                        editor
                            .frame(minWidth: 520)
                    }
                }
                Divider().opacity(0.25)
                footer
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .binderOpenURLs)) { note in
            if let urls = note.object as? [URL], let first = urls.first {
                appState.scan(first)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Audiobook Binder")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(BinderTheme.ink)
                Text(appState.libraryFolder?.path ?? "Apple Books .m4b files, with title, author, cover, and chapters")
                    .font(.system(size: 12))
                    .foregroundStyle(BinderTheme.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Open Folder…") { appState.openFolder() }
                .buttonStyle(BinderButtonStyle())
                .disabled(appState.isScanning || appState.isBuilding)
            Button(appState.isBuilding ? "Building…" : "Build \(appState.selectedCount) Selected") {
                appState.buildSelected()
            }
            .buttonStyle(BinderButtonStyle(prominent: true))
            .disabled(appState.selectedCount == 0 || appState.isBuilding || appState.isScanning)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(BinderTheme.paperDeep.opacity(0.35))
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "headphones")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(BinderTheme.leather)
            Text("Drop a books folder here")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(BinderTheme.ink)
            Text("Select a book folder, or a library folder. Nested wrappers are scanned automatically. MP3 chapters, covers, and ebook metadata are picked up on their own.")
                .font(.system(size: 13))
                .foregroundStyle(BinderTheme.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button("Choose Folder") { appState.openFolder() }
                .buttonStyle(BinderButtonStyle(prominent: true))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bookList: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("BOOKS")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BinderTheme.inkMuted)
                Spacer()
                Button("All") { appState.selectAll(true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BinderTheme.leather)
                Button("None") { appState.selectAll(false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BinderTheme.leather)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            List(selection: $state.selectedID) {
                ForEach($state.books) { $book in
                    BookRow(book: $book)
                        .tag(book.id)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(book.id == state.selectedID ? BinderTheme.gold.opacity(0.22) : Color.clear)
                                .padding(.horizontal, 6)
                        )
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(BinderTheme.paper.opacity(0.4))
    }

    private var editor: some View {
        @Bindable var state = appState
        return Group {
            if let idx = state.selectedBookBindingIndex {
                BookEditor(book: $state.books[idx])
            } else {
                Text("Select a book")
                    .foregroundStyle(BinderTheme.inkMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if appState.isScanning || appState.isBuilding {
                ProgressView()
                    .controlSize(.small)
            }
            if let build = appState.build {
                ProgressView(value: min(max(build.fraction, 0), 1))
                    .frame(width: 140)
                Text("\(build.bookIndex)/\(build.bookCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BinderTheme.inkMuted)
            }
            Text(appState.status)
                .font(.system(size: 12))
                .foregroundStyle(appState.lastError == nil ? BinderTheme.inkMuted : Color.red.opacity(0.85))
                .lineLimit(1)
            Spacer()
            Toggle("Save in book folder", isOn: Bindable(appState).settings.writeNextToBook)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Write the .m4b into the same folder as the chapter files")
            if !appState.settings.writeNextToBook {
                let folderName = appState.settings.outputDirectory?.lastPathComponent
                    ?? ExportSettings.defaultOutputDirectory.lastPathComponent
                Button("Save to: \(folderName)") {
                    appState.chooseOutputFolder()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BinderTheme.leather)
                .help(
                    (appState.settings.outputDirectory ?? ExportSettings.defaultOutputDirectory).path
                )
            }
            Picker("Bitrate", selection: Bindable(appState).settings.bitrate) {
                Text("64 kbps").tag(64_000)
                Text("96 kbps").tag(96_000)
                Text("128 kbps").tag(128_000)
            }
            .labelsHidden()
            .frame(width: 110)
            Toggle("Overwrite", isOn: Bindable(appState).settings.overwrite)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            if appState.isBuilding {
                Button("Cancel") { appState.cancelBuild() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }
            if let url = appState.finishedURLs.last {
                Button("Show in Finder") { appState.reveal(url) }
                    .buttonStyle(.plain)
                    .foregroundStyle(BinderTheme.leather)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(BinderTheme.paperDeep.opacity(0.45))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                let folder = isDir.boolValue ? url : url.deletingLastPathComponent()
                Task { @MainActor in
                    appState.scan(folder)
                }
            }
            handled = true
        }
        return handled
    }
}

struct BookRow: View {
    @Binding var book: Audiobook

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $book.selected)
                .labelsHidden()
                .toggleStyle(.checkbox)
            CoverView(data: book.coverJPEG, url: book.coverURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BinderTheme.ink)
                    .lineLimit(2)
                Text("\(book.author)  ·  \(book.chapterCount) chapters  ·  \(DurationFormat.string(book.totalDuration))")
                    .font(.system(size: 11))
                    .foregroundStyle(BinderTheme.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct BookEditor: View {
    @Binding var book: Audiobook
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(spacing: 8) {
                        CoverView(data: book.coverJPEG, url: book.coverURL, size: 168)
                        Button("Change Cover…") { appState.chooseCover() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(BinderTheme.leather)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        labeled("Title") { TextField("Title", text: $book.title) }
                        labeled("Author") { TextField("Author", text: $book.author) }
                        labeled("Narrator") { TextField("Narrator", text: $book.narrator) }
                        labeled("Genre") { TextField("Genre", text: $book.genre) }
                        HStack {
                            Label(DurationFormat.string(book.totalDuration), systemImage: "clock")
                            Label("\(book.chapterCount) chapters", systemImage: "list.number")
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(BinderTheme.inkMuted)
                        Text(book.folder.path)
                            .font(.system(size: 11))
                            .foregroundStyle(BinderTheme.inkMuted)
                            .textSelection(.enabled)
                            .lineLimit(2)
                    }
                }

                labeled("Description") {
                    TextEditor(text: $book.bookDescription)
                        .font(.system(size: 13))
                        .frame(minHeight: 72, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.65)))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Chapters")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(BinderTheme.inkMuted)
                    VStack(spacing: 0) {
                        ForEach($book.chapters) { $chapter in
                            HStack(spacing: 10) {
                                Text(String(format: "%02d", chapter.index))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(BinderTheme.gold)
                                    .frame(width: 28, alignment: .trailing)
                                TextField("Chapter title", text: $chapter.title)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                Spacer(minLength: 8)
                                if !chapter.audioInfo.summary.isEmpty {
                                    Text(chapter.audioInfo.summary)
                                        .font(.system(size: 11))
                                        .foregroundStyle(BinderTheme.inkMuted)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .frame(minWidth: 0)
                                        .layoutPriority(-1)
                                }
                                let playingThis = appState.playback.isPlaying(chapter)
                                Button {
                                    appState.playback.toggle(chapter)
                                } label: {
                                    Image(systemName: playingThis ? "pause.circle.fill" : "play.circle")
                                        .font(.system(size: 14))
                                        .foregroundStyle(
                                            appState.playback.playingID == chapter.id
                                                ? BinderTheme.leather
                                                : BinderTheme.ink
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(playingThis ? "Pause chapter" : "Play chapter")
                                .accessibilityLabel(playingThis ? "Pause chapter" : "Play chapter")
                                .disabled(appState.isBuilding)
                                Text(DurationFormat.string(chapter.duration))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(BinderTheme.inkMuted)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            if chapter.id != book.chapters.last?.id {
                                Divider().opacity(0.2)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.62))
                    )
                }
            }
        }
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BinderTheme.inkMuted)
            content()
                .textFieldStyle(.plain)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.65)))
        }
    }
}

struct CoverView: View {
    var data: Data?
    var url: URL?
    var size: CGFloat

    var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    BinderTheme.paperDeep
                    Image(systemName: "book.closed")
                        .foregroundStyle(BinderTheme.leather.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 80 ? 10 : 6, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }
}
