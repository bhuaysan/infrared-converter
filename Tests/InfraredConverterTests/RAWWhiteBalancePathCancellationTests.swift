import Testing
import Foundation
@testable import InfraredConverter

/// The mosaic-domain half of the pipeline, stopped in the middle.
///
/// These four stages used to run to completion whatever happened, which was
/// tolerable while they only ran when a file was opened. They are now on the
/// path a user re-triggers by clicking a neutral patch, so a superseded pass
/// that kept working would compete for a core and a buffer with the one whose
/// result the user is waiting for.
///
/// Every test here asserts on the **poll count**, not merely on the throw. A
/// stage that checked once at the end and threw would satisfy "it throws" and
/// would not be cancellation at all.
@Suite("Mosaic-domain cancellation")
struct RAWWhiteBalancePathCancellationTests {

    /// A mosaic with a known number of rows, so a poll count means something.
    static func mosaic(width: Int = 8, height: Int = 6) throws -> LinearRAWMosaic {
        var values = [Float]()
        values.reserveCapacity(width * height)
        for index in 0..<(width * height) {
            // Strictly positive and all different, so every plane measures a
            // usable mean and no two planes accidentally agree.
            values.append(Float(index % 97 + 1) / 128)
        }
        return LinearRAWMosaic(
            width: width,
            height: height,
            values: values,
            sensorColorLayout: RAWTestData.bayerLayout(),
            processing: RAWLinearProcessing(whiteLevelPolicy: .metadataMaximum, whiteLevel: 4095)
        )
    }

    static func region(_ mosaic: LinearRAWMosaic) -> RAWActiveAreaRegion {
        RAWActiveAreaRegion(
            originRow: 0, originColumn: 0, width: mosaic.width, height: mosaic.height
        )
    }

    static func estimate(_ mosaic: LinearRAWMosaic) throws -> RAWWhiteBalanceEstimate {
        try RAWWhiteBalanceEstimator().estimateNeutralPatch(
            in: mosaic, region: region(mosaic)
        )
    }

    // MARK: - The estimator

    @Test("An uncancelled estimate polls once before the walk and once per region row")
    func theEstimatorPollsPerRegionRow() throws {
        let mosaic = try Self.mosaic(width: 8, height: 6)
        let probe = CancellationProbe()
        _ = try RAWWhiteBalanceEstimator().estimateNeutralPatch(
            in: mosaic, region: Self.region(mosaic), cancellation: probe.cancellation
        )
        #expect(probe.pollCount == 1 + 6)
    }

