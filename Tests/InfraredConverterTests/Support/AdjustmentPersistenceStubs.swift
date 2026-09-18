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
    /// Every event carries the **complete** adjustment record, not one field
    /// of it.
    ///
    /// That is the whole point of the log now that there are two adjustments:
    /// a render request is one complete state, so a log that recorded only the
    /// orientation could not tell "swap, then rotate" from "rotate" and could
    /// not show that no intermediate state was rendered or written.
    enum Event: Equatable {
        /// The store was asked for a file's saved adjustments, and what it
        /// answered.
        case loadedAdjustments(ImageAdjustments?)
        /// The store refused.
        case adjustmentLoadRefused
        /// The expensive half of the pipeline ran.
        case decodedMosaic
        /// The white-balance-dependent half of the pipeline ran — estimate,
        /// balance, demosaic, convert, reduce — for this decision.
        ///
        /// Logged separately from `rendered` because the whole point of the
        /// two-slot architecture is that they run at different times and for
        /// different reasons. A rotation that produced one of these would be a
        /// defect no assertion on the final image could catch.
        case preparedSource(SourcePreparationRequest)
        /// The white-balance-dependent half refused this decision.
        case preparationRefused(SourcePreparationRequest)
        /// A full render ran, for this complete state.
        case rendered(ImageAdjustments)
        /// A render refused, for this complete state.
        case renderRefused(ImageAdjustments)
        /// The store was asked to write this complete state.
        case saved(ImageAdjustments)
        /// The store refused to write it.
        case saveRefused(ImageAdjustments)
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
    var renders: [ImageAdjustments] {
        all.compactMap { if case .rendered(let state) = $0 { return state } else { return nil } }
    }

    /// Every adjustment that reached the store, in order.
    var saves: [ImageAdjustments] {
        all.compactMap { if case .saved(let state) = $0 { return state } else { return nil } }
    }

    /// The orientation term of every render, for the suites whose subject is
    /// geometry alone.
    var renderedOrientations: [UserOrientationAdjustment] {
        renders.map(\.orientation)
    }

    /// The orientation term of every save.
    var savedOrientations: [UserOrientationAdjustment] {
        saves.map(\.orientation)
    }

    /// Every white balance the heavy half was actually run for, in order.
    ///
    /// A burst of picks that produced one entry is the coalescing claim; a
    /// rotation that produced none is the "fast adjustments stay fast" claim.
    var preparations: [UserWhiteBalanceAdjustment] {
        preparationRequests.map(\.whiteBalance)
    }

    /// The complete requests the heavy half actually ran, in order.
    ///
    /// This is the event that carries the capture profile, because this is the
    /// pass a profile changes: the camera-to-working transform runs here. A
    /// fast render's profile is asserted through the installed preview's own
    /// provenance instead — the observable a user would actually see — rather
    /// than duplicated into every ordering assertion in the suite.
    var preparationRequests: [SourcePreparationRequest] {
        all.compactMap {
            if case .preparedSource(let request) = $0 { return request } else { return nil }
        }
    }

    /// The capture profiles the heavy half was run for, in order.
    var preparedProfiles: [IRCaptureProfileID] {
        preparationRequests.map(\.captureProfile.id)
    }

    /// Every white balance the heavy half was **asked** for, whether it
    /// finished or refused.
    var preparationAttempts: [UserWhiteBalanceAdjustment] {
        all.compactMap {
            switch $0 {
            case .preparedSource(let request), .preparationRefused(let request):
                return request.whiteBalance
            default: return nil
            }
        }
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

/// An in-memory `PhotographProcessingStore` the test drives and then
/// interrogates.
///
/// It is not a fake filesystem: nothing here is atomic, nothing is encoded.
/// Its job is to answer "what did the workspace ask for, in what order, and
/// what did it try to write" — the questions the JSON store's own suite
/// cannot answer because it does not know what a document is.
final class StubPhotographProcessingStore: PhotographProcessingStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL: PhotographProcessingState] = [:]
    private var loadRefusals: [URL: PhotographProcessingPersistenceError] = [:]
    private var saveRefusal: PhotographProcessingPersistenceError?
    let log: WorkspaceEventLog

    init(log: WorkspaceEventLog = WorkspaceEventLog()) {
        self.log = log
    }

    /// Puts a saved record in place, as if a previous session had written it.
    /// Seeds a photograph's saved adjustments under the built-in uncalibrated
    /// profile — what every sidecar written before capture profiles existed
    /// migrates to, and what a fresh one gets.
    func preload(_ adjustments: ImageAdjustments, for url: URL) {
        preload(PhotographProcessingState(adjustments: adjustments), for: url)
    }

    /// Seeds a photograph's complete saved state, capture profile included.
    func preload(_ state: PhotographProcessingState, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        stored[url] = state
    }

    /// Makes this file's record exist and refuse to be read.
    func refuseLoad(for url: URL, with error: PhotographProcessingPersistenceError) {
        lock.lock()
        defer { lock.unlock() }
        loadRefusals[url] = error
    }

    /// Makes every save refuse, as an unwritable volume would.
    func refuseSaves(with error: PhotographProcessingPersistenceError) {
        lock.lock()
        defer { lock.unlock() }
        saveRefusal = error
    }

    /// What is currently recorded for a file, without logging a load.
    /// The adjustments half of what was saved, for the many assertions that
    /// only care about that.
    func saved(for url: URL) -> ImageAdjustments? {
        savedState(for: url)?.adjustments
    }

    /// The complete record that was saved, capture profile included.
    func savedState(for url: URL) -> PhotographProcessingState? {
        lock.lock()
        defer { lock.unlock() }
        return stored[url]
    }

    /// Every write this store accepted, in order, **with the URL it was
    /// written under**.
    ///
    /// The event log records what was saved; this records where. One
    /// document's adjustment reaching another document's sidecar would be
    /// invisible in the first and obvious in the second.
    private(set) var writes: [(url: URL, state: PhotographProcessingState)] = []

    /// The writes, as a comparable list of file name and complete state.
    ///
    /// Every adjustment, because a write is the whole record: a summary that
    /// named only the orientation would show two different complete states as
    /// the same string. The exposure is its exact `Double`, `0.0EV` included,
    /// and so are the two levels bounds.
    var writeSummary: [String] {
        lock.lock()
        defer { lock.unlock() }
        return writes.map {
            """
            \($0.url.lastPathComponent):\($0.state.captureProfile)\
            :\($0.state.adjustments.orientation.persistedToken)\
            :\($0.state.adjustments.channelMix.kind.rawValue)\
            :\($0.state.adjustments.exposure.ev)EV\
            :\($0.state.adjustments.whiteBalance.kind.rawValue)\
            :\($0.state.adjustments.levels.blackPoint)-\($0.state.adjustments.levels.whitePoint)\
            :\($0.state.adjustments.contrast.amount)C
            """
        }
    }

    func load(
        for url: URL
    ) throws(PhotographProcessingPersistenceError) -> PhotographProcessingState? {
        let refusal: PhotographProcessingPersistenceError? = {
            lock.lock()
            defer { lock.unlock() }
            return loadRefusals[url]
        }()
        if let refusal {
            log.append(.adjustmentLoadRefused)
            throw refusal
        }

        let state: PhotographProcessingState? = {
            lock.lock()
            defer { lock.unlock() }
            return stored[url]
        }()
        // The event carries the adjustments half. Which profile was loaded is
        // observed where it has an effect — the capture profile the first
        // preparation ran under — rather than restated in every ordering
        // assertion in the suite.
        log.append(.loadedAdjustments(state?.adjustments))
        return state
    }

    func save(
        _ state: PhotographProcessingState, for url: URL
    ) throws(PhotographProcessingPersistenceError) {
        let refusal: PhotographProcessingPersistenceError? = {
            lock.lock()
            defer { lock.unlock() }
            return saveRefusal
        }()
        if let refusal {
            log.append(.saveRefused(state.adjustments))
            throw refusal
        }

        lock.lock()
        stored[url] = state
        writes.append((url: url, state: state))
        lock.unlock()
        log.append(.saved(state.adjustments))
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
    /// Which complete states this render refuses. Everything else renders
    /// normally.
    ///
    /// A predicate over the **whole** adjustment record, because that is what
    /// a render is asked for. `refusing(orientations:)` spells the common
    /// case for a suite whose subject is geometry.
    var refuses: @Sendable (ImageAdjustments) -> Bool = { _ in false }

    init(log: WorkspaceEventLog) {
        self.log = log
    }

    init(log: WorkspaceEventLog, refusing orientations: [UserOrientationAdjustment]) {
        self.log = log
        self.refuses = { orientations.contains($0.orientation) }
    }

    init(
        log: WorkspaceEventLog,
        refuses: @escaping @Sendable (ImageAdjustments) -> Bool
    ) {
        self.log = log
        self.refuses = refuses
    }

    var render: DocumentState.PreviewRender {
        let log = self.log
        let refuses = self.refuses
        return { source, captureProfile, adjustments, cancellation in
            if refuses(adjustments) {
                log.append(.renderRefused(adjustments))
                throw Refused()
            }
            let preview = try DocumentState.pipelineRender(
                source, captureProfile, adjustments, cancellation
            )
            log.append(.rendered(adjustments))
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

/// A render the test starts, holds, and releases by hand.
///
/// `RecordingRender` counts and refuses; this one also **stops**, which is what
/// a lifecycle test needs: a render that is genuinely in flight while the test
/// does something else, rather than one that has already finished by the time
/// the next line runs.
///
/// Only the adjustments named in `holding` are gated. Everything else renders
/// straight through, so opening a second file while the first one's rotation is
/// held does not deadlock on the second file's own initial render.
///
/// The render itself is the real one, so the pixels a test asserts on are real
/// pixels — and a gated render that is cancelled while held still unwinds as a
/// cancellation, because the pipeline polls the signal after the gate opens.
///
/// ## Why a suite using this must be serialised
///
/// A held render occupies a Swift concurrency cooperative-pool thread for as
/// long as the test holds it. Several at once can exhaust the pool, at which
/// point the render a test is waiting for cannot start and the run deadlocks.
/// Every wait is bounded as a second line of defence, so a mistake of that kind
/// fails the test instead of hanging the run.
final class GatedRender: @unchecked Sendable {
    /// A wait that never returned: a fault in the test, reported rather than
    /// hung.
    struct Stalled: Error {}
    /// A stage saying no, which is nothing like a cancellation.
    struct Refused: Error, LocalizedError {
        var errorDescription: String? { "The gated render refused this adjustment." }
    }

    /// Deliberately far longer than anything healthy. It exists so a genuine
    /// deadlock fails the run instead of hanging it, and it is thirty minutes
    /// rather than ten for the reason `RenderProbe.waitLimit` gives: a full
    /// run with the RAW fixture takes minutes, so a guard of the same order
    /// reports contention as a deadlock.
    static let waitLimit = DispatchTimeInterval.seconds(1800)

    private let lock = NSLock()
    private let holds: @Sendable (ImageAdjustments) -> Bool
    private let refuses: @Sendable (ImageAdjustments) -> Bool
    private let didStart = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    let log: WorkspaceEventLog

    /// Gates and refusals are predicates over the **complete** adjustment
    /// record, because that is what a render is asked for.
    init(
        log: WorkspaceEventLog,
        holds: @escaping @Sendable (ImageAdjustments) -> Bool,
        refuses: @escaping @Sendable (ImageAdjustments) -> Bool
    ) {
        self.log = log
        self.holds = holds
        self.refuses = refuses
    }

    /// A gate with no refusals.
    convenience init(
        log: WorkspaceEventLog,
        holds: @escaping @Sendable (ImageAdjustments) -> Bool
    ) {
        self.init(log: log, holds: holds, refuses: { _ in false })
    }

    /// The common case for a suite whose subject is geometry: gate or refuse
    /// by the orientation term alone.
    convenience init(
        log: WorkspaceEventLog,
        holding orientations: [UserOrientationAdjustment] = [],
        refusing refusals: [UserOrientationAdjustment] = []
    ) {
        self.init(
            log: log,
            holds: { orientations.contains($0.orientation) },
            refuses: { refusals.contains($0.orientation) }
        )
    }

    var render: DocumentState.PreviewRender {
        { [self] source, captureProfile, adjustments, cancellation in
            if withLock({ holds(adjustments) }) {
                didStart.signal()
                guard release.wait(timeout: .now() + Self.waitLimit) == .success else {
                    throw Stalled()
                }
            }
            if withLock({ refuses(adjustments) }) {
                log.append(.renderRefused(adjustments))
                throw Refused()
            }
            let preview = try DocumentState.pipelineRender(
                source, captureProfile, adjustments, cancellation
            )
            log.append(.rendered(adjustments))
            return preview
        }
    }

    /// Suspends until a gated render has begun and is waiting at the gate.
    ///
    /// The blocking wait runs on a global queue, never on the main actor, so
    /// the workspace can keep working while the test waits.
    func waitForGatedRenderToStart() async throws {
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(
                    returning: didStart.wait(timeout: .now() + Self.waitLimit) == .success
                )
            }
        }
        guard started else { throw Stalled() }
    }

    /// Lets one held render past the gate.
    func releaseOneRender() { release.signal() }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// A decoder that serves a different mosaic per URL, so one workspace can open
/// two genuinely different files.
///
/// The geometries are meant to differ: a preview from the wrong file is then
/// visible in its dimensions, not merely in a label.
struct MultiFileStubDecoder: RAWDecoder {
    var mosaics: [URL: DecodedRAWMosaic]
    var log: WorkspaceEventLog?

    func readMetadata(at url: URL) throws -> RAWMetadata {
        try decodeMosaic(at: url).metadata
    }

    func decode(at url: URL, options: RAWDecodeOptions) throws -> DecodedRAW {
        RAWTestData.decodedRAW(url: url)
    }

    func decodeMosaic(at url: URL) throws -> DecodedRAWMosaic {
        log?.append(.decodedMosaic)
        guard let mosaic = mosaics[url] else { throw RAWDecodingError.fileNotFound(url) }
        return mosaic
    }
}


/// The real white-balance preparation, wrapped so a test can count it and make
/// it refuse.
///
/// The preparation itself is genuine — `DocumentState.pipelineSourcePreparation`,
/// the same closure production uses — so the pixels it produces are really
/// balanced, demosaiced and reduced from the retained mosaic. Only the
/// counting and the deliberate refusal are added.
struct RecordingPreparation: Sendable {
    /// A refusal that is nothing like a cancellation: a stage saying no.
    struct Refused: Error, LocalizedError {
        var errorDescription: String? {
            "The stub preparation refused this white balance."
        }
    }

    let log: WorkspaceEventLog
    /// Which white balances this preparation refuses. Everything else prepares
    /// normally.
    var refuses: @Sendable (UserWhiteBalanceAdjustment) -> Bool = { _ in false }

    init(
        log: WorkspaceEventLog,
        refuses: @escaping @Sendable (UserWhiteBalanceAdjustment) -> Bool = { _ in false }
    ) {
        self.log = log
        self.refuses = refuses
    }

    var prepare: DocumentState.SourcePreparation {
        let log = self.log
        let refuses = self.refuses
        return { base, whiteBalance, captureProfile, policy, cancellation in
            let request = SourcePreparationRequest(
                whiteBalance: whiteBalance, captureProfile: captureProfile
            )
            if refuses(whiteBalance) {
                log.append(.preparationRefused(request))
                throw Refused()
            }
            let source = try DocumentState.pipelineSourcePreparation(
                base, whiteBalance, captureProfile, policy, cancellation
            )
            log.append(.preparedSource(request))
            return source
        }
    }
}

/// A white-balance preparation the test starts, holds, and releases by hand.
///
/// The heavy-slot counterpart of `GatedRender`, and it exists for the same
/// reason: the races this milestone has to get right — a superseded patch, an
/// exposure changed mid-preparation, a file switch during one — are only
/// testable while a preparation is genuinely in flight.
///
/// Only the white balances named by `holds` are gated, so a second file's own
/// opening preparation does not deadlock behind the first file's held one.
///
/// ## Why a suite using this must be serialised
///
/// A held preparation occupies a cooperative-pool thread for as long as the
/// test holds it, exactly as a held render does. Every wait is bounded so a
/// mistake fails the test rather than hanging the run.
final class GatedPreparation: @unchecked Sendable {
    struct Stalled: Error {}
    struct Refused: Error, LocalizedError {
        var errorDescription: String? {
            "The gated preparation refused this white balance."
        }
    }

    static let waitLimit = DispatchTimeInterval.seconds(1800)

    private let lock = NSLock()
    private let holds: @Sendable (UserWhiteBalanceAdjustment) -> Bool
    private let refuses: @Sendable (UserWhiteBalanceAdjustment) -> Bool
    private let didStart = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    let log: WorkspaceEventLog

    init(
        log: WorkspaceEventLog,
        holds: @escaping @Sendable (UserWhiteBalanceAdjustment) -> Bool,
        refuses: @escaping @Sendable (UserWhiteBalanceAdjustment) -> Bool = { _ in false }
    ) {
        self.log = log
        self.holds = holds
        self.refuses = refuses
    }

    /// Gates every preparation that is not the default — that is, every one a
    /// user action caused, and none of the ones an open causes.
    convenience init(log: WorkspaceEventLog, holdingPicks: Bool) {
        self.init(log: log, holds: { holdingPicks && !$0.isDefault })
    }

    /// Whether a held pass ignores the cancellation it was handed.
    ///
    /// Off by default, which is production's behaviour: a superseded
    /// preparation stops inside itself and is never delivered. A test that
    /// wants to prove the **delivery guard** — that a source prepared for one
    /// state cannot install into a document that has moved to another — needs a
    /// pass that succeeds despite having been superseded, which is what this
    /// produces.
    var ignoresCancellation = false

    var prepare: DocumentState.SourcePreparation {
        { [self] base, whiteBalance, captureProfile, policy, cancellation in
            let request = SourcePreparationRequest(
                whiteBalance: whiteBalance, captureProfile: captureProfile
            )
            if withLock({ holds(whiteBalance) }) {
                didStart.signal()
                guard release.wait(timeout: .now() + Self.waitLimit) == .success else {
                    throw Stalled()
                }
            }
            if withLock({ refuses(whiteBalance) }) {
                log.append(.preparationRefused(request))
                throw Refused()
            }
            let source = try DocumentState.pipelineSourcePreparation(
                base,
                whiteBalance,
                captureProfile,
                policy,
                withLock({ ignoresCancellation }) ? .none : cancellation
            )
            log.append(.preparedSource(request))
            return source
        }
    }

    /// Suspends until a gated preparation has begun and is waiting at the
    /// gate.
    func waitForGatedPreparationToStart() async throws {
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(
                    returning: didStart.wait(timeout: .now() + Self.waitLimit) == .success
                )
            }
        }
        guard started else { throw Stalled() }
    }

    /// Lets one held preparation past the gate.
    func releaseOnePreparation() { release.signal() }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
