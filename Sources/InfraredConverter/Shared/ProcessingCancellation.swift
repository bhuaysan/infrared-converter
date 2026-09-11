import Foundation

/// A cooperative cancellation signal for the long synchronous loops inside the
/// processing stages.
///
/// ## Why the stages need one at all
///
/// `Task.cancel()` on its own only stops a task at its next suspension point.
/// A full-frame permutation or display encode has none: it is one synchronous
/// pass over millions of pixels, so a cancelled task keeps burning a core and
/// a buffer until the pass ends, and the result is then thrown away. Checking
/// after the work is not cancellation — it is only a refusal to install the
/// result.
///
/// So the stages poll. What they poll is this value, at a granularity each one
/// documents, and what they do when it says yes is throw `CancellationError`.
///
/// ## What this is not
///
/// It is not a UI concept and it knows nothing about documents, buttons,
/// coalescing or SwiftUI. It is a `Bool`-returning function with a name — the
/// same shape `RAWWhiteBalancer` takes gains in, and `IRChannelMixer` takes a
/// mix in: something a caller decided, passed explicitly, with a documented
/// no-op default so that every existing caller is unaffected.
///
/// ## The contract a stage must keep
///
/// - **Deterministic.** The poll granularity is stated in the stage's own
///   documentation, so a test can predict exactly how many polls a given
///   image produces.
/// - **No half-finished images.** A cancelled stage throws. It never returns a
///   partially written buffer, and never a plausible-looking one.
/// - **Cancellation is not failure.** `CancellationError` means "nobody wants
///   this any more", which is a different thing from "the image could not be
///   processed". A caller must not report it as a processing error, and the
///   stages deliberately do not fold it into `OrientationError` or
///   `DisplayRenderingError`.
public struct ProcessingCancellation: Sendable {
    private let isCancelledNow: @Sendable () -> Bool

    /// Builds a signal from any predicate.
    ///
    /// The predicate is called from inside a processing loop, so it must be
    /// cheap and must not block.
    public init(_ isCancelled: @escaping @Sendable () -> Bool) {
        self.isCancelledNow = isCancelled
    }

    /// Never cancels.
    ///
    /// The default on every stage, so a caller that has no cancellation story
    /// pays nothing and reads no differently than before.
    public static let none = ProcessingCancellation { false }

    /// Follows the Swift concurrency task the stage is running inside.
    ///
    /// This is what an application-layer caller normally wants: cancelling the
    /// task that owns the render stops the render.
    public static let enclosingTask = ProcessingCancellation { Task.isCancelled }

    /// Whether the work has been superseded.
    public var isCancelled: Bool { isCancelledNow() }

    /// Abandons the work if it has been superseded.
    ///
    /// - Throws: `CancellationError`, and nothing else.
    public func check() throws {
        if isCancelledNow() { throw CancellationError() }
    }
}
