import Testing
import Foundation
@testable import InfraredConverter

/// The full-resolution exposure stage: scene-linear in, scene-linear out,
/// nothing clipped and nothing encoded.
@Suite("Scene-linear exposer")
struct SceneLinearExposerTests {

    private static func image(
        _ values: [Float],
        width: Int = 2,
        height: Int = 1,
        orientation: RAWImageOrientation = .upright,
        mix: IRChannelMix = .identity
    ) -> OrientedSceneLinearRGBImage {
        ExportTestData.oriented(
            width: width, height: height, values: values,
            orientation: orientation, mix: mix
        )
    }

    // MARK: - The arithmetic

    @Test("A stop up doubles every component")
    func aStopUpDoubles() throws {
        let source = Self.image([0.1, 0.2, 0.3, -0.4, 0.5, 1.5])
        let exposed = try SceneLinearExposer().apply(
            to: source, exposure: SceneLinearExposure(ev: 1)
        )
        #expect(exposed.width == 2)
        #expect(exposed.height == 1)
        for (index, value) in source.values.enumerated() {
            #expect(exposed.values[index] == Float(Double(value) * 2))
        }
    }

    @Test("A stop down halves every component")
    func aStopDownHalves() throws {
        let source = Self.image([0.5, 1, 2, -1, 3, 0])
        let exposed = try SceneLinearExposer().apply(
            to: source, exposure: SceneLinearExposure(ev: -1)
        )
        #expect(exposed.values == [0.25, 0.5, 1, -0.5, 1.5, 0])
    }

    @Test("Nothing is clipped, in either direction")
    func nothingIsClipped() throws {
        let source = Self.image([-0.25, 0.5, 1.5, -2, 4, 8])
        let exposed = try SceneLinearExposer().apply(
            to: source, exposure: SceneLinearExposure(ev: 1)
        )
        #expect(exposed.values == [-0.5, 1, 3, -4, 8, 16])
        #expect(!exposed.processing.clamped)
        #expect(exposed.processing.sceneLinear)
        #expect(!exposed.processing.displayEncodingApplied)
        #expect(!exposed.processing.quantized)
    }

    @Test("The identity hands back the same values, bit for bit")
    func theIdentityPreservesEveryBitPattern() throws {
        // Three pixels of deliberately awkward components: signed zeros, a
        // subnormal, and both ends of the Float32 range.
        let awkward: [Float] = [
            0, -0, 1,
            -1, 1e-30, -1e-30,
            0.1, 1e30, -1e30
        ]
        let source = Self.image(awkward, width: 3, height: 1)
        let exposed = try SceneLinearExposer().apply(to: source, exposure: .neutral)
        for (index, value) in source.values.enumerated() {
            #expect(exposed.values[index].bitPattern == value.bitPattern)
        }
        #expect(exposed.processing.exposureEV == 0)
        #expect(exposed.processing.exposureApplied)
    }

    @Test("Applying twice is not the same as applying once, and never happens here")
    func exposureIsAppliedExactlyOnce() throws {
        // The stage always reads the image it is given. Two separate stops on
        // the same source are two separate results; only a caller that fed one
        // result back in could compound them, and the export pipeline never
        // does. This pins the arithmetic that makes the difference visible.
        let source = Self.image([0.25, 0.25, 0.25, 0.25, 0.25, 0.25])
        let once = try SceneLinearExposer().apply(
            to: source, exposure: SceneLinearExposure(ev: 1)
        )
        let twice = try SceneLinearExposer().apply(
            to: Self.image(once.values), exposure: SceneLinearExposure(ev: 1)
        )
        #expect(once.values.allSatisfy { $0 == 0.5 })
        #expect(twice.values.allSatisfy { $0 == 1.0 })
    }

    // MARK: - Provenance

    @Test("The whole upstream chain stays readable through the exposed image")
    func provenanceIsCarriedThrough() throws {
        let source = Self.image(
            [0.1, 0.2, 0.3, 0.4, 0.5, 0.6],
            orientation: .rotated90Clockwise,
            mix: .redBlueSwap
        )
        let exposed = try SceneLinearExposer().apply(
            to: source, exposure: SceneLinearExposure(ev: 0.5)
        )
        let processing = exposed.processing
        #expect(processing.exposureEV == 0.5)
        #expect(processing.exposureScale == exp2(0.5))
        #expect(processing.orientation == .rotated90Clockwise)
        #expect(processing.orientationApplied)
        #expect(processing.orientationSwappedDimensions)
        #expect(processing.mix == .redBlueSwap)
        #expect(processing.channelMixApplied)
        #expect(processing.workingColorSpace == .extendedLinearSRGB)
        #expect(processing.demosaiced)
        #expect(processing.whiteBalanceApplied)
        #expect(processing.blackLevelSubtracted)
        #expect(processing.normalized)
        #expect(!processing.isValidatedInfraredCalibration)
        // And what it did not do.
        #expect(!processing.toneMappingApplied)
        #expect(!processing.automaticExposureApplied)
        #expect(!processing.highlightReconstructionApplied)
        #expect(!processing.interpolated)
        #expect(!processing.scaled)
        #expect(!processing.cropped)
    }

    @Test("A full-resolution image says it was not reduced for preview")
    func aFullResolutionImageSaysSo() throws {
        let exposed = try SceneLinearExposer().apply(
            to: Self.image([0.1, 0.2, 0.3, 0.4, 0.5, 0.6]), exposure: .neutral
        )
        #expect(!exposed.processing.reducedForPreview)
        #expect(exposed.processing.previewResolution == nil)
    }

