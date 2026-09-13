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
                        sidebar
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
                Text(
                    (appState.selectedFolderURL ?? appState.libraryFolder)?.path
                        ?? "Apple Books .m4b files, with title, author, cover, and chapters"
                )
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

    private var sidebar: some View {
        VStack(spacing: 0) {
            if appState.showsFolderTree {
                VSplitView {
                    folderTree
                        .frame(minHeight: 120)
                    bookList
                }
            } else {
                bookList
            }
        }
        .background(BinderTheme.paper.opacity(0.4))
    }

    private var folderTree: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 0) {
            Text("FOLDERS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(BinderTheme.inkMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            if let outline = appState.folderOutline {
                List(selection: $state.selectedFolderURL) {
                    FolderOutlineRows(node: outline, selected: state.selectedFolderURL)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var bookList: some View {
        @Bindable var state = appState
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(booksHeaderTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(BinderTheme.inkMuted)
                    .lineLimit(1)
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

            TextField("Filter", text: $state.bookQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            List(selection: $state.selectedID) {
                ForEach($state.books) { $book in
                    if appState.isVisible(book) {
                        BookRow(book: $book)
                            .tag(book.id)
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(book.id == state.selectedID ? BinderTheme.gold.opacity(0.22) : Color.clear)
                                    .padding(.horizontal, 6)
                            )
                    }
                }
                if !state.books.contains(where: { appState.isVisible($0) }) {
                    Text("No matching books")
                        .font(.system(size: 11))
                        .foregroundStyle(BinderTheme.inkMuted)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    private var booksHeaderTitle: String {
        guard let folder = appState.selectedFolderURL,
              let root = appState.libraryFolder,
              !LibraryOutline.sameFolder(folder, root) else {
            return "BOOKS"
        }
        return "BOOKS IN \(folder.lastPathComponent.uppercased())"
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
            if let scan = appState.scanProgress, scan.bookCount > 0 {
                ProgressView(value: min(max(scan.fraction, 0), 1))
                    .frame(width: 140)
                Text("\(scan.bookIndex)/\(scan.bookCount)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BinderTheme.inkMuted)
            } else if let build = appState.build {
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
                .truncationMode(.middle)
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
                Button("Open in Books") { appState.openInBooks(url) }
                    .buttonStyle(.plain)
                    .foregroundStyle(BinderTheme.leather)
                    .help("Open the audiobook in Apple Books")
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

struct FolderOutlineRows: View {
    let node: LibraryNode
    var selected: URL?
    @State private var expanded = true

    var body: some View {
        if node.children.isEmpty {
            FolderLabel(node: node, isSelected: isSelected)
                .tag(node.url)
                .listRowBackground(rowBackground)
        } else {
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(node.children) { child in
                    FolderOutlineRows(node: child, selected: selected)
                }
            } label: {
                FolderLabel(node: node, isSelected: isSelected)
            }
            .tag(node.url)
            .listRowBackground(rowBackground)
        }
    }

    private var isSelected: Bool {
        guard let selected else { return false }
        return LibraryOutline.sameFolder(selected, node.url)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? BinderTheme.gold.opacity(0.22) : Color.clear)
            .padding(.horizontal, 6)
    }
}

struct FolderLabel: View {
    let node: LibraryNode
    var isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.hasNestedFolders ? "folder.fill" : "folder")
                .font(.system(size: 12))
                .foregroundStyle(BinderTheme.gold)
                .frame(width: 16)
            Text(node.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(BinderTheme.ink)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("\(node.bookCount)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(BinderTheme.inkMuted)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .help("Show books in this folder")
    }
}

struct BookRow: View {
    @Binding var book: Audiobook

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: selectionBinding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(book.isAlreadyBound)
            CoverView(data: book.coverJPEG, url: book.coverURL, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BinderTheme.ink)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(BinderTheme.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var selectionBinding: Binding<Bool> {
        Binding(
            get: { book.isAlreadyBound ? false : book.selected },
            set: { newValue in
                if !book.isAlreadyBound {
                    book.selected = newValue
                }
            }
        )
    }

    private var subtitle: String {
        if book.isAlreadyBound {
            return "\(book.author)  ·  Already an audiobook  ·  \(DurationFormat.string(book.totalDuration))"
        }
        return "\(book.author)  ·  \(book.chapterCountLabel)  ·  \(DurationFormat.string(book.totalDuration))"
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
                            Label(book.chapterCountLabel, systemImage: "list.number")
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
                    HStack {
                        Text("Chapters")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(BinderTheme.inkMuted)
                        if !book.isAlreadyBound {
                            Spacer()
                            Button("All") { setChaptersIncluded(true) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(BinderTheme.leather)
                            Button("None") { setChaptersIncluded(false) }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(BinderTheme.leather)
                        }
                    }
                    if book.isAlreadyBound {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Already an audiobook")
                            if let name = book.existingM4BURL?.lastPathComponent {
                                Text(name)
                            }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(BinderTheme.inkMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.62))
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach($book.chapters) { $chapter in
                                HStack(spacing: 10) {
                                    Toggle("", isOn: $chapter.included)
                                        .labelsHidden()
                                        .toggleStyle(.checkbox)
                                    Text(String(format: "%02d", chapter.index))
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(BinderTheme.gold)
                                        .frame(width: 28, alignment: .trailing)
                                    TextField("Chapter title", text: $chapter.title)
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 13))
                                        .foregroundStyle(chapter.included ? BinderTheme.ink : BinderTheme.inkMuted)
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
    }

    private func setChaptersIncluded(_ included: Bool) {
        for i in book.chapters.indices {
            book.chapters[i].included = included
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
