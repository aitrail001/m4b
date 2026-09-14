import Foundation
import AudiobookBinderCore

@main
struct AudiobookBinderSelfTest {
    static func main() async {
        var failed = 0
        func expect(_ cond: Bool, _ message: String) {
            if cond {
                print("  ok  \(message)")
            } else {
                failed += 1
                print("  FAIL  \(message)")
            }
        }

        let booksRoot = URL(fileURLWithPath: NSString(string: "~/Documents/books").expandingTildeInPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: booksRoot.path) else {
            print("skip live library (no \(booksRoot.path))")
            Darwin.exit(0)
        }

        print("== Scan \(booksRoot.path) ==")
        do {
            let books = try await BookScanner().scan(root: booksRoot)
            for book in books {
                print("  BOOK \(book.title) | \(book.author) | \(book.chapterCount) ch")
                if book.isAlreadyBound {
                    expect(book.chapterCount == 0, "\(book.title) already bound has 0 chapters")
                    expect(!book.selected, "\(book.title) already bound is not selected")
                    expect(book.existingM4BURL != nil, "\(book.title) already bound has m4b")
                } else {
                    expect(book.chapterCount >= 1, "\(book.title) has chapters")
                }
                expect(!book.title.isEmpty, "title present")
            }
        } catch {
            expect(false, "scan error: \(error)")
        }

        Darwin.exit(failed == 0 ? 0 : 1)
    }
}
