# Audiobook Binder

A macOS app that turns a folder of chapter MP3s into an Apple Books audiobook (`.m4b`) with title, author, narrator, cover, and chapter marks.

## What it expects

Your books look like the library in `~/Documents/books`:

- **One book:** a folder of numbered MP3s, plus an optional cover `.jpg` and/or an `ebook/` folder.
- **A library:** a parent folder whose subfolders are books. Nested wrapper folders are found automatically.

It already understands the layouts in that library, including nested audio folders, Calibre `metadata.opf` files, ebook filenames like `Title - Author.epub`, and Chinese helper folders such as `不分章节` (those unchaptered files are skipped when numbered chapters exist).

Metadata is filled in this order: MP3 tags → OPF/EPUB → ebook filename → folder name. Chapter titles fall back to `Chapter 01`, `Chapter 02`, … when the MP3 titles are just the book name. You can edit everything in the UI before building.

## Download

- Site: [audiobook-binder.nwai.cc](https://audiobook-binder.nwai.cc) (also [audiobook-binder.pages.dev](https://audiobook-binder.pages.dev))
- DMG: [GitHub Releases](https://github.com/aitrail001/m4b/releases/latest) or `make dmg`

macOS 14+. First launch: if Gatekeeper warns, right-click the app and choose **Open**.

## Build and run

Requires macOS 14+ and Swift 6.

```bash
cd m4b
make run
```

That compiles a release build, packages `dist/AudiobookBinder.app`, and opens it.

```bash
make test     # XCTest + AudiobookBinderSelfTest
make app      # dist/AudiobookBinder.app
make dmg      # signed .app + dist/AudiobookBinder-VERSION.dmg
make release  # GitHub release with the DMG
```

## Use

1. Open a book folder, or a library folder (nested wrappers are fine). The last library reopens on launch. While scanning, the footer names the folder being checked.
2. When the library has nested folders, pick a level in the folder tree on the left to show only the books under it. Filter the list if you need to. Folders that already have an `.m4b` show as **Already an audiobook** and stay unselected.
3. Review title, author, narrator, cover, and chapter names. Uncheck chapters you want to skip; play a chapter to preview.
4. Choose bitrate (64 kbps is the audiobook default). Save the `.m4b` in the book folder, or uncheck that to write to `~/Music/Audiobooks` (or pick another folder).
5. Build the selected books, then Show in Finder, Open in Books, or **Verify** the `.m4b` (play the file or a chapter). If its duration matches the source, you can move the original MP3s to Trash.

You can also bind from the command line:

```bash
./dist/AudiobookBinder.app/Contents/MacOS/AudiobookBinder --scan ~/Documents/books
./dist/AudiobookBinder.app/Contents/MacOS/AudiobookBinder --bind ~/Documents/books/Antifragile\ Things\ That\ Gain\ from\ Disorder\ \(Unabridged\) --overwrite
```

Drop the finished `.m4b` onto Books (or double-click it). Apple marks the file as an audiobook (`stik=2`) with a chapter track.