    @Test("A preview-derived image carries its reduction, and says so")
    func aPreviewDerivedImageCarriesItsReduction() throws {
        let exposed = try ExportTestData.exposedFromPreview(
            width: 2, height: 1, values: [0.1, 0.2, 0.3, 0.4, 0.5, 0.6]
        )
        #expect(exposed.processing.reducedForPreview)
        #expect(exposed.processing.previewResolution?.sourceWidth == 4056)
    }

    // MARK: - Refusals

    @Test("Inconsistent geometry is refused")
    func inconsistentGeometryIsRefused() {
        let broken = ExportTestData.oriented(width: 4, height: 4, values: [0, 0, 0])
        #expect(throws: SceneLinearExposureError.self) {
            try SceneLinearExposer().apply(to: broken, exposure: .neutral)
        }
    }

    @Test("An exposure that cannot be applied is refused, not sanitised")
    func anUnusableExposureIsRefused() throws {
        let source = Self.image([0.1, 0.2, 0.3, 0.4, 0.5, 0.6])
        for ev in [Double.nan, .infinity, -.infinity, 100_000] {
            #expect(throws: SceneLinearExposureError.self) {
                try SceneLinearExposer().apply(
                    to: source, exposure: SceneLinearExposure(ev: ev)
                )
            }
        }
    }

    @Test("A non-finite input names its coordinates, on both paths")
    func aNonFiniteInputNamesItsCoordinates() throws {
        let values: [Float] = [0.1, 0.2, 0.3, 0.4, .nan, 0.6]
        let source = Self.image(values)

        // The multiplying path. NaN never compares equal to itself, so the
        // case is matched and its payload checked rather than compared.
        do {
            _ = try SceneLinearExposer().apply(
                to: source, exposure: SceneLinearExposure(ev: 1)
            )
            Issue.record("A NaN component should have been refused.")
        } catch let error as SceneLinearExposureError {
            guard case .nonFiniteSceneLinearInput(let row, let column, let channel, let value)
                = error
            else {
                Issue.record("Wrong case: \(error)")
                return
            }
            #expect(row == 0)
            #expect(column == 1)
            #expect(channel == .green)
            #expect(value.isNaN)
        }

        // And the identity path, which must not become a way of smuggling a
        // NaN through by asking for 0 EV.
        #expect(throws: SceneLinearExposureError.self) {
            try SceneLinearExposer().apply(to: source, exposure: .neutral)
        }
    }

    @Test("A finite value that overflows once exposed is refused")
    func anOverflowingValueIsRefused() throws {
        let source = Self.image([1e38, 0.2, 0.3, 0.4, 0.5, 0.6])
        do {
            _ = try SceneLinearExposer().apply(
                to: source, exposure: SceneLinearExposure(ev: 10)
            )
            Issue.record("An overflowing component should have been refused.")
        } catch let error as SceneLinearExposureError {
            guard case .nonFiniteExposedValue(let row, let column, let channel, let ev) = error
            else {
                Issue.record("Wrong case: \(error)")
                return
            }
            #expect(row == 0)
            #expect(column == 0)
            #expect(channel == .red)
            #expect(ev == 10)
        }
    }

    // MARK: - Cancellation

    @Test("A superseded call stops before it allocates")
    func aSupersededCallStopsImmediately() {
        let probe = CancellationProbe(cancelAfterPolls: 1)
        #expect(throws: CancellationError.self) {
            try SceneLinearExposer().apply(
                to: Self.image([0.1, 0.2, 0.3, 0.4, 0.5, 0.6]),
                exposure: SceneLinearExposure(ev: 1),
                cancellation: probe.cancellation
            )
        }
    }

    @Test("The multiplying path polls once per row")
    func theMultiplyingPathPollsPerRow() throws {
        let probe = CancellationProbe()
        let tall = ExportTestData.oriented(
            width: 1, height: 4, values: Array(repeating: 0.5, count: 12)
        )
        _ = try SceneLinearExposer().apply(
            to: tall, exposure: SceneLinearExposure(ev: 1), cancellation: probe.cancellation
        )
        // One entry poll plus one per row.
        #expect(probe.pollCount == 5)
    }

    @Test("The identity path polls once per row too")
    func theIdentityPathPollsPerRow() throws {
        let probe = CancellationProbe()
        let tall = ExportTestData.oriented(
            width: 1, height: 4, values: Array(repeating: 0.5, count: 12)
        )
        _ = try SceneLinearExposer().apply(
            to: tall, exposure: .neutral, cancellation: probe.cancellation
        )
        #expect(probe.pollCount == 5)
    }

    @Test("Cancelling mid-pass abandons the buffer rather than returning part of it")
    func cancellingMidPassAbandonsTheBuffer() {
        let tall = ExportTestData.oriented(
            width: 1, height: 8, values: Array(repeating: 0.5, count: 24)
        )
        for exposure in [SceneLinearExposure(ev: 1), .neutral] {
            let probe = CancellationProbe(cancelAfterPolls: 3)
            #expect(throws: CancellationError.self) {
                try SceneLinearExposer().apply(
                    to: tall, exposure: exposure, cancellation: probe.cancellation
                )
            }
        }
    }
}
