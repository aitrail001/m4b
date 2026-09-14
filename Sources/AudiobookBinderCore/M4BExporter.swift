import AVFoundation
import Foundation

public struct M4BExporter: Sendable {
    public var bitrate: Int
    public var sampleRate: Double

    public init(bitrate: Int = 64_000, sampleRate: Double = 44_100) {
        self.bitrate = bitrate
        self.sampleRate = sampleRate
    }

    public static func chaptersReadyForExport(_ chapters: [Chapter]) -> [Chapter] {
        chapters.filter(\.included)
    }

    /// Included chapters that exist as readable regular files.
    /// Throws `noAudioFiles` when every included file is missing (or none are included).
    /// Throws `missingChapters` when some included files are missing.
    /// Excluded chapters are ignored even if their files are absent.
    public static func chaptersForExport(_ chapters: [Chapter], folder: URL) throws -> [Chapter] {
        let included = chaptersReadyForExport(chapters)
        let missing = included.compactMap { isUsableExportSource($0.url) ? nil : $0.url }
        if included.isEmpty || missing.count == included.count {
            throw BinderError.noAudioFiles(folder)
        }
        if !missing.isEmpty {
            throw BinderError.missingChapters(missing)
        }
        return included
    }

    public func export(
        book: Audiobook,
        to outputURL: URL,
        overwrite: Bool,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        try Self.preflightDestination(outputURL, book: book, overwrite: overwrite)
        _ = try Self.chaptersForExport(book.chapters, folder: book.folder)

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).m4a")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        progress?(0.01, "Preparing \(book.title)")

        let chapters = try Self.chaptersForExport(book.chapters, folder: book.folder)
        let marks = try await encode(chapters: chapters, to: tempURL, progress: progress)

        progress?(0.92, "Writing audiobook tags and chapters")
        try MP4AudiobookTagger.apply(
            to: tempURL,
            tags: AudiobookTags(
                title: book.title,
                author: book.author,
                album: book.title,
                narrator: book.narrator,
                genre: book.genre.isEmpty ? "Audiobook" : book.genre,
                comment: book.bookDescription,
                coverJPEG: book.coverJPEG
            ),
            chapters: marks
        )

        guard FileManager.default.fileExists(atPath: tempURL.path) else {
            throw BinderError.exportFailed("Encode produced no output")
        }

        try Self.publish(staging: tempURL, to: outputURL, overwrite: overwrite)
        progress?(1.0, "Finished \(book.title)")
    }

    public static func plan(books: [Audiobook], settings: ExportSettings) -> [UUID: URL] {
        settings.plannedOutputs(for: books.filter(\.selected))
    }

    public func exportAll(
        books: [Audiobook],
        settings: ExportSettings,
        progress: (@Sendable (JobProgress) -> Void)? = nil
    ) async throws -> [BookExportResult] {
        let selected = books.filter(\.selected)
        let destinations = settings.plannedOutputs(for: selected)
        var results: [BookExportResult] = []
        for (idx, book) in selected.enumerated() {
            try Task.checkCancellation()
            let dest = destinations[book.id] ?? settings.outputURL(for: book)
            let existed = Self.existingRegularFile(dest)
            if existed && !settings.overwrite {
                results.append(BookExportResult(bookID: book.id, url: dest, outcome: .skippedExisting))
                continue
            }
            do {
                try await export(book: book, to: dest, overwrite: settings.overwrite) { fraction, detail in
                    progress?(
                        JobProgress(
                            label: book.title,
                            index: idx + 1,
                            count: selected.count,
                            fraction: (Double(idx) + fraction) / Double(selected.count),
                            detail: detail
                        )
                    )
                }
                results.append(
                    BookExportResult(
                        bookID: book.id,
                        url: dest,
                        outcome: existed ? .replaced : .created
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch BinderError.cancelled {
                throw BinderError.cancelled
            } catch let error as BinderError {
                if case .outputExists = error {
                    results.append(BookExportResult(bookID: book.id, url: dest, outcome: .skippedExisting))
                } else {
                    results.append(
                        BookExportResult(
                            bookID: book.id,
                            url: dest,
                            outcome: .failed(error.localizedDescription)
                        )
                    )
                }
            } catch {
                results.append(
                    BookExportResult(
                        bookID: book.id,
                        url: dest,
                        outcome: .failed(error.localizedDescription)
                    )
                )
            }
        }
        return results
    }

    private func encode(
        chapters: [Chapter],
        to url: URL,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws -> [ChapterMark] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let marks = try self.encodeBlocking(chapters: chapters, to: url, progress: progress)
                    continuation.resume(returning: marks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func encodeBlocking(
        chapters: [Chapter],
        to url: URL,
        progress: (@Sendable (Double, String) -> Void)?
    ) throws -> [ChapterMark] {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = avMetadata(for: chapters)

        let first = chapters[0].url
        let asbd = AudioMetadata.streamDescription(of: first)
        let channels = max(1, min(2, Int(asbd?.mChannelsPerFrame ?? 1)))
        let rate = asbd?.mSampleRate ?? sampleRate
        let encodeRate = rate >= 48_000 ? 48_000.0 : 44_100.0

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: encodeRate,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: bitrate
        ]

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw BinderError.exportFailed("Cannot add AAC audio input")
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw BinderError.exportFailed(writer.error?.localizedDescription ?? "Failed to start writing")
        }
        writer.startSession(atSourceTime: .zero)

        let pcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: encodeRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        var marks: [ChapterMark] = []
        var cursor = CMTime.zero
        let total = max(chapters.reduce(0.0) { $0 + $1.duration }, 1)

        for (index, chapter) in chapters.enumerated() {
            if Task.isCancelled {
                writer.cancelWriting()
                throw BinderError.cancelled
            }
            progress?(
                0.02 + 0.88 * (cursor.seconds / total),
                "Encoding chapter \(index + 1) of \(chapters.count)"
            )

            guard Self.isUsableExportSource(chapter.url) else {
                writer.cancelWriting()
                throw BinderError.missingChapters([chapter.url])
            }

            let asset = AVURLAsset(url: chapter.url, options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ])
            let start = cursor
            cursor = try append(asset: asset, to: input, writer: writer, pcmSettings: pcmSettings, at: cursor, timescale: Int32(encodeRate))
            var duration = CMTimeSubtract(cursor, start).seconds
            if duration <= 0 { duration = max(chapter.duration, 0.001) }
            marks.append(ChapterMark(start: start.seconds, duration: duration, title: chapter.title))
        }

        let finishGroup = DispatchGroup()
        finishGroup.enter()
        input.markAsFinished()
        var finishError: Error?
        writer.finishWriting {
            finishError = writer.error
            finishGroup.leave()
        }
        finishGroup.wait()
        if writer.status != .completed {
            throw BinderError.exportFailed(finishError?.localizedDescription ?? "Encode did not complete")
        }
        return marks
    }

    private func append(
        asset: AVURLAsset,
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        pcmSettings: [String: Any],
        at start: CMTime,
        timescale: Int32
    ) throws -> CMTime {
        let loaded = DispatchSemaphore(value: 0)
        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
            loaded.signal()
        }
        loaded.wait()
        var tracksError: NSError?
        guard asset.statusOfValue(forKey: "tracks", error: &tracksError) == .loaded,
              let track = asset.tracks(withMediaType: .audio).first else {
            throw BinderError.exportFailed(tracksError?.localizedDescription ?? "No audio track in \(asset.url.lastPathComponent)")
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw BinderError.exportFailed("Cannot read \(asset.url.lastPathComponent): \(error.localizedDescription)")
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw BinderError.exportFailed("Cannot add reader output")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw BinderError.exportFailed(reader.error?.localizedDescription ?? "Reader failed")
        }

        var cursor = start

        while reader.status == .reading {
            if !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            guard let sample = output.copyNextSampleBuffer() else { break }
            let frames = max(1, CMSampleBufferGetNumSamples(sample))
            let duration = CMTime(value: Int64(frames), timescale: timescale)
            let timed = retimed(sample, pts: cursor, duration: duration) ?? sample
            if !input.append(timed) {
                let detail = writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Failed to append audio"
                throw BinderError.exportFailed(detail)
            }
            cursor = CMTimeAdd(cursor, duration)
        }

        if reader.status == .failed {
            throw BinderError.exportFailed(reader.error?.localizedDescription ?? "Reader failed")
        }
        return cursor
    }

    private func retimed(_ sample: CMSampleBuffer, pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        var copy: CMSampleBuffer?
        var info = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &info,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }

    private func avMetadata(for chapters: [Chapter]) -> [AVMetadataItem] {
        _ = chapters
        return []
    }
}

