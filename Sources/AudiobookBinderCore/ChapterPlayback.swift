import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
public final class ChapterPlayback {
    public private(set) var playingID: UUID?
    public private(set) var isPlaying = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var endTask: Task<Void, Never>?
    @ObservationIgnored private var failTask: Task<Void, Never>?
    @ObservationIgnored private var boundaryToken: Any?

    public init() {}

    public func isPlaying(_ chapter: Chapter) -> Bool {
        isPlaying && playingID == chapter.id
    }

    public func toggle(_ chapter: Chapter) {
        if playingID == chapter.id, player != nil {
            if isPlaying {
                player?.pause()
                isPlaying = false
            } else {
                player?.play()
                isPlaying = true
            }
            return
        }

        stop()

        let url = chapter.url
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path) else {
            return
        }

        let item = AVPlayerItem(url: url)
        if item.status == .failed {
            return
        }

        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = false
        self.player = player
        playingID = chapter.id
        listenForEnd(of: item)
        if chapter.isEmbedded {
            let start = CMTime(seconds: chapter.startOffset, preferredTimescale: 600)
            let endSeconds = chapter.startOffset + max(chapter.duration, 0.05)
            let end = CMTime(seconds: endSeconds, preferredTimescale: 600)
            boundaryToken = player.addBoundaryTimeObserver(
                forTimes: [NSValue(time: end)],
                queue: .main
            ) { [weak self] in
                self?.stop()
            }
            player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor in
                    guard finished else { return }
                    self?.player?.play()
                    self?.isPlaying = true
                }
            }
        } else {
            player.play()
            isPlaying = true
        }
    }

    public func stop() {
        endTask?.cancel()
        endTask = nil
        failTask?.cancel()
        failTask = nil
        if let boundaryToken, let player {
            player.removeTimeObserver(boundaryToken)
        }
        boundaryToken = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playingID = nil
        isPlaying = false
    }

    private func listenForEnd(of item: AVPlayerItem) {
        endTask?.cancel()
        failTask?.cancel()
        endTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: AVPlayerItem.didPlayToEndTimeNotification,
                object: item
            ) {
                guard !Task.isCancelled else { return }
                self?.stop()
                return
            }
        }
        failTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: AVPlayerItem.failedToPlayToEndTimeNotification,
                object: item
            ) {
                guard !Task.isCancelled else { return }
                self?.stop()
                return
            }
        }
    }
}
