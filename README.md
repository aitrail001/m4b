# Audiobook Binder

A macOS app that turns a folder of chapter MP3s into an Apple Books audiobook (`.m4b`) with title, author, narrator, cover, and chapter marks.

## What it expects

Your books look like the library in `~/Documents/books`:

- **One book:** a folder of numbered MP3s, plus an optional cover `.jpg` and/or an `ebook/` folder.
- **A library:** a parent folder whose subfolders are books. Nested wrapper folders are found automatically.

It already understands the layouts in that library, including nested audio folders, Calibre `metadata.opf` files, ebook filenames like `Title - Author.epub`, and Chinese helper folders such as `不分章节` (those unchaptered files are skipped when numbered chapters exist).

Metadata is filled in this order: MP3 tags → OPF/EPUB → ebook filename → folder name. Chapter titles fall back to `Chapter 01`, `Chapter 02`, … when the MP3 titles are just the book name. You can edit everything in the UI before building.

## Build and run

Requires macOS 14+ and Swift 6.

```bash
cd m4b
make run
```

That compiles a release build, packages `dist/AudiobookBinder.app`, and opens it.

```bash
make test    # scan ~/Documents/books and encode a short smoke .m4b
make app     # dist/AudiobookBinder.app
```

## Use

1. Open a book folder, or the parent folder that contains one folder per book.
2. Review title, author, narrator, cover, and chapter names.
3. Choose bitrate (64 kbps is the audiobook default). Save the `.m4b` in the book folder, or uncheck that to write to `~/Music/Audiobooks` (or pick another folder).
4. Build the selected books.

You can also bind from the command line:

```bash
./dist/AudiobookBinder.app/Contents/MacOS/AudiobookBinder --scan ~/Documents/books
./dist/AudiobookBinder.app/Contents/MacOS/AudiobookBinder --bind ~/Documents/books/Antifragile\ Things\ That\ Gain\ from\ Disorder\ \(Unabridged\) --overwrite
```

Drop the finished `.m4b` onto Books (or double-click it). Apple marks the file as an audiobook (`stik=2`) with a chapter track.
