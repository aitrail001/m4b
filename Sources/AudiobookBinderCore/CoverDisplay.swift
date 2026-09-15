import Foundation

/// Chooses cover pixels for UI. Only validated `coverJPEG` is displayable;
/// `coverURL` is source metadata and is never decoded after normalization.
public enum CoverDisplay: Sendable {
    public enum Source: Equatable, Sendable {
        case jpeg
        case placeholder
    }

    /// Display never falls back to `NSImage(contentsOf:)` / raw URL bytes.
    public static let usesRawURLFallback = false

    public static func imageData(jpeg: Data?, url _: URL?) -> Data? {
        guard let jpeg, !jpeg.isEmpty else { return nil }
        return jpeg
    }

    public static func source(jpeg: Data?, url: URL?) -> Source {
        imageData(jpeg: jpeg, url: url) == nil ? .placeholder : .jpeg
    }
}
