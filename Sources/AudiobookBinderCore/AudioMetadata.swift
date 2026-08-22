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

    public static func duration(of url: URL) -> TimeInterval {
        var file: AudioFileID?
        let status = AudioFileOpenURL(url as CFURL, .readPermission, 0, &file)
        guard status == noErr, let file else { return 0 }
        defer { AudioFileClose(file) }
        var duration: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let prop = AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &size, &duration)
        if prop == noErr, duration.isFinite, duration > 0 {
            return TimeInterval(duration)
        }
        return 0
    }

    public static func loadTags(from url: URL, includeArtwork: Bool = true) async -> TrackTags {
        var tags = TrackTags(duration: duration(of: url))
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.metadata)
            tags.title = firstString(metadata, identifiers: [
                .commonIdentifierTitle, .id3MetadataTitleDescription, .iTunesMetadataSongName
            ])
            tags.album = firstString(metadata, identifiers: [
                .commonIdentifierAlbumName, .id3MetadataAlbumTitle, .iTunesMetadataAlbum
            ])
            tags.artist = firstString(metadata, identifiers: [
                .commonIdentifierArtist, .id3MetadataLeadPerformer, .iTunesMetadataArtist
            ])
            tags.composer = firstString(metadata, identifiers: [
                .id3MetadataComposer, .iTunesMetadataComposer, .commonIdentifierCreator
            ])
            tags.comment = firstString(metadata, identifiers: [
                .commonIdentifierDescription, .id3MetadataComments, .iTunesMetadataDescription
            ])
            if let track = firstNumber(metadata, identifiers: [.id3MetadataTrackNumber, .iTunesMetadataTrackNumber]) {
                tags.trackNumber = track
            }
            if includeArtwork {
                tags.artwork = firstArtwork(metadata)
                if tags.artwork == nil {
                    tags.artwork = firstArtwork(try await asset.load(.commonMetadata))
                }
            }
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
        } catch {
            // Keep AudioToolbox duration even if metadata load fails.
        }
        return tags
    }

    private static func firstString(_ items: [AVMetadataItem], identifiers: [AVMetadataIdentifier]) -> String? {
        for id in identifiers {
            if let value = items.first(where: { $0.identifier == id })?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func firstNumber(_ items: [AVMetadataItem], identifiers: [AVMetadataIdentifier]) -> Int? {
        for id in identifiers {
            guard let item = items.first(where: { $0.identifier == id }) else { continue }
            if let n = item.numberValue?.intValue, n > 0 { return n }
            if let s = item.stringValue {
                let part = s.split(whereSeparator: { $0 == "/" || $0 == " " }).first
                if let part, let n = Int(part), n > 0 { return n }
            }
        }
        return nil
    }

    private static func firstArtwork(_ items: [AVMetadataItem]) -> Data? {
        for item in items {
            let isArt = item.identifier == .commonIdentifierArtwork
                || item.identifier == .iTunesMetadataCoverArt
                || item.commonKey == .commonKeyArtwork
            guard isArt else { continue }
            if let data = item.dataValue, !data.isEmpty { return data }
            if let data = item.value as? Data, !data.isEmpty { return data }
        }
        return nil
    }
}

public enum CoverJPEG {
    public static func loadAndNormalize(from url: URL, maxEdge: CGFloat = 1400) -> Data? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return normalize(data, maxEdge: maxEdge)
    }

    public static func normalize(_ data: Data, maxEdge: CGFloat = 1400) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return data.isEmpty ? nil : data
        }
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let longest = max(w, h)
        let scale = longest > maxEdge ? maxEdge / longest : 1
        let tw = max(1, Int(w * scale))
        let th = max(1, Int(h * scale))
        let color = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: tw,
            height: th,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: color,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return data }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let scaled = ctx.makeImage() else { return data }
        let dest = NSMutableData()
        guard let destSrc = CGImageDestinationCreateWithData(dest, "public.jpeg" as CFString, 1, nil) else {
            return data
        }
        let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.88]
        CGImageDestinationAddImage(destSrc, scaled, opts as CFDictionary)
        CGImageDestinationFinalize(destSrc)
        return dest as Data
    }
}
