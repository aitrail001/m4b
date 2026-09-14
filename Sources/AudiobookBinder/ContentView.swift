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
                Divider().opacity(0.12)
                controlsBar
                Divider().opacity(0.25)
                if state.books.isEmpty {
                    emptyState
                } else {
                    HSplitView {
                        sidebar
                            .frame(minWidth: 280, idealWidth: 340)
                        editor
                            .frame(minWidth: 360)
                    }
                }
                Divider().opacity(0.25)
                statusBar
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
        .background(WindowTitleView(title: "Audiobook Binder \(AppVersion.display)"))
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .center, spacing: 10) {
                    Text("Audiobook Binder")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(BinderTheme.ink)
                    Text(AppVersion.badge)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(BinderTheme.leather))
                        .help("Version \(AppVersion.display)")
                }
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
        .padding(.top, 16)
        .padding(.bottom, 10)
        .background(BinderTheme.paperDeep.opacity(0.35))
    }

    private var controlsBar: some View {
        HStack(spacing: 14) {
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
            Spacer(minLength: 8)
            if appState.isBuilding {
                Button("Cancel") { appState.cancelBuild() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
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

    private var statusBar: some View {
        HStack(spacing: 12) {
            if appState.isScanning || appState.isBuilding {
                ProgressView()
                    .controlSize(.small)
            }
            if let scan = appState.scanProgress, scan.count > 0 {
                ProgressView(value: min(max(scan.fraction, 0), 1))
                    .frame(width: 140)
                Text("\(scan.index)/\(scan.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BinderTheme.inkMuted)
            } else if let build = appState.build {
                ProgressView(value: min(max(build.fraction, 0), 1))
                    .frame(width: 140)
                Text("\(build.index)/\(build.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BinderTheme.inkMuted)
            }
            Text(appState.status)
                .font(.system(size: 12))
                .foregroundStyle(appState.lastError == nil ? BinderTheme.inkMuted : Color.red.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if let url = appState.finishedURLs.last {
                Button("Show in Finder") { appState.reveal(url) }
                    .buttonStyle(.plain)
                    .foregroundStyle(BinderTheme.leather)
                Button("Open in Books") { appState.openInBooks(url) }
                    .buttonStyle(.plain)
                    .foregroundStyle(BinderTheme.leather)
                    .help("Open the audiobook in Apple Books")
                Button("Verify") {
                    if let book = appState.books.first(where: { $0.existingM4BURL == url }) {
                        appState.selectedID = book.id
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(BinderTheme.leather)
                .help("Inspect chapters and play the finished .m4b")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
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
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        coverColumn(168)
                        fieldsColumn
                    }
                    HStack(alignment: .top, spacing: 12) {
                        coverColumn(108)
                        fieldsColumn
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        coverColumn(108)
                        fieldsColumn
                    }
                }

                labeled("Description") {
                    TextEditor(text: $book.bookDescription)
                        .font(.system(size: 13))
                        .frame(minWidth: 0, minHeight: 72, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                }

                ChaptersCompareSection(book: $book)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func coverColumn(_ size: CGFloat) -> some View {
        VStack(spacing: 8) {
            CoverView(data: book.coverJPEG, url: book.coverURL, size: size)
            Button("Change Cover…") { appState.chooseCover() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(BinderTheme.leather)
        }
    }

    private var fieldsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled("Title") { TextField("Title", text: $book.title).lineLimit(1) }
            labeled("Author") { TextField("Author", text: $book.author).lineLimit(1) }
            labeled("Narrator") { TextField("Narrator", text: $book.narrator).lineLimit(1) }
            labeled("Genre") { TextField("Genre", text: $book.genre).lineLimit(1) }
            HStack(spacing: 12) {
                Label(DurationFormat.string(book.totalDuration), systemImage: "clock")
                Label(book.chapterCountLabel, systemImage: "list.number")
            }
            .font(.system(size: 12))
            .foregroundStyle(BinderTheme.inkMuted)
            .lineLimit(1)
            Text(book.folder.path)
                .font(.system(size: 11))
                .foregroundStyle(BinderTheme.inkMuted)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BinderTheme.inkMuted)
            content()
                .textFieldStyle(.plain)
                .padding(8)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.65)))
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

private struct WindowTitleView: NSViewRepresentable {
    var title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.title = title }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.title = title
    }
}

struct ChaptersCompareSection: View {
    @Binding var book: Audiobook
    @Environment(AppState.self) private var appState
    @State private var inspection: M4BInspection?
    @State private var boundChapters: [Chapter] = []
    @State private var fileChapter: Chapter?
    @State private var inspecting = false
    @State private var confirmCleanup = false
    @State private var cleanupError: String?

    private var m4bURL: URL? { appState.boundURL(for: book) }
    private var showOriginal: Bool { !book.chapters.isEmpty }
    private var showBound: Bool { m4bURL != nil }
    private var rows: [ChapterCompareRow] {
        ChapterCompare.rows(original: book.chapters, bound: boundChapters)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let inspection {
                comparisonBanner(inspection)
            } else if inspecting {
                Text("Reading .m4b…")
                    .font(.system(size: 12))
                    .foregroundStyle(BinderTheme.inkMuted)
            }

            if showOriginal || showBound {
                VStack(alignment: .leading, spacing: 0) {
                    compareHeaders
                    Divider().opacity(0.2)
                    ForEach(Array(rows.enumerated()), id: \.offset) { offset, row in
                        compareRow(row, originalIndex: offset < book.chapters.count ? offset : nil)
                        if offset < rows.count - 1 {
                            Divider().opacity(0.15)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.62))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(BinderTheme.gold.opacity(0.22), lineWidth: 1)
                )
            }

            if let cleanupError {
                Text(cleanupError)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.red.opacity(0.85))
            }
            if book.canCleanupSources, let inspection {
                cleanupControls(inspection: inspection)
            }
        }
        .task(id: m4bURL) {
            guard m4bURL != nil else {
                inspection = nil
                boundChapters = []
                fileChapter = nil
                return
            }
            await inspect()
        }
        .confirmationDialog(
            "Move original audio files to Trash?",
            isPresented: $confirmCleanup,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                performCleanup()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            let files = M4BInspector.sourceFilesToRemove(from: book)
            Text("\(files.count) original audio file\(files.count == 1 ? "" : "s") will go to Trash. The .m4b stays.")
        }
    }

    private var compareHeaders: some View {
        HStack(alignment: .center, spacing: 0) {
            if showOriginal {
                originalHeader
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showOriginal && showBound {
                Rectangle()
                    .fill(BinderTheme.gold.opacity(0.35))
                    .frame(width: 1)
                    .padding(.vertical, 6)
            }
            if showBound {
                boundHeader
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(BinderTheme.leather.opacity(0.08))
            }
        }
    }

    private var originalHeader: some View {
        HStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                SourceKindBadge(title: "Original audio files", emphasized: false)
                SourceKindBadge(title: "Original", emphasized: false)
            }
            Spacer(minLength: 4)
            Button("All") { setChaptersIncluded(true) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BinderTheme.leather)
            Button("None") { setChaptersIncluded(false) }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BinderTheme.leather)
        }
        .lineLimit(1)
    }

    private var boundHeader: some View {
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                SourceKindBadge(title: "Bound .m4b", emphasized: true)
                SourceKindBadge(title: ".m4b", emphasized: true)
            }
            if let m4bURL {
                Text(m4bURL.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(BinderTheme.inkMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 0)
                    .layoutPriority(-1)
            }
            Spacer(minLength: 4)
            if inspecting {
                Text("Reading…")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(BinderTheme.inkMuted)
                    .lineLimit(1)
            } else {
                Button("Inspect") {
                    Task { await inspect() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(BinderTheme.leather)
            }
            if let fileChapter {
                boundPlayControl(fileChapter)
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func boundPlayControl(_ fileChapter: Chapter) -> some View {
        let playingFile = appState.playback.isPlaying(fileChapter)
        Button {
            appState.playback.toggle(fileChapter)
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    Image(systemName: playingFile ? "pause.circle.fill" : "play.circle")
                    Text(playingFile ? "Pause" : "Play file")
                }
                Image(systemName: playingFile ? "pause.circle.fill" : "play.circle")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(BinderTheme.leather)
        .font(.system(size: 12, weight: .medium))
        .help(playingFile ? "Pause file" : "Play file")
        .layoutPriority(1)
    }

    @ViewBuilder
    private func compareRow(_ row: ChapterCompareRow, originalIndex: Int?) -> some View {
        let disagree = row.durationsMatch == false
        HStack(alignment: .center, spacing: 0) {
            if showOriginal {
                HStack(spacing: 8) {
                    if let originalIndex {
                        Toggle("", isOn: $book.chapters[originalIndex].included)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                    } else {
                        Color.clear.frame(width: 18, height: 18)
                    }
                    Text(String(format: "%02d", row.index))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(BinderTheme.gold)
                        .frame(width: 22, alignment: .trailing)
                    if let originalIndex {
                        TextField("Chapter title", text: $book.chapters[originalIndex].title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(book.chapters[originalIndex].included ? BinderTheme.ink : BinderTheme.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .help(book.chapters[originalIndex].audioInfo.summary)
                        ChapterPlayButton(chapter: book.chapters[originalIndex])
                            .layoutPriority(1)
                        durationLabel(book.chapters[originalIndex].duration, highlight: disagree)
                            .layoutPriority(1)
                    } else {
                        Text("—")
                            .foregroundStyle(BinderTheme.inkMuted)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 20, height: 14)
                        durationLabel(nil, highlight: false)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showOriginal && showBound {
                Rectangle()
                    .fill(BinderTheme.gold.opacity(0.28))
                    .frame(width: 1)
            }
            if showBound {
                HStack(spacing: 8) {
                    if !showOriginal {
                        Text(String(format: "%02d", row.index))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(BinderTheme.gold)
                            .frame(width: 22, alignment: .trailing)
                    }
                    if let bound = row.bound {
                        Text(bound.title)
                            .font(.system(size: 13))
                            .foregroundStyle(BinderTheme.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .help(bound.title)
                        ChapterPlayButton(chapter: bound)
                            .layoutPriority(1)
                        durationLabel(bound.duration, highlight: disagree)
                            .layoutPriority(1)
                    } else {
                        Text("—")
                            .foregroundStyle(BinderTheme.inkMuted)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 20, height: 14)
                        durationLabel(nil, highlight: false)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(BinderTheme.leather.opacity(0.06))
            }
        }
    }

    private func durationLabel(_ duration: TimeInterval?, highlight: Bool) -> some View {
        Text(duration.map(DurationFormat.string) ?? "—")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(highlight ? Color.red.opacity(0.85) : BinderTheme.inkMuted)
            .frame(width: 54, alignment: .trailing)
            .help(highlight ? "Duration does not match the other side" : "")
    }

    @ViewBuilder
    private func comparisonBanner(_ inspection: M4BInspection) -> some View {
        let summary = ChapterCompare.summary(
            original: book.chapters,
            bound: boundChapters,
            boundDuration: inspection.duration
        )
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    Label(
                        "Original \(summary.originalCount) ch · \(DurationFormat.string(summary.originalDuration))",
                        systemImage: "waveform"
                    )
                    Label(
                        ".m4b \(summary.boundCount) ch · \(DurationFormat.string(summary.boundDuration))",
                        systemImage: "headphones"
                    )
                }
                .lineLimit(1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Original  \(summary.originalCount) ch · \(DurationFormat.string(summary.originalDuration))")
                    Text(".m4b  \(summary.boundCount) ch · \(DurationFormat.string(summary.boundDuration))")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(BinderTheme.inkMuted)
            Text(summary.detail)
                .font(.system(size: 12))
                .foregroundStyle(summary.allMatch || book.chapters.isEmpty ? BinderTheme.inkMuted : Color.red.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cleanupControls(inspection: M4BInspection) -> some View {
        let files = M4BInspector.sourceFilesToRemove(from: book)
        let summary = ChapterCompare.summary(
            original: book.chapters,
            bound: boundChapters,
            boundDuration: inspection.duration
        )
        if !files.isEmpty, summary.allMatch {
            Button("Move \(files.count) original audio files to Trash") {
                confirmCleanup = true
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(BinderTheme.leather)
        }
    }

    private func setChaptersIncluded(_ included: Bool) {
        for i in book.chapters.indices {
            book.chapters[i].included = included
        }
    }

    private func inspect() async {
        guard let m4bURL else { return }
        inspecting = true
        cleanupError = nil
        let result = await M4BInspector.inspect(m4bURL)
        inspection = result
        boundChapters = M4BInspector.playableChapters(from: result)
        fileChapter = Chapter(
            url: result.url,
            index: 0,
            title: book.title,
            duration: result.duration,
            fileSize: result.fileSize
        )
        inspecting = false
    }

    private func performCleanup() {
        guard let inspection else { return }
        let files = M4BInspector.sourceFilesToRemove(from: book)
        do {
            for url in files {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            appState.applyCleanup(to: book.id, inspection: inspection)
            cleanupError = nil
        } catch {
            cleanupError = error.localizedDescription
        }
    }
}

struct SourceKindBadge: View {
    var title: String
    var emphasized: Bool

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(emphasized ? Color.white : BinderTheme.ink)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(emphasized ? BinderTheme.leather : BinderTheme.paperDeep)
            )
            .fixedSize(horizontal: true, vertical: true)
            .accessibilityLabel(title)
    }
}

struct ChapterPlayButton: View {
    var chapter: Chapter
    @Environment(AppState.self) private var appState

    var body: some View {
        let playing = appState.playback.isPlaying(chapter)
        Button {
            appState.playback.toggle(chapter)
        } label: {
            Image(systemName: playing ? "pause.circle.fill" : "play.circle")
                .font(.system(size: 14))
                .foregroundStyle(
                    appState.playback.playingID == chapter.id
                        ? BinderTheme.leather
                        : BinderTheme.ink
                )
        }
        .buttonStyle(.plain)
        .frame(width: 20, alignment: .center)
        .help(playing ? "Pause chapter" : "Play chapter")
        .accessibilityLabel(playing ? "Pause chapter" : "Play chapter")
        .disabled(appState.isBuilding)
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
