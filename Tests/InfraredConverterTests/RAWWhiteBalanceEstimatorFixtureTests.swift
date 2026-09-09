import Testing
import Foundation
@testable import InfraredConverter

/// The neutral-patch estimator against a real RAW file, through the actual
/// pipeline: `RAW file → unpack → RAWMosaic → RAWMosaicNormalizer →
/// LinearRAWMosaic → RAWWhiteBalanceEstimator → RAWWhiteBalancer`.
///
/// ## The numbers here are diagnostic only
///
/// The region below is a geometrically central rectangle, chosen because it is
/// deterministic and large enough to contain all four CFA positions. **No
/// claim is made that it is visually neutral**, that this frame is a grey
/// card, or that the gains it produces are an Olympus E-PL3 calibration, an
/// infrared filter profile, or a recommended starting point for anything.
/// They are a measurement of one rectangle in one file, reported so the
/// estimator's arithmetic can be checked against real data instead of only
/// against synthetic patches.
///
/// These require a local fixture (see `RAWFixtures`) and skip cleanly without
/// it.
@Suite(
    "RAWWhiteBalanceEstimator integration",
    .enabled(if: RAWFixtures.isAvailable, "\(RAWFixtures.unavailableReason)")
)
struct RAWWhiteBalanceEstimatorFixtureTests {
    /// A 64×64 patch at the centre of the 4056×3040 active area.
    ///
    /// Both origin coordinates are even, so the patch starts on the same CFA
    /// phase as the top-left of the image, and 64×64 gives 1024 samples of
    /// each of the four planes — enough that a mean is not dominated by a
    /// handful of samples. Scanning the whole 12-megapixel frame would tell us
    /// nothing extra about the estimator and would make the test slow.
    static let diagnosticRegion = RAWActiveAreaRegion(
        originRow: 1488, originColumn: 1996, width: 64, height: 64
    )

    /// A relative tolerance for comparing a post-white-balance patch mean
    /// against the target.
    ///
    /// Each balanced sample is one Float32 multiply (relative error up to
    /// `2^-24 ≈ 6e-8`), the gain itself was rounded once to Float32 (another
    /// `6e-8`), and the 1024 products are then summed in Double, which adds
    /// nothing material. `1e-6` is roughly an order of magnitude above that
    /// floor: tight enough that a real renormalisation or clamp would fail
    /// it, loose enough not to be a coin flip.
    static let relativeTolerance = 1e-6

    private static func processFixture() throws -> ProcessedRAWMosaic {
        let url = try #require(RAWFixtures.olympusORF)
        let decoded = try LibRawDecoder().decodeMosaic(at: url)
        return try RAWMosaicNormalizer().process(decoded)
    }

    // MARK: - Estimation

    @Test("The diagnostic patch measures all four CFA planes independently")
    func allFourPlanesAreMeasured() throws {
        let processed = try Self.processFixture()
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: processed.mosaic, region: Self.diagnosticRegion)
        let statistics = estimate.statistics

        // 64×64 on a 2×2 CFA: 1024 samples of every plane, including plane 3.
        #expect(statistics.sampleCountsByColorPlane == [1024, 1024, 1024, 1024])
        #expect(statistics.measuredColorPlanes == [0, 1, 2, 3])
        #expect(processed.mosaic.sensorColorLayout.colorCount == 3)
        #expect(processed.mosaic.sensorColorLayout.colorDescription == "RGBG")

        // The two greens are separate measurements over separate samples, not
        // one number written into two slots.
        let g1 = try #require(statistics.plane1?.mean)
        let g2 = try #require(statistics.plane3?.mean)
        #expect(g1 != g2)
        #expect(estimate.gains.plane1 != estimate.gains.plane3)

