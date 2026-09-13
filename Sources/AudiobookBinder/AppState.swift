import AppKit
import Foundation
import Observation
import AudiobookBinderCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppState {
    let playback = ChapterPlayback()
    var books: [Audiobook] = []
    var bookQuery: String = ""
    var selectedID: Audiobook.ID? {
        didSet {
            if selectedID != oldValue {
                playback.stop()
            }
        }
    }
    var selectedFolderURL: URL? {
        didSet {
            guard selectedFolderURL != oldValue, let folder = selectedFolderURL else { return }
            let visible = LibraryOutline.books(books, under: folder)
            if let selectedID, visible.contains(where: { $0.id == selectedID }) { return }
            selectedID = visible.first?.id
        }
    }
    var libraryFolder: URL?
    var settings = ExportSettings() {
        didSet { Self.persistSettings(settings) }
    }
    var isScanning = false
    var isBuilding = false
    var status: String = "Choose a books folder to begin."
    var lastError: String?
    var build: BuildProgress?
    var finishedURLs: [URL] = []

    private var buildTask: Task<Void, Never>?

    init() {
        settings = Self.loadSettings()
        if let url = LibraryBookmark.resolvedDirectory(
            path: UserDefaults.standard.string(forKey: "audiobookBinder.libraryFolder")
        ) {
            scan(url)
        }
    }

    var selectedBook: Audiobook? {
        books.first(where: { $0.id == selectedID })
    }

    var selectedCount: Int { books.filter(\.selected).count }

    var folderOutline: LibraryNode? {
        guard let libraryFolder, !books.isEmpty else { return nil }
        return LibraryOutline.build(root: libraryFolder, books: books)
    }

    var showsFolderTree: Bool {
        folderOutline?.hasNestedFolders == true
    }

    func isVisible(_ book: Audiobook) -> Bool {
        book.matches(query: bookQuery) && isInSelectedFolder(book)
    }

    func isInSelectedFolder(_ book: Audiobook) -> Bool {
        guard let folder = selectedFolderURL ?? libraryFolder else { return true }
        return LibraryOutline.book(book, isUnder: folder)
    }

    var selectedBookBindingIndex: Int? {
        books.firstIndex(where: { $0.id == selectedID })
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Select a book folder or a library folder. Nested wrappers are scanned automatically."
        panel.prompt = "Scan"
        panel.directoryURL = libraryFolder ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/books")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scan(url)
    }

    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use"
        panel.message = "Save finished .m4b files here."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.outputDirectory = url
        settings.writeNextToBook = false
    }

    func scan(_ url: URL) {
        playback.stop()
        bookQuery = ""
        let folder = LibraryOutline.folderURL(url)
        libraryFolder = folder
        UserDefaults.standard.set(folder.path, forKey: "audiobookBinder.libraryFolder")
        isScanning = true
        lastError = nil
        status = "Scanning \(url.lastPathComponent)…"
        Task {
            do {
                let found = try await BookScanner().scan(root: url)
                books = found
                selectedID = found.first?.id
                selectedFolderURL = folder
                let boundCount = found.filter(\.isAlreadyBound).count
                if boundCount > 0 {
                    status = "Found \(found.count) book\(found.count == 1 ? "" : "s") (\(boundCount) already bound)."
                } else {
                    status = found.count == 1
                        ? "Found 1 book — \(found[0].chapterCount) chapters."
                        : "Found \(found.count) books."
                }
            } catch {
                lastError = error.localizedDescription
                status = error.localizedDescription
                books = []
                selectedFolderURL = folder
            }
            isScanning = false
        }
    }

    func selectAll(_ on: Bool) {
        for i in books.indices {
            guard isVisible(books[i]) else { continue }
            if on, books[i].isAlreadyBound { continue }
            books[i].selected = on
        }
    }

    func chooseCover() {
        guard let idx = selectedBookBindingIndex else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .webP, .tiff]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        books[idx].coverURL = url
        books[idx].coverJPEG = CoverJPEG.loadAndNormalize(from: url)
    }

    func buildSelected() {
        guard !isBuilding else { return }
        let selectedBooks = books.filter { $0.selected && !$0.isAlreadyBound }
        let queue = selectedBooks.filter { !$0.includedChapters.isEmpty }
        guard !queue.isEmpty else {
            status = selectedBooks.isEmpty
                ? "Select at least one book."
                : "Select at least one chapter."
            return
        }
        playback.stop()
        isBuilding = true
        lastError = nil
        finishedURLs = []
        status = "Building \(queue.count) audiobook\(queue.count == 1 ? "" : "s")…"
        let settings = settings
        buildTask = Task {
            do {
                let urls = try await M4BExporter(bitrate: settings.bitrate).exportAll(
                    books: queue,
                    settings: settings
                ) { [weak self] progress in
                    Task { @MainActor in
                        self?.build = progress
                        self?.status = progress.detail
                    }
                }
                finishedURLs = urls
                status = "Created \(urls.count) audiobook\(urls.count == 1 ? "" : "s")."
            } catch is CancellationError {
                status = "Cancelled."
            } catch {
                lastError = error.localizedDescription
                status = error.localizedDescription
            }
            isBuilding = false
            build = nil
        }
    }

    func cancelBuild() {
        buildTask?.cancel()
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func revealLibrary() {
        if let libraryFolder {
            NSWorkspace.shared.open(libraryFolder)
        }
    }

    func openInBooks(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    private static func loadSettings() -> ExportSettings {
        let defaults = UserDefaults.standard
        var loaded = ExportSettings()
        if defaults.object(forKey: "audiobookBinder.writeNextToBook") != nil {
            loaded.writeNextToBook = defaults.bool(forKey: "audiobookBinder.writeNextToBook")
        }
        if defaults.object(forKey: "audiobookBinder.overwrite") != nil {
            loaded.overwrite = defaults.bool(forKey: "audiobookBinder.overwrite")
        }
        let bitrate = defaults.integer(forKey: "audiobookBinder.bitrate")
        if defaults.object(forKey: "audiobookBinder.bitrate") != nil, bitrate > 0 {
            loaded.bitrate = bitrate
        }
        if let path = defaults.string(forKey: "audiobookBinder.outputDirectory"), !path.isEmpty {
            loaded.outputDirectory = URL(fileURLWithPath: path, isDirectory: true)
        }
        return loaded
    }

    private static func persistSettings(_ settings: ExportSettings) {
        let defaults = UserDefaults.standard
        defaults.set(settings.writeNextToBook, forKey: "audiobookBinder.writeNextToBook")
        defaults.set(settings.overwrite, forKey: "audiobookBinder.overwrite")
        defaults.set(settings.bitrate, forKey: "audiobookBinder.bitrate")
        if let path = settings.outputDirectory?.path {
            defaults.set(path, forKey: "audiobookBinder.outputDirectory")
        } else {
            defaults.removeObject(forKey: "audiobookBinder.outputDirectory")
        }
    }
}
