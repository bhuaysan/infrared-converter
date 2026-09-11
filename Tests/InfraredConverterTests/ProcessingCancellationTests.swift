import Testing
import Foundation
@testable import InfraredConverter

/// Cooperative cancellation inside the two full-frame stages.
///
/// Every test here measures **how much work was actually done**, not merely
/// what came back. A stage that ran the whole pass and then threw would pass a
/// throws-based test and fail every test in this suite, which is the point:
/// the bug this milestone fixes was a cancellation check placed after the
/// work.
@Suite("Processing cancellation")
struct ProcessingCancellationTests {

    /// A tall image, so "stopped after three rows" and "ran to the end" are
    /// numbers far enough apart to be unmistakable.
    static let rows = 100
    static let columns = 4

    static func channelMixed() -> IRChannelMixedRGBImage {
        let values = (0..<(rows * columns * 3)).map { Float($0) / 10_000 }
        return DisplayPreviewTestData.channelMixedImage(
            width: columns, height: rows, values: values
        )
    }

    static func oriented() -> OrientedSceneLinearRGBImage {
        let values = (0..<(rows * columns * 3)).map { Float($0) / 10_000 }
        return DisplayPreviewTestData.image(width: columns, height: rows, values: values)
    }

    // MARK: - The default is unchanged behaviour

    @Test("A stage with no cancellation signal behaves exactly as before")
    func theDefaultIsNoCancellation() throws {
        let oriented = try ImageOrienter()
            .apply(to: Self.channelMixed(), orientation: .rotated90Clockwise)
        let preview = try DisplayPreviewRenderer()
            .render(oriented, settings: DisplayPreviewTestData.settings(exposureEV: 0))

        #expect(oriented.width == Self.rows)
        #expect(oriented.height == Self.columns)
        #expect(preview.width == Self.rows)
        #expect(preview.height == Self.columns)
    }

    @Test("A signal that never fires is polled once per row plus once at entry")
    func aCompleteRunPollsOncePerRow() throws {
        let orienterProbe = CancellationProbe()
        let oriented = try ImageOrienter().apply(
            to: Self.channelMixed(),
            orientation: .rotated90Clockwise,
            cancellation: orienterProbe.cancellation
        )
        // Rotating a 4 × 100 image gives 100 × 4: four destination rows.
        #expect(oriented.height == Self.columns)
        #expect(orienterProbe.pollCount == 1 + Self.columns)

        let rendererProbe = CancellationProbe()
        _ = try DisplayPreviewRenderer().render(
            oriented,
            settings: DisplayPreviewTestData.settings(exposureEV: 0),
            cancellation: rendererProbe.cancellation
        )
        #expect(rendererProbe.pollCount == 1 + Self.columns)
    }

    // MARK: - ImageOrienter

    @Test("A cancelled orientation throws before it allocates anything")
    func anOrienterCancelledAtEntryDoesNoWork() {
        let probe = CancellationProbe(cancelAfterPolls: 1)
        #expect(throws: CancellationError.self) {
            try ImageOrienter().apply(
                to: Self.channelMixed(),
                orientation: .rotated90Clockwise,
                cancellation: probe.cancellation
            )
        }
        // Exactly one poll: the entry check refused, and not a single
        // destination row was begun.
        #expect(probe.pollCount == 1)
    }

    @Test("An orientation cancelled mid-pass abandons the remaining rows")
    func anOrienterStopsInsideThePass() {
        // 100 × 4 output: entry poll, then one per destination row. Cancelling
        // on the third poll stops after the first destination row.
        let probe = CancellationProbe(cancelAfterPolls: 3)
        #expect(throws: CancellationError.self) {
            try ImageOrienter().apply(
                to: Self.channelMixed(),
                orientation: .rotated90Clockwise,
                cancellation: probe.cancellation
            )
        }
        #expect(probe.pollCount == 3)
        #expect(probe.pollCount < 1 + Self.columns)
    }

    @Test("Even the free identity path refuses superseded work")
    func anUprightOrientationIsStillCancellable() {
        let probe = CancellationProbe(cancelAfterPolls: 1)
        #expect(throws: CancellationError.self) {
            try ImageOrienter().apply(
                to: Self.channelMixed(),
                orientation: .upright,
                cancellation: probe.cancellation
            )
        }
    }

    @Test("A cancelled orientation returns no image, not a partial one")
    func anOrienterReturnsNothingWhenCancelled() {
        let probe = CancellationProbe(cancelAfterPolls: 2)
        let result = Result {
            try ImageOrienter().apply(
                to: Self.channelMixed(),
                orientation: .rotated90Clockwise,
                cancellation: probe.cancellation
            )
        }
        guard case .failure(let error) = result else {
            Issue.record("Expected the orientation to be abandoned")
            return
        }
        #expect(error is CancellationError)
        // And not folded into the stage's own error type: nothing was wrong
        // with the image.
        #expect(!(error is OrientationError))
    }

    // MARK: - DisplayPreviewRenderer

    @Test("A cancelled display render throws before it allocates anything")
    func aRendererCancelledAtEntryDoesNoWork() {
        let probe = CancellationProbe(cancelAfterPolls: 1)
        #expect(throws: CancellationError.self) {
            try DisplayPreviewRenderer().render(
                Self.oriented(),
                settings: DisplayPreviewTestData.settings(exposureEV: 0),
                cancellation: probe.cancellation
            )
        }
        #expect(probe.pollCount == 1)
    }

    @Test("A display render cancelled mid-pass abandons the remaining rows")
    func aRendererStopsInsideThePass() {
        let probe = CancellationProbe(cancelAfterPolls: 4)
        #expect(throws: CancellationError.self) {
            try DisplayPreviewRenderer().render(
                Self.oriented(),
                settings: DisplayPreviewTestData.settings(exposureEV: 0),
                cancellation: probe.cancellation
            )
        }
        // Three rows of a hundred were begun, and ninety-seven were not.
        #expect(probe.pollCount == 4)
        #expect(probe.pollCount < 1 + Self.rows)
    }

    @Test("A cancelled display render returns no image, not a partial one")
    func aRendererReturnsNothingWhenCancelled() {
        let probe = CancellationProbe(cancelAfterPolls: 5)
        let result = Result {
            try DisplayPreviewRenderer().render(
                Self.oriented(),
                settings: DisplayPreviewTestData.settings(exposureEV: 0),
                cancellation: probe.cancellation
            )
        }
        guard case .failure(let error) = result else {
            Issue.record("Expected the render to be abandoned")
            return
        }
        #expect(error is CancellationError)
        #expect(!(error is DisplayRenderingError))
    }

    // MARK: - The pipeline forwards it

    @Test("The workspace pipeline's cheap half stops inside the pass too")
    func thePipelineForwardsCancellation() throws {
        let url = URL(fileURLWithPath: "/tmp/example.orf")
        let decoder = WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: url))
        )
        let pipeline = WorkspacePreviewPipeline()
        let source = try pipeline.prepare(decoding: url, using: decoder)

        let probe = CancellationProbe(cancelAfterPolls: 1)
        #expect(throws: CancellationError.self) {
            try pipeline.render(
                source,
                adjustments: ImageAdjustments(orientation: .quarterTurnRight),
                cancellation: probe.cancellation
            )
        }
        #expect(probe.pollCount == 1)

        // And with no signal it renders exactly as it always did.
        let preview = try pipeline.render(
            source, adjustments: ImageAdjustments(orientation: .quarterTurnRight)
        )
        #expect(preview.userOrientationAdjustment == .quarterTurnRight)
    }
}
