import Foundation
@testable import InfraredConverter

/// A stand-in for the full-resolution export, which records exactly which
/// snapshot reached it and can be held open at a gate.
///
/// It records the `ExportRequest` rather than a description of one: the whole
/// point of these tests is *which* URL and *which* adjustments an export was
/// given, and a string could agree by accident.
final class RecordingExport: @unchecked Sendable {
    struct Refused: Error, LocalizedError {
        var errorDescription: String? { "The stub export refused this request." }
    }
    struct Stalled: Error {}

    static let waitLimit = DispatchTimeInterval.seconds(1800)

    private let lock = NSLock()
    private var requests: [(request: ExportRequest, destination: URL)] = []
    private let holds: @Sendable (ExportRequest) -> Bool
    private let outcome: @Sendable (ExportRequest) -> Error?
    private let didStart = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    init(
        holds: @escaping @Sendable (ExportRequest) -> Bool = { _ in false },
        failing outcome: @escaping @Sendable (ExportRequest) -> Error? = { _ in nil }
    ) {
        self.holds = holds
        self.outcome = outcome
    }

    /// Every export that was started, in order.
    var started: [(request: ExportRequest, destination: URL)] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    var startedCount: Int { started.count }

    var run: DocumentState.ExportRun {
        { [self] request, destination, _ in
            lock.lock()
            requests.append((request: request, destination: destination))
            let shouldHold = holds(request)
            lock.unlock()

            if shouldHold {
                didStart.signal()
                guard release.wait(timeout: .now() + Self.waitLimit) == .success else {
                    throw Stalled()
                }
            }
            if let error = outcome(request) { throw error }

            return TIFFExportResult(
                destination: destination,
                sourceURL: request.rawURL,
                adjustments: request.adjustments,
                pixelWidth: 4056,
                pixelHeight: 3040,
                bitsPerComponent: 16,
                channelCount: 3,
                clippedLowSampleCount: 0,
                clippedHighSampleCount: 0,
                fileSizeBytes: 1234
            )
        }
    }

    func waitForGatedExportToStart() async throws {
        let started = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(
                    returning: didStart.wait(timeout: .now() + Self.waitLimit) == .success
                )
            }
        }
        guard started else { throw Stalled() }
    }

    func releaseOneExport() { release.signal() }
}