    @Test("An estimate cancelled before it starts does no work at all")
    func theEstimatorStopsBeforeWalking() throws {
        let mosaic = try Self.mosaic()
        let probe = CancellationProbe(cancelAfterPolls: 1)
        #expect(throws: CancellationError.self) {
            try RAWWhiteBalanceEstimator().estimateNeutralPatch(
                in: mosaic, region: Self.region(mosaic), cancellation: probe.cancellation
            )
        }
        #expect(probe.pollCount == 1)
    }

    @Test("An estimate cancelled part way stops at that row")
    func theEstimatorStopsMidWalk() throws {
        let mosaic = try Self.mosaic(width: 8, height: 6)
        let probe = CancellationProbe(cancelAfterPolls: 3)
        #expect(throws: CancellationError.self) {
            try RAWWhiteBalanceEstimator().measureNeutralPatch(
                in: mosaic, region: Self.region(mosaic), cancellation: probe.cancellation
            )
        }
        // Three polls: the pre-walk check, row 0, and row 1 — where it stopped.
        #expect(probe.pollCount == 3)
    }

    // MARK: - The balancer

    @Test("An uncancelled balance polls once before allocating and once per row")
    func theBalancerPollsPerRow() throws {
        let mosaic = try Self.mosaic(width: 8, height: 6)
        let probe = CancellationProbe()
        _ = try RAWWhiteBalancer().apply(
            to: mosaic, gains: .identity, cancellation: probe.cancellation
        )
        #expect(probe.pollCount == 1 + 6)
    }

    @Test("A balance cancelled before it starts allocates nothing")
    func theBalancerStopsBeforeAllocating() throws {
        let mosaic = try Self.mosaic()
        let probe = CancellationProbe(cancelAfterPolls: 1)
        #expect(throws: CancellationError.self) {
            try RAWWhiteBalancer().apply(
                to: mosaic, gains: .identity, cancellation: probe.cancellation
            )
        }
        #expect(probe.pollCount == 1)
    }

    @Test("A balance cancelled part way throws rather than returning a partial mosaic")
    func theBalancerStopsMidPass() throws {
        let mosaic = try Self.mosaic(width: 8, height: 6)
        let probe = CancellationProbe(cancelAfterPolls: 4)
        #expect(throws: CancellationError.self) {
            try RAWWhiteBalancer().apply(
                to: mosaic, estimate: try Self.estimate(mosaic),
                cancellation: probe.cancellation
            )
        }
        #expect(probe.pollCount == 4)
    }

    // MARK: - The demosaicer

    @Test("An uncancelled demosaic polls once before allocating and once per row")
    func theDemosaicerPollsPerRow() throws {
        let mosaic = try Self.mosaic(width: 8, height: 6)
        let balanced = try RAWWhiteBalancer().apply(to: mosaic, gains: .identity)
        let probe = CancellationProbe()
        _ = try RAWDemosaicer().demosaic(balanced, cancellation: probe.cancellation)
        #expect(probe.pollCount == 1 + 6)
    }

    @Test("A demosaic cancelled part way throws rather than returning a partial image")
    func theDemosaicerStopsMidPass() throws {
        let mosaic = try Self.mosaic(width: 8, height: 6)
        let balanced = try RAWWhiteBalancer().apply(to: mosaic, gains: .identity)
        let probe = CancellationProbe(cancelAfterPolls: 2)
        #expect(throws: CancellationError.self) {
            try RAWDemosaicer().demosaic(balanced, cancellation: probe.cancellation)
        }
        #expect(probe.pollCount == 2)
    }

    // MARK: - The working-colour conversion

    /// Both paths poll: the identity path, which hands the same buffer back
    /// and only sweeps for non-finite values, and the general one.
    @Test("An uncancelled conversion polls once before starting and once per row")
    func theConverterPollsPerRow() throws {
        let mosaic = try Self.mosaic(width: 8, height: 6)
        let balanced = try RAWWhiteBalancer().apply(to: mosaic, gains: .identity)
        let demosaiced = try RAWDemosaicer().demosaic(balanced)

        for transform in [
            RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor,
            .explicit(matrix: try PreviewTestData.asymmetricMatrix()),
        ] {
            let probe = CancellationProbe()
            _ = try RAWWorkingColorConverter().convert(
                demosaiced, using: transform, cancellation: probe.cancellation
            )
            #expect(probe.pollCount == 1 + 6, "\(transform.source)")
        }
    }

    @Test("A conversion cancelled part way throws on both paths")
    func theConverterStopsMidPass() throws {
        let mosaic = try Self.mosaic(width: 8, height: 6)
        let balanced = try RAWWhiteBalancer().apply(to: mosaic, gains: .identity)
        let demosaiced = try RAWDemosaicer().demosaic(balanced)

        for transform in [
            RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor,
            .explicit(matrix: try PreviewTestData.asymmetricMatrix()),
        ] {
            let probe = CancellationProbe(cancelAfterPolls: 3)
            #expect(throws: CancellationError.self) {
                try RAWWorkingColorConverter().convert(
                    demosaiced, using: transform, cancellation: probe.cancellation
                )
            }
            #expect(probe.pollCount == 3, "\(transform.source)")
        }
    }

    // MARK: - The whole heavy half

    /// What a superseded neutral patch actually gets: the chain stops inside
    /// the first stage that notices, and nothing downstream of it runs.
    @Test("A cancelled white-balance preparation stops in its first stage")
    func theHeavyHalfStopsEarly() throws {
        let decoder = WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: Self.url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: Self.url, width: 16, height: 12))
        )
        let base = try RAWBasePreparationPipeline().prepare(
            decoding: Self.url, using: decoder
        )
        let probe = CancellationProbe(cancelAfterPolls: 1)

        #expect(throws: CancellationError.self) {
            try WorkspacePreviewPipeline().prepareSource(
                base,
                whiteBalance: .defaultNeutralPatch,
                captureProfile: .builtinUncalibrated,
                policy: WorkspacePreviewPipeline.previewPolicy,
                cancellation: probe.cancellation
            )
        }
        // One poll: the estimator's pre-walk check. Nothing measured, nothing
        // balanced, nothing demosaiced, nothing reduced.
        #expect(probe.pollCount == 1)
    }

    /// Cancellation is not a processing failure, and the type says so: it is
    /// `CancellationError`, never a `RAWProcessingError`.
    @Test("A cancelled stage throws cancellation, not a processing error")
    func cancellationIsNotAProcessingFailure() throws {
        let mosaic = try Self.mosaic()
        let probe = CancellationProbe(cancelAfterPolls: 1)
        do {
            _ = try RAWWhiteBalancer().apply(
                to: mosaic, gains: .identity, cancellation: probe.cancellation
            )
            Issue.record("Expected the balance to be cancelled")
        } catch is CancellationError {
            // Exactly this.
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }

    nonisolated static let url = URL(fileURLWithPath: "/tmp/cancellation.orf")
}
