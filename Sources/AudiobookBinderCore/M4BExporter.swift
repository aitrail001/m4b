import AVFoundation
import Darwin
import Foundation

public struct M4BExporter: Sendable {
    public var bitrate: Int
    public var sampleRate: Double
    /// Test seam: runs after source capture and before snapshot/hash-verify.
    package var afterSourceCapture: (@Sendable () -> Void)?
    /// Test seam: runs after successful publish, before dest hash / provenance.
    package var afterPublish: (@Sendable () -> Void)?
    /// Test seam: runs after dest-absent is recorded and before identity capture.
    package var afterPreflight: (@Sendable () -> Void)?
    /// Test seam: runs after the first exportAll existence/owns check.
    package var afterDestinationCheck: (@Sendable () -> Void)?
    /// Test seam: runs after the last exportAll skip check and before export.
    package var beforeExport: (@Sendable () -> Void)?
    /// Test seam: after dest identity is confirmed and before the dest is moved aside.
    nonisolated(unsafe) package static var testingBeforeReplaceItem: (() -> Void)?
    /// Test seam: after the dest has been moved to the backup path.
    nonisolated(unsafe) package static var testingAfterMoveDestAside: (() -> Void)?
    /// Test seam: after staging is published and before the backup inode is unlinked.
    nonisolated(unsafe) package static var testingBeforeRemoveBackup: ((_ backup: URL) -> Void)?
    /// Test seam: make `trashHeldBackup` fail after a successful publish.
    nonisolated(unsafe) package static var testingTrashHeldBackupFails = false

    public init(bitrate: Int = 64_000, sampleRate: Double = 44_100) {
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.afterSourceCapture = nil
        self.afterPublish = nil
        self.afterPreflight = nil
        self.afterDestinationCheck = nil
        self.beforeExport = nil
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
        destWasAbsent: Bool? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        try await exportPrepared(
            book: book,
            to: outputURL,
            overwrite: overwrite,
            destWasAbsent: destWasAbsent,
            expectedOwnedIdentity: nil,
            progress: progress
        )
    }

    private func exportPrepared(
        book: Audiobook,
        to outputURL: URL,
        overwrite: Bool,
        destWasAbsent: Bool?,
        expectedOwnedIdentity: FileIdentity?,
        progress: (@Sendable (Double, String) -> Void)?
    ) async throws {
        let destWasAbsent = destWasAbsent ?? !Self.existingRegularFile(outputURL)
        let ownedIdentity = expectedOwnedIdentity ?? (
            destWasAbsent
                ? nil
                : FileIdentity.read(from: outputURL).flatMap { identity in
                    identity.isDirectory ? nil : identity
                }
        )
        try Self.preflightDestination(outputURL, book: book, overwrite: overwrite)
        _ = try Self.chaptersForExport(book.chapters, folder: book.folder)
        afterPreflight?()

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let expectedIdentity = try Self.expectedDestinationIdentity(
            dest: outputURL,
            book: book,
            destWasAbsent: destWasAbsent,
            ownedIdentity: ownedIdentity
        )

        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).m4a")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        let cancellation = EncodeCancellation()
        try await withTaskCancellationHandler {
            progress?(0.01, "Preparing \(book.title)")

            let chapters = try Self.chaptersForExport(book.chapters, folder: book.folder)
            let captured = try SourceAssociation.capture(
                chapters.map(\.url),
                dest: outputURL,
                cancellation: cancellation
            )
            guard !captured.isEmpty else {
                throw BinderError.exportFailed("Cannot capture source provenance")
            }
            try SourceAssociation.validateForExport(captured: captured, dest: outputURL)
            afterSourceCapture?()
            let snapshots = try SourceAssociation.stageEncodeSnapshots(
                captured,
                cancellation: cancellation
            )
            defer { SourceAssociation.removeEncodeSnapshots(at: snapshots.directory) }
            let encodeChapters = Self.chaptersForEncode(chapters, snapshots: snapshots.remap)
            let marks = try await encode(
                chapters: encodeChapters,
                to: tempURL,
                progress: progress,
                cancellation: cancellation
            )
            try cancellation.checkCancelled()

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
                chapters: marks,
                cancellation: cancellation
            )

