import Foundation
import Testing
@testable import InfraredConverter

/// Synthetic tests for the neutral-patch white-balance estimator. Nothing
/// here touches a RAW file: every sample is constructed, so the per-plane
/// means and therefore the expected gains are known in advance.
@Suite("RAWWhiteBalanceEstimator")
struct RAWWhiteBalanceEstimatorTests {

    // MARK: - Layouts

    /// The reference camera's arrangement: four reachable plane indices even
    /// though `colorCount` is `3`.
    ///
    /// ```text
    /// 0 1     R  G1
    /// 3 2     G2 B
    /// ```
    static let rgbg = RAWTestData.bayerLayout()

    /// A genuine three-plane Bayer layout: both greens are plane `1`, so
    /// plane `3` is never produced anywhere in the CFA.
    ///
    /// ```text
    /// 0 1     R G
    /// 1 2     G B
    /// ```
    static let rggb = RAWTestData.bayerLayout(filters: 0x94949494)

    /// A valid 6×6 X-Trans table with the usual 20 green / 8 red / 8 blue
    /// proportions, using plane indices `0`, `1` and `2` only.
    static let xTransTable: [[Int]] = [
        [1, 1, 0, 1, 1, 2],
        [1, 1, 2, 1, 1, 0],
        [2, 0, 1, 0, 2, 1],
        [1, 1, 2, 1, 1, 0],
        [1, 1, 0, 1, 1, 2],
        [0, 2, 1, 2, 0, 1],
    ]

    static let xTrans = RAWMetadata.SensorColorLayout(
        pattern: .xTrans,
        filters: 9,
        colorDescription: "RGBG",
        colorCount: 3,
        sourceRawBitDepth: 14,
        xTransPattern: xTransTable
    )

    static let linearProcessing = RAWLinearProcessing(
        whiteLevelPolicy: .metadataMaximum,
        whiteLevel: 4095
    )

    // MARK: - Mosaic construction

    static func mosaic(
        width: Int,
        height: Int,
        values: [Float],
        layout: RAWMetadata.SensorColorLayout = rgbg
    ) -> LinearRAWMosaic {
        LinearRAWMosaic(
            width: width,
            height: height,
            values: values,
            sensorColorLayout: layout,
            processing: linearProcessing
        )
    }

    /// Builds a mosaic by handing each colour plane its own list of values,
    /// consumed in scan order. A plane whose list runs out repeats its last
    /// value, so a list of one is a constant plane.
    static func mosaic(
        width: Int,
        height: Int,
        layout: RAWMetadata.SensorColorLayout = rgbg,
        planeValues: [Int: [Float]]
    ) -> LinearRAWMosaic {
        var used = [Int: Int]()
        var values = [Float]()
        values.reserveCapacity(width * height)
        for row in 0..<height {
            for column in 0..<width {
                let plane = layout.colorPlaneIndex(row: row, column: column) ?? 0
                let list = planeValues[plane] ?? [0]
                let position = used[plane, default: 0]
                used[plane] = position + 1
                values.append(list[min(position, list.count - 1)])
            }
        }
        return mosaic(width: width, height: height, values: values, layout: layout)
    }

    static func wholeRegion(_ mosaic: LinearRAWMosaic) -> RAWActiveAreaRegion {
        RAWActiveAreaRegion(
            originRow: 0, originColumn: 0, width: mosaic.width, height: mosaic.height
        )
    }

    // MARK: - The reference RGBG case

    /// A 4×4 RGBG patch, four samples per plane, whose per-plane arithmetic
    /// means are `0.50 / 0.25 / 0.10 / 0.20`.
    ///
    /// The four samples of each plane are spread symmetrically around that
    /// plane's mean rather than being constant, so an implementation that
    /// took a single sample, a minimum or a maximum instead of a mean would
    /// not reproduce these numbers.
    static let rgbgPlaneValues: [Int: [Float]] = [
        0: [0.25, 0.375, 0.625, 0.75],       // mean 0.50
        1: [0.125, 0.1875, 0.3125, 0.375],   // mean 0.25
        2: [0.05, 0.075, 0.125, 0.15],       // mean 0.10
        3: [0.10, 0.15, 0.25, 0.30],         // mean 0.20
    ]

