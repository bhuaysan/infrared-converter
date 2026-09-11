import Foundation
@testable import InfraredConverter

/// A cancellation signal a test drives by hand, and can then interrogate.
///
/// The point of the type is the **count**. Asserting that a cancelled stage
/// throws proves only that it noticed; asserting that it polled three times
/// while rendering a hundred-row image proves it stopped after three rows and
/// never did the other ninety-seven. That is the difference between
/// cancellation and discarding a finished result, and it is the difference
/// this milestone is about.
///
/// Nothing here sleeps or races: the flag flips on a poll count the test
/// chooses, so a run is completely deterministic.
final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var polls = 0
    private var cancelAfterPolls: Int?

    /// - Parameter cancelAfterPolls: the poll on which the signal first
    ///   reports cancellation — `1` cancels the very first check. `nil` never
    ///   cancels, which measures how many times a complete run polls.
    init(cancelAfterPolls: Int? = nil) {
        self.cancelAfterPolls = cancelAfterPolls
    }

    /// How many times a stage has asked.
    var pollCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return polls
    }

    /// Cancels from the next poll onward, whatever the count says.
    func cancelNow() {
        lock.lock()
        defer { lock.unlock() }
        cancelAfterPolls = polls + 1
    }

    /// The signal to hand a processing stage.
    var cancellation: ProcessingCancellation {
        ProcessingCancellation { [self] in
            lock.lock()
            defer { lock.unlock() }
            polls += 1
            guard let cancelAfterPolls else { return false }
            return polls >= cancelAfterPolls
        }
    }
}