            guard FileManager.default.fileExists(atPath: tempURL.path) else {
                throw BinderError.exportFailed("Encode produced no output")
            }

            try cancellation.checkCancelled()
            guard let stagingDigest = try SourceAssociation.sha256Hex(
                of: tempURL,
                cancellation: cancellation
            ), !stagingDigest.isEmpty else {
                throw BinderError.exportFailed("Could not hash encoded output")
            }
            let backupWarning = try Self.publish(
                staging: tempURL,
                to: outputURL,
                overwrite: overwrite,
                expectedIdentity: expectedIdentity
            )
            afterPublish?()
            try Self.finalizePublishedOutput(
                dest: outputURL,
                captured: captured,
                stagingDigest: stagingDigest,
                inBookFolder: book.folder
            )
            if let backupWarning {
                throw BinderError.publishedUnverified(backupWarning)
            }
            progress?(1.0, "Finished \(book.title)")
        } onCancel: {
            cancellation.cancel()
        }
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
            let dest = destinations[book.id] ?? settings.outputURL(for: book)
            if Task.isCancelled {
                Self.appendCancelled(
                    selected[idx...],
                    destinations: destinations,
                    settings: settings,
                    into: &results
                )
                return results
            }
            if Self.shouldSkipExistingDestination(dest, book: book, settings: settings) {
                results.append(BookExportResult(bookID: book.id, url: dest, outcome: .skippedExisting))
                continue
            }
            afterDestinationCheck?()
            if Self.shouldSkipExistingDestination(dest, book: book, settings: settings) {
                results.append(BookExportResult(bookID: book.id, url: dest, outcome: .skippedExisting))
                continue
            }
            let existed = Self.existingRegularFile(dest)
            let ownedIdentity = existed
                ? Self.validatedOwnedDestinationIdentity(dest, book: book, settings: settings)
                : nil
            if existed, ownedIdentity == nil {
                results.append(BookExportResult(bookID: book.id, url: dest, outcome: .skippedExisting))
                continue
            }
            beforeExport?()
            do {
                try await exportPrepared(
                    book: book,
                    to: dest,
                    overwrite: settings.overwrite,
                    destWasAbsent: !existed,
                    expectedOwnedIdentity: ownedIdentity
                ) { fraction, detail in
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
                Self.appendCancelled(
                    selected[idx...],
                    destinations: destinations,
                    settings: settings,
                    into: &results
                )
                return results
            } catch BinderError.cancelled {
                Self.appendCancelled(
                    selected[idx...],
                    destinations: destinations,
                    settings: settings,
                    into: &results
                )
                return results
            } catch let error as BinderError {
                if case .outputExists = error {
                    results.append(BookExportResult(bookID: book.id, url: dest, outcome: .skippedExisting))
                } else if case .publishedUnverified(let warning) = error {
                    results.append(
                        BookExportResult(
                            bookID: book.id,
                            url: dest,
                            outcome: .publishedUnverified(replaced: existed, warning: warning)
                        )
                    )
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
        progress: (@Sendable (Double, String) -> Void)?,
        cancellation: EncodeCancellation
    ) async throws -> [ChapterMark] {
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let marks = try self.encodeBlocking(
                            chapters: chapters,
                            to: url,
                            progress: progress,
                            cancellation: cancellation
                        )
                        try cancellation.checkCancelled()
                        continuation.resume(returning: marks)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func encodeBlocking(
        chapters: [Chapter],
        to url: URL,
        progress: (@Sendable (Double, String) -> Void)?,
        cancellation: EncodeCancellation
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

        do {
            return try encodeAfterWriterStarted(
                chapters: chapters,
                writer: writer,
                input: input,
                encodeRate: encodeRate,
                channels: channels,
                progress: progress,
                cancellation: cancellation
            )
        } catch {
            Self.cancelIfWriting(writer)
            throw error
        }
    }

    private func encodeAfterWriterStarted(
        chapters: [Chapter],
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        encodeRate: Double,
        channels: Int,
        progress: (@Sendable (Double, String) -> Void)?,
        cancellation: EncodeCancellation
    ) throws -> [ChapterMark] {
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
            try Self.throwIfCancelled(cancellation, writer: writer)
            progress?(
                0.02 + 0.88 * (cursor.seconds / total),
                "Encoding chapter \(index + 1) of \(chapters.count)"
            )

            guard Self.isUsableExportSource(chapter.url) else {
                throw BinderError.missingChapters([chapter.url])
            }

            let asset = AVURLAsset(url: chapter.url, options: [
                AVURLAssetPreferPreciseDurationAndTimingKey: true
            ])
            let start = cursor
            cursor = try append(
                asset: asset,
                to: input,
                writer: writer,
                pcmSettings: pcmSettings,
                at: cursor,
                timescale: Int32(encodeRate),
                cancellation: cancellation
            )
            var duration = CMTimeSubtract(cursor, start).seconds
            if duration <= 0 { duration = max(chapter.duration, 0.001) }
            marks.append(ChapterMark(start: start.seconds, duration: duration, title: chapter.title))
        }

        try Self.throwIfCancelled(cancellation, writer: writer)

        let finishGroup = DispatchGroup()
        finishGroup.enter()
        input.markAsFinished()
        writer.finishWriting {
            finishGroup.leave()
        }
        guard try Self.wait(finishGroup, timeout: Self.finishWritingTimeout, cancellation: cancellation) else {
            Self.cancelIfWriting(writer)
            throw BinderError.exportFailed("Timed out waiting for encode to finish")
        }
        if writer.status != .completed {
            throw BinderError.exportFailed(writer.error?.localizedDescription ?? "Encode did not complete")
        }
        return marks
    }

    private func append(
        asset: AVURLAsset,
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        pcmSettings: [String: Any],
        at start: CMTime,
        timescale: Int32,
        cancellation: EncodeCancellation
    ) throws -> CMTime {
        let track = try Self.loadAudioTrack(from: asset, cancellation: cancellation)

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
        var readyWaitStarted: Date?

        while reader.status == .reading {
            try Self.throwIfCancelled(cancellation, writer: writer)
            if writer.status == .failed || writer.status == .cancelled {
                throw BinderError.exportFailed(
                    writer.error?.localizedDescription
                        ?? (writer.status == .cancelled ? "Writer cancelled" : "Writer failed")
                )
            }
            if !input.isReadyForMoreMediaData {
                if readyWaitStarted == nil {
                    readyWaitStarted = Date()
                }
                if let readyWaitStarted, Date().timeIntervalSince(readyWaitStarted) >= Self.writerReadyTimeout {
                    throw BinderError.exportFailed("Writer stalled waiting for media data")
                }
                Thread.sleep(forTimeInterval: 0.002)
                continue
            }
            readyWaitStarted = nil
            guard let sample = output.copyNextSampleBuffer() else { break }
            let frames = CMSampleBufferGetNumSamples(sample)
            let timing = Self.pcmTiming(frames: frames, timescale: timescale)
            let timed = try Self.retimed(sample, pts: cursor, sampleDuration: timing.sampleDuration)
            if !input.append(timed) {
                let detail = writer.error?.localizedDescription ?? reader.error?.localizedDescription ?? "Failed to append audio"
                throw BinderError.exportFailed(detail)
            }
            cursor = CMTimeAdd(cursor, timing.bufferAdvance)
        }

        if reader.status == .failed {
            throw BinderError.exportFailed(reader.error?.localizedDescription ?? "Reader failed")
        }
        return cursor
    }

    /// Per-sample duration is one frame at `timescale`. Cursor advance is N frames.
    package static func pcmTiming(
        frames: Int,
        timescale: Int32
    ) -> (sampleDuration: CMTime, bufferAdvance: CMTime) {
        let count = Int64(max(frames, 1))
        return (
            sampleDuration: CMTime(value: 1, timescale: timescale),
            bufferAdvance: CMTime(value: count, timescale: timescale)
        )
    }

    /// Copies `sample` onto a continuous encode timeline. Throws if retiming fails
    /// so the original buffer timestamps cannot reset PTS at a chapter boundary.
    package static func retimed(
        _ sample: CMSampleBuffer,
        pts: CMTime,
        sampleDuration: CMTime
    ) throws -> CMSampleBuffer {
        var copy: CMSampleBuffer?
        var info = CMSampleTimingInfo(
            duration: sampleDuration,
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
        return try requireRetimedCopy(status: status, copy: copy)
    }

    package static func requireRetimedCopy(status: OSStatus, copy: CMSampleBuffer?) throws -> CMSampleBuffer {
        guard status == noErr, let copy else {
            throw BinderError.exportFailed("Failed to retime audio samples")
        }
        return copy
    }

    private func avMetadata(for chapters: [Chapter]) -> [AVMetadataItem] {
        _ = chapters
        return []
    }

    private static func loadAudioTrack(
        from asset: AVURLAsset,
        cancellation: EncodeCancellation
    ) throws -> AVAssetTrack {
        final class Box: @unchecked Sendable {
            let asset: AVURLAsset
            var result: Result<AVAssetTrack, Error>?
            init(asset: AVURLAsset) { self.asset = asset }
        }
        let box = Box(asset: asset)
        let loaded = DispatchSemaphore(value: 0)
        Task {
            defer { loaded.signal() }
            do {
                _ = try await box.asset.load(.duration)
                let tracks = try await box.asset.loadTracks(withMediaType: .audio)
                guard let track = tracks.first else {
                    throw BinderError.exportFailed("No audio track in \(box.asset.url.lastPathComponent)")
                }
                box.result = .success(track)
            } catch {
                box.result = .failure(error)
            }
        }
        guard try wait(loaded, timeout: assetLoadTimeout, cancellation: cancellation) else {
            throw BinderError.exportFailed("Timed out loading \(asset.url.lastPathComponent)")
        }
        switch box.result {
        case .success(let track):
            return track
        case .failure(let error):
            if let binder = error as? BinderError { throw binder }
            throw BinderError.exportFailed(error.localizedDescription)
        case nil:
            throw BinderError.exportFailed("Failed to load \(asset.url.lastPathComponent)")
        }
    }

    private static func throwIfCancelled(_ cancellation: EncodeCancellation, writer: AVAssetWriter) throws {
        if cancellation.isCancelled {
            cancelIfWriting(writer)
            throw BinderError.cancelled
        }
    }

    private static func cancelIfWriting(_ writer: AVAssetWriter) {
        if writer.status == .writing {
            writer.cancelWriting()
        }
    }
}

extension M4BExporter {
    package static let assetLoadTimeout: TimeInterval = 30
    package static let finishWritingTimeout: TimeInterval = 60
    package static let writerReadyTimeout: TimeInterval = 30

    /// Default poll slice so cancel unblocks without waiting out the full timeout.
    package static let waitSlice: TimeInterval = 0.05

    /// Bounded wait so encode cannot block forever on a semaphore that never signals.
    package static func wait(_ semaphore: DispatchSemaphore, timeout: TimeInterval) -> Bool {
        (try? wait(semaphore, timeout: timeout, cancellation: nil)) ?? false
    }

    /// Bounded wait so encode cannot block forever on a group that never leaves.
    package static func wait(_ group: DispatchGroup, timeout: TimeInterval) -> Bool {
        (try? wait(group, timeout: timeout, cancellation: nil)) ?? false
    }

    package static func wait(
        _ semaphore: DispatchSemaphore,
        timeout: TimeInterval,
        cancellation: EncodeCancellation?,
        slice: TimeInterval = waitSlice
    ) throws -> Bool {
        try wait(timeout: timeout, cancellation: cancellation, slice: slice) { remaining in
            semaphore.wait(timeout: .now() + remaining)
        }
    }

    package static func wait(
        _ group: DispatchGroup,
        timeout: TimeInterval,
        cancellation: EncodeCancellation?,
        slice: TimeInterval = waitSlice
    ) throws -> Bool {
        try wait(timeout: timeout, cancellation: cancellation, slice: slice) { remaining in
            group.wait(timeout: .now() + remaining)
        }
    }

    private static func wait(
        timeout: TimeInterval,
        cancellation: EncodeCancellation?,
        slice: TimeInterval,
        step: (TimeInterval) -> DispatchTimeoutResult
    ) throws -> Bool {
        try cancellation?.checkCancelled()
        if cancellation == nil {
            return step(timeout) == .success
        }
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        let slice = max(slice, 0.001)
        while true {
            try cancellation?.checkCancelled()
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                return false
            }
            if step(min(slice, remaining)) == .success {
                return true
            }
        }
    }

    private static func appendCancelled(
        _ books: Array<Audiobook>.SubSequence,
        destinations: [UUID: URL],
        settings: ExportSettings,
        into results: inout [BookExportResult]
    ) {
        for book in books {
            let dest = destinations[book.id] ?? settings.outputURL(for: book)
            results.append(BookExportResult(bookID: book.id, url: dest, outcome: .cancelled))
        }
    }

    /// Dest that existed at export start keeps current overwrite/replace identity.
    /// Dest that appears after that observation is adopted only when this book
    /// owns the same object captured in `live`.
    private static func expectedDestinationIdentity(
        dest: URL,
        book: Audiobook,
        destWasAbsent: Bool,
        ownedIdentity: FileIdentity?
    ) throws -> FileIdentity? {
        let live = FileIdentity.read(from: dest).flatMap { identity in
            identity.isDirectory ? nil : identity
        }
        if destWasAbsent {
            guard live != nil || existingRegularFile(dest) else { return nil }
            guard let live, isOwnedAppearedDest(dest, book: book, live: live) else {
                throw BinderError.outputExists(dest)
            }
            return live
        }
        guard let ownedIdentity else {
            if live != nil || existingRegularFile(dest) {
                throw BinderError.outputExists(dest)
            }
            return nil
        }
        guard let live, live.isSameVersion(as: ownedIdentity) else {
            throw BinderError.outputExists(dest)
        }
        return live
    }

    /// Appeared dest is owned only when `load` validated this same dest object.
    static func isOwnedAppearedDest(_ dest: URL, book: Audiobook, live: FileIdentity) -> Bool {
        guard let associated = OutputAssociation.loadVerified(inBookFolder: book.folder) else {
            return false
        }
        return isSameFileURL(associated.url, dest)
            && associated.identity.isSameVersion(as: live)
    }

    private static func shouldSkipExistingDestination(
        _ dest: URL,
        book: Audiobook,
        settings: ExportSettings
    ) -> Bool {
        guard existingRegularFile(dest) else { return false }
        return validatedOwnedDestinationIdentity(dest, book: book, settings: settings) == nil
    }

    /// Identity `loadVerified` accepted for this dest. Nil if dest is absent,
    /// overwrite is off, or the live file is not the owned object.
    private static func validatedOwnedDestinationIdentity(
        _ dest: URL,
        book: Audiobook,
        settings: ExportSettings
    ) -> FileIdentity? {
        guard settings.overwrite else { return nil }
        guard let associated = OutputAssociation.loadVerified(inBookFolder: book.folder),
              isSameFileURL(associated.url, dest)
        else {
            return nil
        }
        return associated.identity
    }

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

    /// Dest is already committed. Never throw `.cancelled` from this path.
    /// Every exit persists loadable provenance or explicitly invalidates.
    private static func finalizePublishedOutput(
        dest: URL,
        captured: [SourceAssociation.Entry],
        stagingDigest: String,
        inBookFolder folder: URL
    ) throws {
        do {
            try completePublishedProvenance(
                dest: dest,
                captured: captured,
                stagingDigest: stagingDigest,
                inBookFolder: folder
            )
        } catch let error as BinderError {
            switch error {
            case .publishedUnverified:
                throw error
            case .cancelled:
                SourceAssociation.invalidate(inBookFolder: folder)
                throw BinderError.publishedUnverified("Cancelled after the audiobook was written")
            default:
                SourceAssociation.invalidate(inBookFolder: folder)
                throw BinderError.publishedUnverified(error.localizedDescription)
            }
        } catch is CancellationError {
            SourceAssociation.invalidate(inBookFolder: folder)
            throw BinderError.publishedUnverified("Cancelled after the audiobook was written")
        } catch {
            SourceAssociation.invalidate(inBookFolder: folder)
            throw BinderError.publishedUnverified(error.localizedDescription)
        }
    }

    private static func completePublishedProvenance(
        dest: URL,
        captured: [SourceAssociation.Entry],
        stagingDigest: String,
        inBookFolder folder: URL
    ) throws {
        guard let destIdentity = FileIdentity.read(from: dest), !destIdentity.isDirectory else {
            SourceAssociation.invalidate(inBookFolder: folder)
            throw BinderError.publishedUnverified("Could not record published output identity")
        }
        guard let publishedDigest = try SourceAssociation.sha256Hex(of: dest, cancellation: nil),
              !publishedDigest.isEmpty,
              publishedDigest.caseInsensitiveCompare(stagingDigest) == .orderedSame
        else {
            SourceAssociation.invalidate(inBookFolder: folder)
            throw BinderError.publishedUnverified("Published output does not match encoded file")
        }
        guard SourceAssociation.record(
            captured: captured,
            dest: dest,
            destIdentity: destIdentity,
            destinationSHA256: publishedDigest,
            inBookFolder: folder
        ) else {
            SourceAssociation.invalidate(inBookFolder: folder)
            throw BinderError.publishedUnverified("Could not record source provenance")
        }
        guard OutputAssociation.record(dest, inBookFolder: folder) else {
            SourceAssociation.invalidate(inBookFolder: folder)
            throw BinderError.publishedUnverified("Could not record output association")
        }
    }

    /// Publishes a ready staging file. Never delete-then-move the previous dest.
    /// `expectedIdentity` is the dest snapshot from export start (`nil` = absent).
    /// Returns a warning when dest was published but the previous dest could
    /// not be moved to Trash. Callers must finalize provenance first.
    static func publish(
        staging: URL,
        to dest: URL,
        overwrite: Bool,
        expectedIdentity: FileIdentity?
    ) throws -> String? {
        let kind = destinationKind(dest)
        if kind.isDirectory {
            throw BinderError.exportFailed("Destination is a directory: \(dest.path)")
        }
        let live = FileIdentity.read(from: dest).flatMap { identity in
            identity.isDirectory ? nil : identity
        }

        if let expectedIdentity {
            guard let live, live.isSameVersion(as: expectedIdentity) else {
                throw BinderError.outputExists(dest)
            }
            if !overwrite {
                throw BinderError.outputExists(dest)
            }
            testingBeforeReplaceItem?()
            let backup = dest.deletingLastPathComponent()
                .appendingPathComponent(".\(UUID().uuidString).m4b-bak")
            do {
                try FileManager.default.moveItem(at: dest, to: backup)
            } catch {
                throw BinderError.outputExists(dest)
            }
            testingAfterMoveDestAside?()
            guard let backupHandle = openBackup(backup) else {
                restoreDisplacedBackupIfDestVacant(backup, dest: dest)
                throw BinderError.outputExists(dest)
            }
            defer { try? backupHandle.close() }
            guard let backupSnap = backupInodeSnapshot(of: backupHandle),
                  let displaced = FileIdentity.read(from: backup).flatMap({ identity in
                      identity.isDirectory ? nil : identity
                  }),
                  displaced.isSameVersion(as: expectedIdentity),
                  pathNamesBackupInode(backup, expected: backupSnap, handle: backupHandle)
            else {
                restoreDisplacedBackupIfDestVacant(backup, dest: dest)
                throw BinderError.outputExists(dest)
            }
            if FileManager.default.fileExists(atPath: dest.path) {
                throw BinderError.outputExists(dest)
            }
            do {
                try FileManager.default.moveItem(at: staging, to: dest)
            } catch {
                restoreDisplacedBackupIfDestVacant(backup, dest: dest)
                throw BinderError.outputExists(dest)
            }
            testingBeforeRemoveBackup?(backup)
            do {
                try trashHeldBackup(handle: backupHandle, expected: backupSnap)
            } catch let error as BinderError {
                if case .publishedUnverified(let warning) = error {
                    return warning
                }
                throw error
            }
            return nil
        }

        if live != nil || kind.exists {
            throw BinderError.outputExists(dest)
        }
        do {
            try FileManager.default.moveItem(at: staging, to: dest)
        } catch {
            if FileManager.default.fileExists(atPath: dest.path) {
                throw BinderError.outputExists(dest)
            }
            throw BinderError.exportFailed(error.localizedDescription)
        }
        return nil
    }

    /// Put the displaced dest back when the path is still vacant. Never delete
    /// the backup here: if dest reappeared, the backup is the only copy.
    private static func restoreDisplacedBackupIfDestVacant(_ backup: URL, dest: URL) {
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? FileManager.default.moveItem(at: backup, to: dest)
    }

    private struct BackupInode: Equatable {
        var device: dev_t
        var inode: ino_t
    }

    private static func openBackup(_ url: URL) -> FileHandle? {
        url.withUnsafeFileSystemRepresentation { cPath in
            guard let cPath else { return nil }
            let fd = open(cPath, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
    }

    private static func backupInodeSnapshot(of handle: FileHandle) -> BackupInode? {
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return BackupInode(device: info.st_dev, inode: info.st_ino)
    }

    private static func backupInodeSnapshot(at url: URL) -> BackupInode? {
        url.withUnsafeFileSystemRepresentation { cPath in
            guard let cPath else { return nil }
            var info = stat()
            guard lstat(cPath, &info) == 0 else { return nil }
            guard (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            return BackupInode(device: info.st_dev, inode: info.st_ino)
        }
    }

    private static func pathNamesBackupInode(
        _ url: URL,
        expected: BackupInode,
        handle: FileHandle
    ) -> Bool {
        guard let pathSnap = backupInodeSnapshot(at: url),
              let fdSnap = backupInodeSnapshot(of: handle)
        else {
            return false
        }
        return pathSnap == expected && fdSnap == expected
    }

    private static func currentURL(of handle: FileHandle) -> URL? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let status = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return fcntl(handle.fileDescriptor, F_GETPATH, base)
        }
        guard status == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Trash the displaced dest inode. Never delete by the original backup
    /// pathname — that name may now point at a replacement.
    private static func trashHeldBackup(handle: FileHandle, expected: BackupInode) throws {
        if testingTrashHeldBackupFails {
            throw BinderError.publishedUnverified("Could not move the previous audiobook to Trash")
        }
        guard let current = currentURL(of: handle),
              pathNamesBackupInode(current, expected: expected, handle: handle)
        else {
            throw BinderError.publishedUnverified("Could not move the previous audiobook to Trash")
        }
        do {
            var resultingItem: NSURL?
            try FileManager.default.trashItem(at: current, resultingItemURL: &resultingItem)
            guard let trashed = resultingItem as URL?,
                  pathNamesBackupInode(trashed, expected: expected, handle: handle)
            else {
                throw BinderError.publishedUnverified("Could not move the previous audiobook to Trash")
            }
        } catch BinderError.publishedUnverified {
            throw BinderError.publishedUnverified("Could not move the previous audiobook to Trash")
        } catch {
            throw BinderError.publishedUnverified("Could not move the previous audiobook to Trash")
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

    private static func chaptersForEncode(_ chapters: [Chapter], snapshots: [String: URL]) -> [Chapter] {
        chapters.map { chapter in
            guard let snapshot = snapshots[chapter.url.standardizedFileURL.path] else {
                return chapter
            }
            var copy = chapter
            copy.url = snapshot
            return copy
        }
    }

    static func isSameFileURL(_ a: URL, _ b: URL) -> Bool {
        if let aID = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           let bID = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           aID.isEqual(bID) {
            return true
        }
        return a.resolvingSymlinksInPath().standardizedFileURL.path
            == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