    @Test("A four-plane RGBG patch produces gains that equalise its plane means")
    func rgbgEstimate() throws {
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: Self.rgbgPlaneValues)
        let region = Self.wholeRegion(mosaic)

        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: region)

        // The measured means are the ones the patch was built to have. Planes
        // 0 and 1 are exactly representable in binary; 0.10 and 0.20 are not,
        // so they land on the nearest Float32 and are checked to that.
        let statistics = estimate.statistics
        #expect(statistics.sampleCountsByColorPlane == [4, 4, 4, 4])
        #expect(try #require(statistics.plane0?.mean) == 0.5)
        #expect(try #require(statistics.plane1?.mean) == 0.25)
        #expect(abs(try #require(statistics.plane2?.mean) - 0.10) < 1e-7)
        #expect(abs(try #require(statistics.plane3?.mean) - 0.20) < 1e-7)

        // target = the largest plane mean.
        #expect(estimate.targetMean == 0.5)
        #expect(estimate.scalePolicy == .preserveStrongestMeasuredPlane)
        #expect(estimate.region == region)

        // Every ratio here rounds to an exact Float32, so these are equalities
        // and not tolerances.
        #expect(estimate.gains.gainsByColorPlane == [1.0, 2.0, 5.0, 2.5])
    }

    @Test("Applying the estimate makes all four patch means equal to the target")
    func rgbgAppliedMeansAreEqual() throws {
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: Self.rgbgPlaneValues)
        let region = Self.wholeRegion(mosaic)
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: region)

        let balanced = try RAWWhiteBalancer().apply(to: mosaic, estimate: estimate)
        let means = PatchMeans.perPlane(mosaic: balanced, region: region)

        #expect(means.count == 4)
        for plane in 0..<4 {
            let mean = try #require(means[plane])
            // These particular values multiply exactly, so the tolerance is
            // only what Float32 could have needed, not what it did need.
            #expect(abs(mean - 0.5) < 0.5 * 1e-6, "plane \(plane) mean \(mean)")
        }
    }

    // MARK: - The second green is measured independently

    @Test("Plane 1 and plane 3 get different gains when their means differ")
    func secondGreenIsIndependent() throws {
        // Only the two greens differ; an implementation that averaged them
        // together, or tied them, would produce one gain for both.
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: [
            0: [0.5], 1: [0.25], 2: [0.5], 3: [0.125],
        ])
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))

        #expect(try #require(estimate.statistics.plane1?.mean) == 0.25)
        #expect(try #require(estimate.statistics.plane3?.mean) == 0.125)
        #expect(estimate.gains.plane1 == 2)
        #expect(estimate.gains.plane3 == 4)
        #expect(estimate.gains.plane1 != estimate.gains.plane3)
    }

    // MARK: - CFA addressing

    @Test("Plane 3 is addressed as plane 3, never folded modulo colorCount")
    func planeThreeIsNotFoldedModuloColorCount() throws {
        #expect(Self.rgbg.colorCount == 3)
        #expect(Self.rgbg.colorPlaneIndex(row: 1, column: 0) == 3)
        #expect(try RAWWhiteBalanceEstimator.colorPlanes(in: Self.rgbg) == [0, 1, 2, 3])

        // Plane 0 and plane 3 are given deliberately different means. Under
        // `plane % colorCount` the two would share slot 0, their samples
        // would merge into one mean of 0.375, and neither gain below could
        // come out.
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: [
            0: [0.5], 1: [0.5], 2: [0.5], 3: [0.25],
        ])
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))

        #expect(try #require(estimate.statistics.plane0?.mean) == 0.5)
        #expect(try #require(estimate.statistics.plane3?.mean) == 0.25)
        #expect(estimate.statistics.sampleCountsByColorPlane == [4, 4, 4, 4])
        #expect(estimate.gains.gainsByColorPlane == [1, 1, 1, 2])
    }

    // MARK: - Negative samples

    @Test("Finite negative samples participate in the mean and are not clamped")
    func negativeSamplesParticipate() throws {
        // Plane 2 straddles zero. Its true mean is 0.10, which gives a gain
        // of 5. Clamping the negative to zero would raise the mean to 0.1125
        // and the gain would come out near 4.444 instead.
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: [
            0: [0.5], 1: [0.5], 2: [-0.05, 0.05, 0.15, 0.25], 3: [0.5],
        ])
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))

        let mean = try #require(estimate.statistics.plane2?.mean)
        #expect(abs(mean - 0.10) < 1e-7)
        #expect(estimate.gains.plane2 == 5)
        // The clamping implementation's answer, stated so the test says what
        // it is defending against.
        #expect(abs(estimate.gains.plane2 - 4.4444447) > 0.5)
    }

    @Test("A plane whose samples are all negative fails rather than being made positive")
    func allNegativePlaneFails() {
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: [
            0: [0.5], 1: [0.5], 2: [-0.25, -0.5, -0.125, -0.125], 3: [0.5],
        ])
        #expect {
            try RAWWhiteBalanceEstimator()
                .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))
        } throws: { error in
            guard case .invalidPlaneMean(let plane, let mean) = error as? RAWProcessingError
            else { return false }
            return plane == 2 && mean < 0
        }
    }

    // MARK: - Non-positive means

    @Test("A plane mean of exactly zero is a typed failure, not an infinite gain")
    func zeroPlaneMeanFails() {
        // +0.25, -0.25, +0.5, -0.5 all sum exactly, so this mean is exactly 0.
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: [
            0: [0.5], 1: [0.5], 2: [0.25, -0.25, 0.5, -0.5], 3: [0.5],
        ])
        #expect {
            try RAWWhiteBalanceEstimator()
                .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))
        } throws: { error in
            guard case .invalidPlaneMean(let plane, let mean) = error as? RAWProcessingError
            else { return false }
            return plane == 2 && mean == 0
        }
    }

    // MARK: - Non-finite input

    @Test("A NaN sample inside the patch is reported with its coordinate")
    func nanSampleFails() {
        var values = [Float](repeating: 0.5, count: 16)
        values[2 * 4 + 1] = .nan
        let mosaic = Self.mosaic(width: 4, height: 4, values: values)

        #expect {
            try RAWWhiteBalanceEstimator()
                .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))
        } throws: { error in
            guard case .nonFiniteInputValue(let row, let column, let value) =
                error as? RAWProcessingError
            else { return false }
            return row == 2 && column == 1 && value.isNaN
        }
    }

    @Test("An infinite sample inside the patch is reported with its coordinate")
    func infiniteSampleFails() {
        var values = [Float](repeating: 0.5, count: 16)
        values[3 * 4 + 3] = .infinity
        let mosaic = Self.mosaic(width: 4, height: 4, values: values)

        #expect {
            try RAWWhiteBalanceEstimator()
                .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))
        } throws: { error in
            guard case .nonFiniteInputValue(let row, let column, let value) =
                error as? RAWProcessingError
            else { return false }
            return row == 3 && column == 3 && value == .infinity
        }
    }

    @Test("A non-finite sample outside the requested patch is irrelevant")
    func nonFiniteOutsideThePatchIsIgnored() throws {
        var values = [Float](repeating: 0.5, count: 64)
        values[7 * 8 + 7] = .nan
        let mosaic = Self.mosaic(width: 8, height: 8, values: values)

        // The estimator reads only what the region covers.
        let estimate = try RAWWhiteBalanceEstimator().estimateNeutralPatch(
            in: mosaic,
            region: RAWActiveAreaRegion(originRow: 0, originColumn: 0, width: 4, height: 4)
        )
        #expect(estimate.gains == .identity)
    }

    // MARK: - Missing required plane

    @Test("A patch too small to reach a plane the layout produces is an error")
    func missingRequiredPlaneFails() {
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: Self.rgbgPlaneValues)
        // A single sample is one colour plane. This is precisely why a UI
        // point picker has to sample a patch rather than a pixel.
        let region = RAWActiveAreaRegion(originRow: 0, originColumn: 0, width: 1, height: 1)

        #expect {
            try RAWWhiteBalanceEstimator().estimateNeutralPatch(in: mosaic, region: region)
        } throws: { error in
            guard case .insufficientPatchSamples(let plane, let failedRegion) =
                error as? RAWProcessingError
            else { return false }
            return plane == 1 && failedRegion == region
        }
    }

    @Test("A missing required plane is recorded as measured-with-zero-samples, not as absent")
    func missingRequiredPlaneIsDistinctFromUnused() throws {
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: Self.rgbgPlaneValues)
        let statistics = try RAWWhiteBalanceEstimator().measureNeutralPatch(
            in: mosaic,
            region: RAWActiveAreaRegion(originRow: 0, originColumn: 0, width: 1, height: 1)
        )

        // The distinction the estimator turns into two different outcomes:
        // present slots with no samples (error) versus absent slots (gain 1).
        #expect(statistics.plane0?.sampleCount == 1)
        #expect(statistics.plane1?.sampleCount == 0)
        #expect(statistics.plane1?.mean == nil)
        #expect(statistics.plane2?.sampleCount == 0)
        #expect(statistics.plane3?.sampleCount == 0)
        #expect(statistics.measuredColorPlanes == [0, 1, 2, 3])
    }

    // MARK: - Unused planes

    @Test("A three-plane Bayer layout leaves the unused fourth slot at exactly 1")
    func unusedBayerPlaneIsIdentity() throws {
        #expect(try RAWWhiteBalanceEstimator.colorPlanes(in: Self.rggb) == [0, 1, 2])

        let mosaic = Self.mosaic(width: 4, height: 4, layout: Self.rggb, planeValues: [
            0: [0.5], 1: [0.25], 2: [0.125],
        ])
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))

        // Plane 3 is absent from the layout, so it is not measured and not
        // demanded — it is simply identity.
        #expect(estimate.statistics.plane3 == nil)
        #expect(estimate.statistics.sampleCountsByColorPlane == [4, 8, 4, 0])
        #expect(estimate.gains.gainsByColorPlane == [1, 2, 4, 1])
        #expect(estimate.gains.plane3 == 1)
    }

    // MARK: - X-Trans

    @Test("A 6×6 X-Trans cell discovers exactly the planes its table contains")
    func xTransPlaneDiscovery() throws {
        #expect(try RAWWhiteBalanceEstimator.colorPlanes(in: Self.xTrans) == [0, 1, 2])
        // Not inferred from colorCount, and not four merely because the gain
        // model has four slots.
        #expect(Self.xTrans.colorCount == 3)
    }

    @Test("An X-Trans patch is estimated per actual plane, with the fourth slot identity")
    func xTransEstimate() throws {
        // One full 6×6 cell: 8 samples of plane 0, 20 of plane 1, 8 of plane
        // 2. Each plane's values alternate symmetrically about its mean, and
        // every count is even, so the means are exact.
        let mosaic = Self.mosaic(width: 6, height: 6, layout: Self.xTrans, planeValues: [
            0: [0.5625, 0.4375, 0.5625, 0.4375, 0.5625, 0.4375, 0.5625, 0.4375],
            1: Array(repeating: [0.3125, 0.1875], count: 10).flatMap { $0 },
            2: [0.1875, 0.0625, 0.1875, 0.0625, 0.1875, 0.0625, 0.1875, 0.0625],
        ])
        let region = Self.wholeRegion(mosaic)
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: region)

        // The X-Trans proportions, measured rather than assumed.
        #expect(estimate.statistics.sampleCountsByColorPlane == [8, 20, 8, 0])
        #expect(try #require(estimate.statistics.plane0?.mean) == 0.5)
        #expect(try #require(estimate.statistics.plane1?.mean) == 0.25)
        #expect(try #require(estimate.statistics.plane2?.mean) == 0.125)

        // No nonexistent fourth plane is demanded, and its slot is identity.
        #expect(estimate.statistics.plane3 == nil)
        #expect(estimate.targetMean == 0.5)
        #expect(estimate.gains.gainsByColorPlane == [1, 2, 4, 1])

        // Applying them equalises the three real planes.
        let balanced = try RAWWhiteBalancer().apply(to: mosaic, estimate: estimate)
        let means = PatchMeans.perPlane(mosaic: balanced, region: region)
        #expect(means.count == 3)
        for plane in 0..<3 {
            #expect(try #require(means[plane]) == 0.5)
        }
    }

    @Test("A malformed X-Trans table is refused rather than assumed to be Bayer")
    func malformedXTransIsRefused() {
        let malformed = RAWMetadata.SensorColorLayout(
            pattern: .xTrans,
            filters: 9,
            colorDescription: "RGBG",
            colorCount: 3,
            xTransPattern: [[0, 1, 2], [1, 0, 1]]
        )
        #expect {
            _ = try RAWWhiteBalanceEstimator.colorPlanes(in: malformed)
        } throws: { error in
            guard case .unsupportedSensorLayoutForEstimation(let pattern, _) =
                error as? RAWProcessingError
            else { return false }
            return pattern == .xTrans
        }
    }

    // MARK: - Layouts with no per-plane mosaic

    @Test("Foveon, full-colour and unknown layouts are typed failures")
    func layoutsWithoutAMosaicAreRefused() {
        for pattern in [
            RAWMetadata.SensorColorLayout.Pattern.foveon, .none, .unknown,
        ] {
            let layout = RAWMetadata.SensorColorLayout(
                pattern: pattern, filters: 0, colorDescription: "RGB", colorCount: 3
            )
            #expect {
                _ = try RAWWhiteBalanceEstimator.colorPlanes(in: layout)
            } throws: { error in
                guard case .unsupportedSensorLayoutForEstimation(let reported, _) =
                    error as? RAWProcessingError
                else { return false }
                return reported == pattern
            }
        }
    }

    @Test("LibRaw's non-standard 16x16 Bayer code is refused, not treated as 2x2")
    func sixteenBySixteenBayerIsRefused() {
        let layout = RAWTestData.bayerLayout(filters: 1)
        #expect {
            _ = try RAWWhiteBalanceEstimator.colorPlanes(in: layout)
        } throws: { error in
            guard case .unsupportedSensorLayoutForEstimation(let pattern, _) =
                error as? RAWProcessingError
            else { return false }
            return pattern == .bayer
        }
    }

    // MARK: - Scale policy

    @Test("The strongest measured plane keeps gain 1 and nothing is attenuated")
    func scalePolicyNeverAttenuates() throws {
        for planeValues: [Int: [Float]] in [
            [0: [0.5], 1: [0.25], 2: [0.1], 3: [0.2]],
            [0: [0.05], 1: [0.9], 2: [0.4], 3: [0.4]],
            [0: [2.5], 1: [2.5], 2: [2.5], 3: [2.5]],
            [0: [0.001], 1: [0.002], 2: [0.004], 3: [0.008]],
        ] {
            let mosaic = Self.mosaic(width: 4, height: 4, planeValues: planeValues)
            let estimate = try RAWWhiteBalanceEstimator()
                .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))

            let measured = estimate.statistics.measuredColorPlanes
                .compactMap { estimate.gains.gain(forColorPlane: $0) }
            #expect(measured.count == 4)
            #expect(measured.min() == 1)
            #expect(measured.allSatisfy { $0 >= 1 })
            #expect(measured.allSatisfy { $0.isFinite })

            // The target really is the largest plane mean.
            let means = estimate.statistics.meansByColorPlane.compactMap { $0 }
            #expect(estimate.targetMean == means.max())
        }
    }

    @Test("Equal plane means produce identity gains, not an arbitrary rescale")
    func equalMeansGiveIdentity() throws {
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: [
            0: [0.3], 1: [0.3], 2: [0.3], 3: [0.3],
        ])
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))
        #expect(estimate.gains == .identity)
    }

    @Test("A very small but positive mean yields a very large finite gain, uncapped")
    func smallMeansAreNotCapped() throws {
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: [
            0: [1], 1: [1], 2: [1e-7], 3: [1],
        ])
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))

        // No arbitrary ceiling: infrared white balance legitimately needs
        // extreme multipliers, and this one stays finite.
        #expect(estimate.gains.plane2 > 1e6)
        #expect(estimate.gains.plane2.isFinite)
    }

    @Test("A ratio too large for Float32 is a typed failure, not a clamp")
    func unrepresentableGainFails() {
        // target / mean here is about 7e44, past Float32's maximum of
        // roughly 3.4e38. Note the contrast with the test above: a gain of
        // 1e7 is fine and a gain of 8e37 would also be fine — only what
        // Float32 genuinely cannot hold is refused.
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: [
            0: [1], 1: [1], 2: [Float.leastNonzeroMagnitude], 3: [1],
        ])
        #expect {
            try RAWWhiteBalanceEstimator()
                .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))
        } throws: { error in
            guard case .nonFiniteEstimatedGain(let plane, _, _) = error as? RAWProcessingError
            else { return false }
            return plane == 2
        }
    }

    // MARK: - Sub-regions

    @Test("Only the selected region is measured")
    func onlyTheRegionIsMeasured() throws {
        // A 8×8 mosaic whose right half is far brighter. Measuring the left
        // half must not see it.
        var values = [Float](repeating: 0.25, count: 64)
        for row in 0..<8 {
            for column in 4..<8 { values[row * 8 + column] = 10 }
        }
        let mosaic = Self.mosaic(width: 8, height: 8, values: values)
        let region = RAWActiveAreaRegion(originRow: 2, originColumn: 0, width: 4, height: 4)

        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: region)

        #expect(estimate.statistics.sampleCountsByColorPlane == [4, 4, 4, 4])
        #expect(estimate.targetMean == 0.25)
        #expect(estimate.gains == .identity)
    }

    @Test("An out-of-bounds region fails instead of being cropped to fit")
    func outOfBoundsRegionFails() {
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: Self.rgbgPlaneValues)
        #expect(throws: RAWProcessingError.self) {
            try RAWWhiteBalanceEstimator().estimateNeutralPatch(
                in: mosaic,
                region: RAWActiveAreaRegion(originRow: 0, originColumn: 0, width: 5, height: 4)
            )
        }
    }

    // MARK: - Estimation and application stay separate

    @Test("RAWWhiteBalancer multiplies the estimate's gains literally and adds nothing")
    func applyStageStaysLiteral() throws {
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: Self.rgbgPlaneValues)
        let region = Self.wholeRegion(mosaic)
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: region)

        let balanced = try RAWWhiteBalancer().apply(to: mosaic, estimate: estimate)

        // Every sample is exactly its input times its own plane's estimated
        // gain: no renormalisation, no exposure preservation, no rescale.
        for row in 0..<4 {
            for column in 0..<4 {
                let plane = try #require(mosaic.colorPlaneIndex(row: row, column: column))
                let input = try #require(mosaic.value(row: row, column: column))
                let gain = try #require(estimate.gains.gain(forColorPlane: plane))
                #expect(try #require(balanced.value(row: row, column: column)) == input * gain)
            }
        }

        // The gains recorded in provenance are the gains that were multiplied.
        #expect(balanced.processing.gains == estimate.gains)
    }

    @Test("Scaling an estimate's gains scales the output, proving no renormalisation")
    func applyStageDoesNotRenormalise() throws {
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: Self.rgbgPlaneValues)
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))
        let balancer = RAWWhiteBalancer()

        let asEstimated = try balancer.apply(to: mosaic, estimate: estimate)
        var doubled = estimate.gains
        doubled.plane0 *= 2
        doubled.plane1 *= 2
        doubled.plane2 *= 2
        doubled.plane3 *= 2
        let asDoubled = try balancer.apply(to: mosaic, gains: doubled)

        // If the apply stage renormalised in any way, these would match.
        for index in asEstimated.values.indices {
            #expect(asDoubled.values[index] == asEstimated.values[index] * 2)
        }
    }

    // MARK: - Provenance

    @Test("Provenance records the region, statistics, target and policy, not the gains again")
    func provenanceExplainsTheGains() throws {
        let mosaic = Self.mosaic(width: 8, height: 8, planeValues: Self.rgbgPlaneValues)
        let region = RAWActiveAreaRegion(originRow: 2, originColumn: 2, width: 4, height: 4)
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: region)

        let balanced = try RAWWhiteBalancer().apply(to: mosaic, estimate: estimate)
        guard case .neutralPatch(let source) = balanced.processing.gainSource else {
            Issue.record("expected a neutral-patch source, got \(balanced.processing.gainSource)")
            return
        }

        #expect(source.region == region)
        #expect(source.scalePolicy == .preserveStrongestMeasuredPlane)
        #expect(source.targetMean == estimate.targetMean)
        #expect(source.statistics == estimate.statistics)
        #expect(source.statistics.sampleCountsByColorPlane == [4, 4, 4, 4])

        // The gains live once, on `processing.gains`, so the record of what
        // was applied cannot disagree with the record of how it was chosen.
        #expect(balanced.processing.gains == estimate.gains)
    }

    @Test("Explicit gains still work and still record an explicit source")
    func explicitGainsAreUnchanged() throws {
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: Self.rgbgPlaneValues)
        let gains = RAWWhiteBalanceGains(plane0: 2, plane1: 3, plane2: 4, plane3: 5)

        let balanced = try RAWWhiteBalancer().apply(to: mosaic, gains: gains)

        #expect(balanced.processing.gains == gains)
        #expect(balanced.processing.gainSource == .explicit)
    }

    // MARK: - The estimate/provenance invariant

    // These pin the shape of the public API, not just one call's behaviour.
    // Two things are being asserted together:
    //
    //   1. every public apply either records `.explicit` or records the
    //      provenance of the estimate it was handed — there is no third
    //      possibility, because no public method accepts a
    //      `RAWWhiteBalanceSource`;
    //   2. an estimate's gains and its provenance always describe the same
    //      measurement, because `RAWWhiteBalanceEstimate` is immutable and
    //      only the estimator can mint one.
    //
    // The compile-time half — that `apply(to:gains:gainSource:)` no longer
    // exists and that these records cannot be constructed outside the module
    // — cannot be expressed as a passing test, since these tests are inside
    // the module. It is enforced by the access levels themselves.

    @Test("Every explicit-gain overload records .explicit, on all three shapes")
    func explicitOverloadsAlwaysRecordExplicit() throws {
        let processed = try RAWWhiteBalanceReprocessingTests.processed()
        let gains = RAWWhiteBalanceGains(plane0: 2, plane1: 3, plane2: 4, plane3: 5)
        let balancer = RAWWhiteBalancer()

        let bare = try balancer.apply(to: processed.mosaic, gains: gains)
        #expect(bare.processing.gainSource == .explicit)

        let wrapped = try balancer.apply(to: processed, gains: gains)
        #expect(wrapped.processing.gainSource == .explicit)

        let replaced = try balancer.apply(
            gains: RAWWhiteBalanceGains(plane0: 5, plane1: 4, plane2: 3, plane3: 2),
            replacing: wrapped
        )
        #expect(replaced.processing.gainSource == .explicit)
    }

    @Test("Every estimate overload records that same estimate's provenance")
    func estimateOverloadsCarryTheirOwnProvenance() throws {
        let processed = try RAWWhiteBalanceReprocessingTests.processed()
        let estimator = RAWWhiteBalanceEstimator()
        let balancer = RAWWhiteBalancer()
        let region = RAWActiveAreaRegion(originRow: 0, originColumn: 0, width: 2, height: 2)
        let estimate = try estimator.estimateNeutralPatch(in: processed.mosaic, region: region)

        func check(_ processing: RAWWhiteBalanceProcessing) {
            #expect(processing.gains == estimate.gains)
            #expect(processing.gainSource == .neutralPatch(estimate.provenance))
        }

        check(try balancer.apply(to: processed.mosaic, estimate: estimate).processing)

        let wrapped = try balancer.apply(to: processed, estimate: estimate)
        check(wrapped.processing)
        // The estimate overload on a processed mosaic must keep the
        // normalised source reachable, exactly as the explicit one does.
        #expect(wrapped.linearMosaic.values == processed.mosaic.values)

        let replaced = try balancer.apply(estimate: estimate, replacing: wrapped)
        check(replaced.processing)
        #expect(replaced.linearMosaic.values == processed.mosaic.values)
    }

    @Test("Recorded neutral-patch provenance always explains the gains beside it")
    func recordedProvenanceExplainsTheRecordedGains() throws {
        let processed = try RAWWhiteBalanceReprocessingTests.processed()
        let region = RAWActiveAreaRegion(originRow: 0, originColumn: 0, width: 2, height: 2)
        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: processed.mosaic, region: region)
        let balanced = try RAWWhiteBalancer().apply(to: processed, estimate: estimate)

        guard case .neutralPatch(let source) = balanced.processing.gainSource else {
            Issue.record("expected a neutral-patch source")
            return
        }

        // Recompute each gain from the provenance alone. The recorded
        // measurement really is the one that produced the recorded numbers,
        // rather than an unrelated measurement stapled to them.
        for plane in 0..<RAWWhiteBalanceGains.planeCount {
            let gain = try #require(balanced.processing.gains.gain(forColorPlane: plane))
            guard let statistics = source.statistics.statistics(forColorPlane: plane),
                  let mean = statistics.mean
            else {
                #expect(gain == 1)
                continue
            }
            #expect(gain == Float(source.targetMean / mean))
        }
    }

    @Test("Estimation reads a pre-white-balance mosaic and produces no image")
    func estimationProducesNoImage() throws {
        let mosaic = Self.mosaic(width: 4, height: 4, planeValues: Self.rgbgPlaneValues)
        #expect(!mosaic.processing.whiteBalanceApplied)

        let estimate = try RAWWhiteBalanceEstimator()
            .estimateNeutralPatch(in: mosaic, region: Self.wholeRegion(mosaic))

        // The estimator returns numbers, not pixels, and leaves the input
        // untouched.
        _ = estimate.gains
        #expect(mosaic.values == Self.mosaic(width: 4, height: 4,
                                             planeValues: Self.rgbgPlaneValues).values)
    }
}
