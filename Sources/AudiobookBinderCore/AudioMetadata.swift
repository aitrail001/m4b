import AVFoundation
import AudioToolbox
import Foundation
import ImageIO

public struct TrackTags: Sendable, Equatable {
    public var title: String?
    public var album: String?
    public var artist: String?
    public var composer: String?
    public var comment: String?
    public var trackNumber: Int?
    public var duration: TimeInterval
    public var artwork: Data?
    public var channelCount: Int
    public var sampleRate: Double

    public init(
        title: String? = nil,
        album: String? = nil,
        artist: String? = nil,
        composer: String? = nil,
        comment: String? = nil,
        trackNumber: Int? = nil,
        duration: TimeInterval = 0,
        artwork: Data? = nil,
        channelCount: Int = 1,
        sampleRate: Double = 44100
    ) {
        self.title = title
        self.album = album
        self.artist = artist
        self.composer = composer
        self.comment = comment
        self.trackNumber = trackNumber
        self.duration = duration
        self.artwork = artwork
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }
}

public enum AudioMetadata {
    public static func streamDescription(of url: URL) -> AudioStreamBasicDescription? {
        var file: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &file)
        guard status == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let prop = AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd)
        guard prop == noErr else { return nil }
        return asbd
    }

    public static func fileInfo(of url: URL) -> (duration: TimeInterval, audioInfo: AudioInfo) {
        var file: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &file)
        guard status == noErr, let file else {
            return (0, AudioInfo())
        }
        defer { AudioFileClose(file) }

        var duration: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var prop = AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)
        let durationValue: TimeInterval
        if prop == noErr, duration.isFinite, duration > 0 {
            durationValue = TimeInterval(duration)
        } else {
            durationValue = 0
        }

        var bitrate: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        prop = AudioFileGetProperty(file, kAudioFilePropertyBitRate, &size, &bitrate)
        var bitrateValue = prop == noErr ? Int(bitrate) : 0

        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        prop = AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &size, &asbd)
        let sampleRate: Double
        let channelCount: Int
        let formatName: String
        if prop == noErr {
            sampleRate = asbd.mSampleRate.isFinite ? asbd.mSampleRate : 0
            channelCount = Int(asbd.mChannelsPerFrame)
            formatName = Self.formatName(for: asbd.mFormatID, url: url)
        } else {
            sampleRate = 0
            channelCount = 0
            formatName = url.pathExtension.uppercased()
        }

        if bitrateValue == 0, durationValue > 0 {
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            if fileSize > 0 {
                bitrateValue = Int(Double(fileSize) * 8 / durationValue)
            }
        }

        return (
            durationValue,
            AudioInfo(
                bitrate: bitrateValue,
                sampleRate: sampleRate,
                channelCount: channelCount,
                formatName: formatName
            )
        )
    }

    private static func formatName(for formatID: AudioFormatID, url: URL) -> String {
        switch formatID {
        case kAudioFormatMPEGLayer3:
            return "MP3"
        case kAudioFormatMPEG4AAC,
             kAudioFormatMPEG4AAC_HE,
             kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD,
             kAudioFormatMPEG4AAC_ELD_SBR,
             kAudioFormatMPEG4AAC_ELD_V2,
             kAudioFormatMPEG4AAC_Spatial:
            return "AAC"
        case kAudioFormatAppleLossless:
            return "ALAC"
        case kAudioFormatFLAC:
            return "FLAC"
        case kAudioFormatLinearPCM:
            return "PCM"
        default:
            return url.pathExtension.uppercased()
        }
    }

    public static func loadTags(from url: URL, includeArtwork: Bool = true) async -> TrackTags {
        var tags = TrackTags(duration: fileInfo(of: url).duration)
        if Task.isCancelled { return tags }
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            if Task.isCancelled { return tags }
            tags.title = await firstString(metadata, identifiers: [
                .commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName
            ])
            tags.album = await firstString(metadata, identifiers: [
                .commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum
            ])
            tags.artist = await firstString(metadata, identifiers: [
                .commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist
            ])
            tags.composer = await firstString(metadata, identifiers: [
                .id3MetadataComposer, .iTunesMetadataComposer, .commonIdentifierCreator
            ])
            tags.comment = await firstString(metadata, identifiers: [
                .commonIdentifierDescription, .id3MetadataComments, .iTunesMetadataDescription
            ])
            if Task.isCancelled { return tags }
            if let track = await firstNumber(
                metadata,
                identifiers: [.id3MetadataTrackNumber, .iTunesMetadataTrackNumber]
            ) {
                tags.trackNumber = track
            }
            if includeArtwork {
                tags.artwork = await firstArtwork(metadata)
                if tags.artwork == nil {
                    if Task.isCancelled { return tags }
                    tags.artwork = await firstArtwork(try await asset.load(.commonMetadata))
                }
            }
            if Task.isCancelled { return tags }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            if let track = tracks.first {
                let desc = try await track.load(.formatDescriptions)
                if let cm = desc.first, let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(cm)?.pointee {
                    tags.channelCount = Int(asbd.mChannelsPerFrame)
                    tags.sampleRate = asbd.mSampleRate
                }
            }
            let precise = try await asset.load(.duration)
            if precise.isNumeric, precise.seconds > 0 {
                tags.duration = precise.seconds
            }
        } catch is CancellationError {
            return tags
        } catch {
            if Task.isCancelled { return tags }
            // Keep AudioToolbox duration even if metadata load fails.
        }
        return tags
    }

    private static func firstString(
        _ items: [AVMetadataItem],
        identifiers: [AVMetadataIdentifier]
    ) async -> String? {
        for id in identifiers {
            if Task.isCancelled { return nil }
            guard let item = items.first(where: { $0.identifier == id }) else { continue }
            guard let value = try? await item.load(.stringValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else { continue }
            return value
        }
        return nil
    }

    private static func firstNumber(
        _ items: [AVMetadataItem],
        identifiers: [AVMetadataIdentifier]
    ) async -> Int? {
        for id in identifiers {
            if Task.isCancelled { return nil }
            guard let item = items.first(where: { $0.identifier == id }) else { continue }
            if let n = try? await item.load(.numberValue), n.intValue > 0 {
                return n.intValue
            }
            if let s = try? await item.load(.stringValue) {
                let part = s.split(whereSeparator: { $0 == "/" || $0 == " " }).first
                if let part, let n = Int(part), n > 0 { return n }
            }
        }
        return nil
    }

    private static func firstArtwork(_ items: [AVMetadataItem]) async -> Data? {
        for item in items {
            if Task.isCancelled { return nil }
            let isArt = item.identifier == .commonIdentifierArtwork
                || item.identifier == .iTunesMetadataCoverArt
                || item.commonKey == .commonKeyArtwork
            guard isArt else { continue }
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
            if let value = try? await item.load(.value), let data = value as? Data, !data.isEmpty {
                return data
            }
        }
        return nil
    }
}

public enum CoverJPEG {
    /// Source images larger than this are rejected before decode.
    public static let maxSourceBytes = 16 * 1024 * 1024
    public static let defaultMaxEdge: CGFloat = 1400

    public static func loadAndNormalize(from url: URL, maxEdge: CGFloat = defaultMaxEdge) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= maxSourceBytes
        else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions()) else {
            return nil
        }
        return jpegThumbnail(from: source, maxEdge: maxEdge)
    }

    public static func normalize(_ data: Data, maxEdge: CGFloat = defaultMaxEdge) -> Data? {
        guard !data.isEmpty, data.count <= maxSourceBytes else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions()) else {
            return nil
        }
        return jpegThumbnail(from: source, maxEdge: maxEdge)
    }

    private static func sourceOptions() -> CFDictionary {
        [
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary
    }

    private static func jpegThumbnail(from source: CGImageSource, maxEdge: CGFloat) -> Data? {
        let pixelSize = max(1, Int(maxEdge))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let dest = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination), dest.length > 0 else {
            return nil
        }
        return dest as Data
    }
}
