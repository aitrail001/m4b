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

    public func export(
        book: Audiobook,
        to outputURL: URL,
        overwrite: Bool,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            if overwrite {
                try FileManager.default.removeItem(at: outputURL)
            } else {
                throw BinderError.outputExists(outputURL)
            }
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let tempURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).m4a")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        let chapters = Self.chaptersReadyForExport(book.chapters).filter {
            FileManager.default.fileExists(atPath: $0.url.path)
        }
        guard !chapters.isEmpty else { throw BinderError.noAudioFiles(book.folder) }

        progress?(0.01, "Preparing \(book.title)")

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

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: outputURL)
        progress?(1.0, "Finished \(book.title)")
    }

    public func exportAll(
        books: [Audiobook],
        settings: ExportSettings,
        progress: (@Sendable (BuildProgress) -> Void)? = nil
    ) async throws -> [URL] {
        let selected = books.filter(\.selected)
        var written: [URL] = []
        for (idx, book) in selected.enumerated() {
            try Task.checkCancellation()
            let dest = settings.outputURL(for: book)
            do {
                try await export(book: book, to: dest, overwrite: settings.overwrite) { fraction, detail in
                    progress?(
                        BuildProgress(
                            bookTitle: book.title,
                            bookIndex: idx + 1,
                            bookCount: selected.count,
                            fraction: (Double(idx) + fraction) / Double(selected.count),
                            detail: detail
                        )
                    )
                }
                written.append(dest)
            } catch BinderError.outputExists {
                written.append(dest)
            }
        }
        return written
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
