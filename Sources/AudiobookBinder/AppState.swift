import AppKit
import Foundation
import Observation
import AudiobookBinderCore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppState {
    var books: [Audiobook] = []
    var selectedID: Audiobook.ID?
    var libraryFolder: URL?
    var settings = ExportSettings()
    var isScanning = false
    var isBuilding = false
    var status: String = "Choose a books folder to begin."
    var lastError: String?
    var build: BuildProgress?
    var finishedURLs: [URL] = []

    private var buildTask: Task<Void, Never>?

    var selectedBook: Audiobook? {
        books.first(where: { $0.id == selectedID })
    }

    var selectedCount: Int { books.filter(\.selected).count }

    var selectedBookBindingIndex: Int? {
        books.firstIndex(where: { $0.id == selectedID })
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Select a book folder, or a library folder that contains one folder per book."
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
        libraryFolder = url
        isScanning = true
        lastError = nil
        status = "Scanning \(url.lastPathComponent)…"
        Task {
            do {
                let found = try await BookScanner().scan(root: url)
                books = found
                selectedID = found.first?.id
                status = found.count == 1
                    ? "Found 1 book — \(found[0].chapterCount) chapters."
                    : "Found \(found.count) books."
            } catch {
                lastError = error.localizedDescription
                status = error.localizedDescription
                books = []
            }
            isScanning = false
        }
    }

    func selectAll(_ on: Bool) {
        for i in books.indices { books[i].selected = on }
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
        let queue = books.filter(\.selected)
        guard !queue.isEmpty else {
            status = "Select at least one book."
            return
        }
        isBuilding = true
        lastError = nil
        finishedURLs = []
        status = "Building \(queue.count) audiobook\(queue.count == 1 ? "" : "s")…"
        let snapshot = books
        let settings = settings
        buildTask = Task {
            do {
                let urls = try await M4BExporter(bitrate: settings.bitrate).exportAll(
                    books: snapshot,
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
}