extension M4BExporter {
    static func preflightDestination(_ dest: URL, book: Audiobook, overwrite: Bool) throws {
        for chapter in book.chapters where chapter.included {
            if isSameFileURL(chapter.url, dest) {
                throw BinderError.exportFailed(
                    "Destination is the same as a source chapter: \(dest.lastPathComponent)"
                )
            }
        }

        let kind = destinationKind(dest)
        if kind.isDirectory {
            throw BinderError.exportFailed("Destination is a directory: \(dest.path)")
        }
        if kind.exists && !overwrite {
            throw BinderError.outputExists(dest)
        }
    }

    /// Publishes a ready staging file. Never delete-then-move the previous dest.
    static func publish(staging: URL, to dest: URL, overwrite: Bool) throws {
        let kind = destinationKind(dest)
        if kind.isDirectory {
            throw BinderError.exportFailed("Destination is a directory: \(dest.path)")
        }
        if kind.exists && !overwrite {
            throw BinderError.outputExists(dest)
        }

        do {
            if kind.exists {
                var resultingItemURL: NSURL?
                try FileManager.default.replaceItem(
                    at: dest,
                    withItemAt: staging,
                    backupItemName: nil,
                    options: [],
                    resultingItemURL: &resultingItemURL
                )
            } else {
                try FileManager.default.moveItem(at: staging, to: dest)
            }
        } catch {
            if overwrite && !FileManager.default.fileExists(atPath: dest.path) {
                do {
                    try FileManager.default.moveItem(at: staging, to: dest)
                    return
                } catch {
                    throw BinderError.exportFailed(error.localizedDescription)
                }
            }
            if !overwrite && FileManager.default.fileExists(atPath: dest.path) {
                throw BinderError.outputExists(dest)
            }
            throw BinderError.exportFailed(error.localizedDescription)
        }
    }

    private static func isUsableExportSource(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isReadableFile(atPath: url.path)
    }

    private static func existingRegularFile(_ url: URL) -> Bool {
        let kind = destinationKind(url)
        return kind.exists && !kind.isDirectory
    }

    private static func destinationKind(_ url: URL) -> (exists: Bool, isDirectory: Bool) {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return (exists, exists && isDirectory.boolValue)
    }

    private static func isSameFileURL(_ a: URL, _ b: URL) -> Bool {
        if let aID = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           let bID = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           aID.isEqual(bID) {
            return true
        }
        return a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
