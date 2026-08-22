import AppKit
import SwiftUI
import AudiobookBinderCore

@main
struct AudiobookBinderMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print(Self.usage)
            return
        }
        if args.contains("--bind") || args.contains("--scan") {
            CLI.run(arguments: args)
            return
        }
        BinderApp.main()
    }

    static let usage = """
    Audiobook Binder

    GUI:
      open AudiobookBinder.app

    CLI:
      AudiobookBinder --scan <folder>
      AudiobookBinder --bind <folder> [--output <dir>] [--bitrate 64] [--overwrite]
    """
}

struct BinderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") { appState.openFolder() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Library") {
                Button("Select All") { appState.selectAll(true) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Select None") { appState.selectAll(false) }
                Divider()
                Button("Build Selected Audiobooks") { appState.buildSelected() }
                    .keyboardShortcut("b", modifiers: .command)
                    .disabled(appState.books.isEmpty || appState.isBuilding)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ sender: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .binderOpenURLs, object: urls)
    }
}

extension Notification.Name {
    static let binderOpenURLs = Notification.Name("audiobookBinder.openURLs")
}

enum CLI {
    static func run(arguments: [String]) {
        let scanIdx = arguments.firstIndex(of: "--scan")
        let bindIdx = arguments.firstIndex(of: "--bind")
        var folder: String?
        if let scanIdx, scanIdx + 1 < arguments.count { folder = arguments[scanIdx + 1] }
        if let bindIdx, bindIdx + 1 < arguments.count { folder = arguments[bindIdx + 1] }
        guard let folder else {
            fputs("Missing folder path.\n", stderr)
            Darwin.exit(2)
        }

        var bitrate = 64_000
        if let i = arguments.firstIndex(of: "--bitrate"), i + 1 < arguments.count {
            bitrate = (Int(arguments[i + 1]) ?? 64) * 1000
        }
        var output: URL?
        if let i = arguments.firstIndex(of: "--output"), i + 1 < arguments.count {
            output = URL(fileURLWithPath: arguments[i + 1], isDirectory: true)
        }
        let overwrite = arguments.contains("--overwrite")
        let root = URL(fileURLWithPath: folder, isDirectory: true)

        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let books = try await BookScanner().scan(root: root)
                if arguments.contains("--scan") {
                    for book in books {
                        print("\(book.title)\t\(book.author)\t\(book.chapterCount) chapters\t\(DurationFormat.string(book.totalDuration))")
                    }
                    Darwin.exit(0)
                }
                let settings = ExportSettings(
                    outputDirectory: output,
                    bitrate: bitrate,
                    overwrite: overwrite,
                    writeNextToBook: output == nil
                )
                let urls = try await M4BExporter(bitrate: bitrate).exportAll(books: books, settings: settings) { progress in
                    fputs(
                        String(format: "[%d/%d] %.0f%% %@\n", progress.bookIndex, progress.bookCount, progress.fraction * 100, progress.detail),
                        stderr
                    )
                }
                for url in urls { print(url.path) }
                Darwin.exit(0)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                Darwin.exit(1)
            }
            sem.signal()
        }
        sem.wait()
    }
}
