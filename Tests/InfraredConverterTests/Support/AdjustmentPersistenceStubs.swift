import Foundation
@testable import InfraredConverter

/// What the workspace did, in the order it did it.
///
/// The open invariant this milestone exists for is an **ordering** claim —
/// the saved adjustments are read before anything is decoded or rendered — and
/// an ordering claim can only be tested by recording order. A shared log that
/// the store, the decoder and the render seam all append to is the smallest
/// thing that can do that.
final class WorkspaceEventLog: @unchecked Sendable {
    enum Event: Equatable {
        /// The store was asked for a file's saved adjustments, and what it
        /// answered.
        case loadedAdjustments(UserOrientationAdjustment?)
        /// The store refused.
        case adjustmentLoadRefused
        /// The expensive half of the pipeline ran.
        case decodedMosaic
        /// A full render ran, for this adjustment.
        case rendered(UserOrientationAdjustment)
        /// A render refused, for this adjustment.
        case renderRefused(UserOrientationAdjustment)
        /// The store was asked to write this adjustment.
        case saved(UserOrientationAdjustment)
        /// The store refused to write it.
        case saveRefused(UserOrientationAdjustment)
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func append(_ event: Event) {
        lock.lock()
        defer { lock.unlock() }
        events.append(event)
    }

    var all: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Every render that actually ran, in order. One element after an open is
    /// the whole "no double render" claim.
    var renders: [UserOrientationAdjustment] {
        all.compactMap { if case .rendered(let state) = $0 { return state } else { return nil } }
    }

    /// Every adjustment that reached the store, in order.
    var saves: [UserOrientationAdjustment] {
        all.compactMap { if case .saved(let state) = $0 { return state } else { return nil } }
    }

    var decodeCount: Int {
        all.filter { $0 == .decodedMosaic }.count
    }

    /// The index of the first event matching `predicate`, for ordering
    /// assertions.
    func firstIndex(where predicate: (Event) -> Bool) -> Int? {
        all.firstIndex(where: predicate)
    }
}

/// An in-memory `ImageAdjustmentStore` the test drives and then interrogates.
///
/// It is not a fake filesystem: nothing here is atomic, nothing is encoded.
/// Its job is to answer "what did the workspace ask for, in what order, and
/// what did it try to write" — the questions the JSON store's own suite
/// cannot answer because it does not know what a document is.
final class StubImageAdjustmentStore: ImageAdjustmentStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL: ImageAdjustments] = [:]
    private var loadRefusals: [URL: ImageAdjustmentPersistenceError] = [:]
    private var saveRefusal: ImageAdjustmentPersistenceError?
    let log: WorkspaceEventLog

    init(log: WorkspaceEventLog = WorkspaceEventLog()) {
        self.log = log
    }

    /// Puts a saved record in place, as if a previous session had written it.
    func preload(_ adjustments: ImageAdjustments, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        stored[url] = adjustments
    }

    /// Makes this file's record exist and refuse to be read.
    func refuseLoad(for url: URL, with error: ImageAdjustmentPersistenceError) {
        lock.lock()
        defer { lock.unlock() }
        loadRefusals[url] = error
    }

    /// Makes every save refuse, as an unwritable volume would.
    func refuseSaves(with error: ImageAdjustmentPersistenceError) {
        lock.lock()
        defer { lock.unlock() }
        saveRefusal = error
    }

    /// What is currently recorded for a file, without logging a load.
    func saved(for url: URL) -> ImageAdjustments? {
        lock.lock()
        defer { lock.unlock() }
        return stored[url]
    }

    func load(for url: URL) throws(ImageAdjustmentPersistenceError) -> ImageAdjustments? {
        let refusal: ImageAdjustmentPersistenceError? = {
            lock.lock()
            defer { lock.unlock() }
            return loadRefusals[url]
        }()
        if let refusal {
            log.append(.adjustmentLoadRefused)
            throw refusal
        }

        let adjustments: ImageAdjustments? = {
            lock.lock()
            defer { lock.unlock() }
            return stored[url]
        }()
        log.append(.loadedAdjustments(adjustments?.orientation))
        return adjustments
    }

    func save(
        _ adjustments: ImageAdjustments, for url: URL
    ) throws(ImageAdjustmentPersistenceError) {
        let refusal: ImageAdjustmentPersistenceError? = {
            lock.lock()
            defer { lock.unlock() }
            return saveRefusal
        }()
        if let refusal {
            log.append(.saveRefused(adjustments.orientation))
            throw refusal
        }

        lock.lock()
        stored[url] = adjustments
        lock.unlock()
        log.append(.saved(adjustments.orientation))
    }
}

/// The real render, wrapped so a test can count it and make it refuse.
///
/// The render itself is genuine — `DocumentState.pipelineRender`, the same
/// closure production uses — so a test that asserts on the resulting pixels is
/// asserting on real ones. Only the counting and the deliberate refusal are
/// added.
struct RecordingRender: Sendable {
    /// A refusal that is nothing like a cancellation: a stage saying no.
    struct Refused: Error, LocalizedError {
        var errorDescription: String? { "The stub render refused this adjustment." }
    }

    let log: WorkspaceEventLog
    /// Adjustments this render refuses. Everything else renders normally.
    var refusing: [UserOrientationAdjustment] = []

    var render: DocumentState.PreviewRender {
        let log = self.log
        let refusing = self.refusing
        return { source, adjustments, cancellation in
            if refusing.contains(adjustments.orientation) {
                log.append(.renderRefused(adjustments.orientation))
                throw Refused()
            }
            let preview = try DocumentState.pipelineRender(source, adjustments, cancellation)
            log.append(.rendered(adjustments.orientation))
            return preview
        }
    }
}

/// A decoder that records the expensive decode, so a test can prove it
/// happened once and happened *after* the saved adjustments were read.
struct RecordingMosaicDecoder: RAWDecoder {
    let wrapped: WorkspaceStubDecoder
    let log: WorkspaceEventLog

    func readMetadata(at url: URL) throws -> RAWMetadata {
        try wrapped.readMetadata(at: url)
    }

    func decode(at url: URL, options: RAWDecodeOptions) throws -> DecodedRAW {
        try wrapped.decode(at: url, options: options)
    }

    func decodeMosaic(at url: URL) throws -> DecodedRAWMosaic {
        log.append(.decodedMosaic)
        return try wrapped.decodeMosaic(at: url)
    }
}