        // Each gain comes from its own plane's mean.
        for plane in 0..<4 {
            let mean = try #require(statistics.statistics(forColorPlane: plane)?.mean)
            let gain = Double(try #require(estimate.gains.gain(forColorPlane: plane)))
            #expect(abs(mean * gain - estimate.targetMean)
                    < estimate.targetMean * Self.relativeTolerance)
        }
    }

    @Test("The scale policy holds on real data: one gain is 1 and none is below it")
    func scalePolicyHoldsOnRealData() throws {
        let processed = try Self.processFixture()
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: processed.mosaic, region: Self.diagnosticRegion)

        let gains = estimate.gains.gainsByColorPlane
        #expect(gains.min() == 1)
        #expect(gains.allSatisfy { $0 >= 1 })
        #expect(gains.allSatisfy { $0.isFinite })

        // The target is the largest measured plane mean, nothing else.
        let means = estimate.statistics.meansByColorPlane.compactMap { $0 }
        #expect(means.count == 4)
        #expect(estimate.targetMean == means.max())
    }

    // MARK: - Applying the estimate

    @Test("Applying the estimate equalises the patch's four plane means")
    func appliedPatchMeansAreEqual() throws {
        let processed = try Self.processFixture()
        let region = Self.diagnosticRegion
        let estimator = RAWWhiteBalanceEstimator()

        let estimate = try estimator.estimateNeutralPatch(in: processed.mosaic, region: region)
        let balanced = try RAWWhiteBalancer().apply(to: processed, estimate: estimate)

        // Recomputed by a separate, obvious implementation over the balanced
        // buffer, not by asking the estimator about its own output.
        let after = PatchMeans.perPlane(mosaic: balanced.mosaic, region: region)
        #expect(after.count == 4)
        for plane in 0..<4 {
            let mean = try #require(after[plane])
            #expect(abs(mean - estimate.targetMean)
                    < estimate.targetMean * Self.relativeTolerance,
                    "plane \(plane) mean \(mean) vs target \(estimate.targetMean)")
        }
    }

    @Test("Nothing is clamped when an estimate is applied")
    func nothingIsClamped() throws {
        let processed = try Self.processFixture()
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: processed.mosaic, region: Self.diagnosticRegion)
        let balanced = try RAWWhiteBalancer().apply(to: processed, estimate: estimate)

        let before = MosaicStatistics(mosaic: processed.mosaic)
        let after = MosaicStatistics(mosaic: balanced.mosaic)

        // Every estimated gain is strictly positive, so no sign can change:
        // the file's 11 sub-black samples are still negative afterwards.
        #expect(before.belowZeroCount == 11)
        #expect(after.belowZeroCount == before.belowZeroCount)
        #expect(after.zeroCount == before.zeroCount)
        #expect(after.minimum < 0)
        #expect(after.nonFiniteCount == 0)
        #expect(!balanced.processing.clamped)

        // Per-plane means scale by their own plane's gain across the whole
        // frame, which they could not if anything were clipped. The tolerance
        // is `relativeTolerance` rather than something tighter because these
        // gains, unlike the small integers the explicit-gain suite uses, are
        // arbitrary Float32 values: each of the three million products
        // carries its own rounding.
        for plane in 0..<4 {
            let mean = try #require(before.perPlaneMean[plane])
            let balancedMean = try #require(after.perPlaneMean[plane])
            let gain = Double(try #require(estimate.gains.gain(forColorPlane: plane)))
            #expect(abs(balancedMean - mean * gain)
                    < abs(mean * gain) * Self.relativeTolerance)
        }
    }

    @Test("Provenance carries the estimate, and the normalised source stays reachable")
    func provenanceAndReachableSource() throws {
        let processed = try Self.processFixture()
        let region = Self.diagnosticRegion
        let estimator = RAWWhiteBalanceEstimator()
        let estimate = try estimator.estimateNeutralPatch(in: processed.mosaic, region: region)
        let balanced = try RAWWhiteBalancer().apply(to: processed, estimate: estimate)

        guard case .neutralPatch(let source) = balanced.processing.gainSource else {
            Issue.record("expected a neutral-patch source, got \(balanced.processing.gainSource)")
            return
        }
        #expect(source.region == region)
        #expect(source.scalePolicy == .preserveStrongestMeasuredPlane)
        #expect(source.statistics == estimate.statistics)
        #expect(source.targetMean == estimate.targetMean)
        #expect(balanced.processing.gains == estimate.gains)

        // The pre-white-balance mosaic is intact, so a later re-estimate reads
        // the same normalised samples this one did.
        #expect(balanced.linearMosaic.values == processed.mosaic.values)
        #expect(!balanced.linearMosaic.processing.whiteBalanceApplied)

        let reEstimate = try estimator.estimateNeutralPatch(
            in: balanced.linearMosaic,
            region: RAWActiveAreaRegion(originRow: 0, originColumn: 0, width: 32, height: 32)
        )
        let rebalanced = try RAWWhiteBalancer().apply(estimate: reEstimate, replacing: balanced)

        // Re-balancing restarts from the normalised mosaic: gains do not
        // compound, and the source is unchanged.
        for (row, column) in [(0, 0), (100, 101), (3039, 4055)] {
            let input = try #require(processed.mosaic.value(row: row, column: column))
            let plane = try #require(processed.mosaic.colorPlaneIndex(row: row, column: column))
            let gain = try #require(reEstimate.gains.gain(forColorPlane: plane))
            #expect(try #require(rebalanced.mosaic.value(row: row, column: column))
                    == input * gain)
        }
        #expect(rebalanced.linearMosaic.values == processed.mosaic.values)
    }

    // MARK: - Diagnostics

    /// Reports the concrete numbers for the diagnostic patch.
    ///
    /// > Every gain printed here is **diagnostic only**: a measurement of one
    /// > rectangle in one file. It is not a calibration, not a filter profile
    /// > and not a recommendation.
    @Test("Diagnostic: neutral-patch estimate for the Olympus E-PL3 fixture")
    func diagnosticEstimate() throws {
        let processed = try Self.processFixture()
        let region = Self.diagnosticRegion
        let estimator = RAWWhiteBalanceEstimator()

        let start = DispatchTime.now().uptimeNanoseconds
        let estimate = try estimator.estimateNeutralPatch(in: processed.mosaic, region: region)
        let estimateMilliseconds =
            Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000

        let balanced = try RAWWhiteBalancer().apply(to: processed, estimate: estimate)
        let before = PatchMeans.perPlane(mosaic: processed.mosaic, region: region)
        let after = PatchMeans.perPlane(mosaic: balanced.mosaic, region: region)

        var report = "\n--- Neutral-patch estimate diagnostic (Olympus E-PL3 fixture) ---\n"
        report += "DIAGNOSTIC ONLY: not a calibration, filter profile or recommendation.\n"
        report += "mosaic: \(processed.mosaic.width) x \(processed.mosaic.height)\n"
        report += "region: origin row \(region.originRow), column \(region.originColumn), "
        report += "size \(region.width)x\(region.height) "
        report += "(\(region.sampleCount.map(String.init) ?? "?") samples)\n"
        report += "scale policy: \(estimate.scalePolicy)\n"
        report += "per-plane sample counts: \(estimate.statistics.sampleCountsByColorPlane)\n"
        report += "per-plane means before WB: \(estimate.statistics.meansByColorPlane)\n"
        report += "target mean: \(estimate.targetMean)\n"
        report += "estimated gains: \(estimate.gains.gainsByColorPlane)\n"
        report += "patch means before WB: \(before.sorted { $0.key < $1.key })\n"
        report += "patch means after WB:  \(after.sorted { $0.key < $1.key })\n"
        report += "estimate time (debug build): \(estimateMilliseconds) ms\n"
        report += "-----------------------------------------------------------------\n"
        print(report)

        #expect(estimate.gains.gainsByColorPlane.allSatisfy { $0.isFinite })
    }
}
