import Foundation

/// Captured cleanup identity. Commits look up by `bookID`, never a start index.
public struct CleanupJob: Equatable, Hashable, Sendable {
    public let bookID: UUID
    public let generation: UInt64

    public init(bookID: UUID, generation: UInt64) {
        self.bookID = bookID
        self.generation = generation
    }
}

/// Owns at most one in-flight cleanup. Apply only if this job is still current.
public struct CleanupJobOwner: Equatable, Sendable {
    public private(set) var current: CleanupJob?
    private var generation: UInt64 = 0

    public init() {}

    public var isCleaningUp: Bool { current != nil }

    /// Starts a job for `bookID`. Returns nil when one is already running.
    public mutating func begin(bookID: UUID) -> CleanupJob? {
        guard current == nil else { return nil }
        generation += 1
        let job = CleanupJob(bookID: bookID, generation: generation)
        current = job
        return job
    }

    /// Clears in-progress state only when `job` is the current generation.
    public mutating func finish(_ job: CleanupJob) {
        guard isCurrent(job) else { return }
        current = nil
        generation += 1
    }

    public func isCurrent(_ job: CleanupJob) -> Bool {
        current == job && job.generation == generation
    }

    /// Success: remaining chapters from reconciling the *snapshot* chapters against moved files.
    @discardableResult
    public func commitSuccess(
        _ books: inout [Audiobook],
        job: CleanupJob,
        inspection: M4BInspection,
        snapshotChapters: [Chapter],
        moved: [URL]
    ) -> Bool {
        let remaining = SourceCleanup.reconcile(chapters: snapshotChapters, moved: moved)
        return apply(to: &books, job: job, inspection: inspection, remainingChapters: remaining)
    }

    /// Partial: remaining chapters from reconciling the *snapshot* chapters.
    @discardableResult
    public func commitPartial(
        _ books: inout [Audiobook],
        job: CleanupJob,
        inspection: M4BInspection,
        snapshotChapters: [Chapter],
        moved: [URL]
    ) -> Bool {
        let remaining = SourceCleanup.reconcile(chapters: snapshotChapters, moved: moved)
        return apply(to: &books, job: job, inspection: inspection, remainingChapters: remaining)
    }

    @discardableResult
    public func apply(
        to books: inout [Audiobook],
        job: CleanupJob,
        inspection: M4BInspection,
        remainingChapters: [Chapter]
    ) -> Bool {
        guard isCurrent(job) else { return false }
        guard let index = books.firstIndex(where: { $0.id == job.bookID }) else {
            return false
        }
        books[index].chapters = remainingChapters
        books[index].existingM4BURL = inspection.url
        books[index].boundDuration = inspection.duration
        if remainingChapters.isEmpty {
            books[index].selected = false
        }
        return true
    }
}
