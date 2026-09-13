import Foundation

public struct LibraryNode: Identifiable, Hashable, Sendable {
    public var url: URL
    public var name: String
    public var bookCount: Int
    public var children: [LibraryNode]

    public var id: URL { url }

    public init(url: URL, name: String, bookCount: Int, children: [LibraryNode]) {
        self.url = url
        self.name = name
        self.bookCount = bookCount
        self.children = children
    }

    /// `nil` when this folder has no nested grouping folders, so OutlineGroup treats it as a leaf.
    public var nestedFolders: [LibraryNode]? {
        children.isEmpty ? nil : children
    }

    public var hasNestedFolders: Bool { !children.isEmpty }
}

public enum LibraryOutline {
    public static func build(root: URL, books: [Audiobook]) -> LibraryNode {
        let root = normalized(root)
        let builder = NodeBuilder(url: root, name: root.lastPathComponent)
        for book in books {
            let folder = normalized(book.folder)
            guard let relative = relativeComponents(from: root, to: folder) else { continue }
            let grouping = relative.dropLast()
            var current = builder
            current.bookCount += 1
            for component in grouping {
                current = current.child(named: component)
                current.bookCount += 1
            }
        }
        return builder.freeze()
    }

    public static func books(_ books: [Audiobook], under folder: URL) -> [Audiobook] {
        books.filter { book($0, isUnder: folder) }
    }

    public static func book(_ book: Audiobook, isUnder folder: URL) -> Bool {
        let folderPath = pathString(folder)
        let bookPath = pathString(book.folder)
        if bookPath == folderPath { return true }
        return bookPath.hasPrefix(folderPath + "/")
    }

    public static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        pathString(a) == pathString(b)
    }

    public static func folderURL(_ url: URL) -> URL {
        URL(fileURLWithPath: pathString(url), isDirectory: true)
    }

    static func normalized(_ url: URL) -> URL {
        folderURL(url)
    }

    static func pathString(_ url: URL) -> String {
        var path = url.standardizedFileURL.path
        if path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    static func relativeComponents(from root: URL, to folder: URL) -> [String]? {
        let rootPath = pathString(root)
        let folderPath = pathString(folder)
        if folderPath == rootPath { return [] }
        let prefix = rootPath + "/"
        guard folderPath.hasPrefix(prefix) else { return nil }
        return folderPath.dropFirst(prefix.count).split(separator: "/").map(String.init)
    }
}

private final class NodeBuilder {
    let url: URL
    let name: String
    var bookCount = 0
    var children: [String: NodeBuilder] = [:]

    init(url: URL, name: String) {
        self.url = url
        self.name = name
    }

    func child(named component: String) -> NodeBuilder {
        if let existing = children[component] { return existing }
        let next = NodeBuilder(
            url: url.appendingPathComponent(component, isDirectory: true),
            name: component
        )
        children[component] = next
        return next
    }

    func freeze() -> LibraryNode {
        let frozen = children.values.map { $0.freeze() }
        return LibraryNode(
            url: url,
            name: name,
            bookCount: bookCount,
            children: NaturalSort.sorted(frozen, key: { $0.name })
        )
    }
}
