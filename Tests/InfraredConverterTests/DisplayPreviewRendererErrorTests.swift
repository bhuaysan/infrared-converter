import Testing
import Foundation
@testable import InfraredConverter

/// What the display rendering stage refuses.
///
/// `IRChannelMixedRGBImage` is publicly constructible on purpose — it is a
/// data representation, not a provenance claim — so a hand-built image can
/// carry anything, and this boundary has to defend itself rather than trust
/// that the channel mixer was upstream.
///
/// The theme running through this file: nothing is clamped into a plausible
/// value. An exposure that overflows would otherwise clip to `1` and reach the
/// screen as an ordinary white pixel, indistinguishable from a legitimately
/// bright one.
@Suite("DisplayPreviewRenderer errors")
struct DisplayPreviewRendererErrorTests {

    // MARK: - Exposure

    @Test(
        "A non-finite EV is refused",
        arguments: [Double.nan, .infinity, -.infinity]
    )
    func nonFiniteExposureIsRefused(exposureEV: Double) {
        #expect {
            _ = try DisplayPreviewTestData.renderPreview(DisplayPreviewTestData.pixel(0.5, 0.5, 0.5), exposureEV: exposureEV)
        } throws: { error in
            guard case .nonFiniteExposure(let reportedEV, _) =
                    error as? SceneLinearExposureError else { return false }
            // NaN cannot be compared with `==`, so it is identified as NaN.
            return exposureEV.isNaN ? reportedEV.isNaN : reportedEV == exposureEV
        }
    }

    /// `−infinity EV` is the case a scale-only check would let through:
    /// `exp2(−infinity)` is `0`, a perfectly finite-looking multiplier that
    /// would silently render a black frame from a nonsense exposure. The EV
    /// itself is checked for exactly this reason.
    @Test("Minus-infinity EV is refused even though its scale is finite")
    func minusInfinityExposureIsRefusedDespiteAFiniteScale() {
        #expect(exp2(-Double.infinity) == 0)
        #expect(exp2(-Double.infinity).isFinite)

        #expect {
            _ = try DisplayPreviewTestData.renderPreview(DisplayPreviewTestData.pixel(0.5, 0.5, 0.5), exposureEV: -.infinity)
        } throws: { error in
            guard case .nonFiniteExposure(let reportedEV, let scale) =
                    error as? SceneLinearExposureError else { return false }
            return reportedEV == -.infinity && scale == 0
        }
    }

    /// A finite EV whose `2^EV` is not finite. Same case, because both mean
    /// "this exposure cannot be applied", and the EV plus its scale diagnoses
    /// either one completely.
    @Test("A finite but enormous EV whose scale overflows is refused")
    func overflowingExposureScaleIsRefused() {
        let exposureEV = 5000.0
        #expect(exposureEV.isFinite)
        #expect(!exp2(exposureEV).isFinite)

        #expect {
            _ = try DisplayPreviewTestData.renderPreview(DisplayPreviewTestData.pixel(0.5, 0.5, 0.5), exposureEV: exposureEV)
        } throws: { error in
            guard case .nonFiniteExposure(let reportedEV, let scale) =
                    error as? SceneLinearExposureError else { return false }
            return reportedEV == exposureEV && scale == .infinity
        }
    }

    /// The exposure that fails per sample rather than per image: a finite
    /// coordinate, a finite scale, and a product `Float32` cannot hold.
    @Test("A sample that overflows Float32 on exposure is refused, not clipped")
    func exposureOverflowIsRefusedRatherThanClipped() {
        // Finite in Double, infinite as Float32.
        let scale = exp2(1.0)
        #expect((Double(Float.greatestFiniteMagnitude) * scale).isFinite)
        #expect(Float(Double(Float.greatestFiniteMagnitude) * scale).isFinite == false)

        let image = DisplayPreviewTestData.image(
            width: 2,
            height: 1,
            values: [0.5, 0.5, 0.5, 0.25, .greatestFiniteMagnitude, 0.75]
        )
        #expect {
            _ = try DisplayPreviewTestData.renderPreview(image, exposureEV: 1)
        } throws: { error in
            guard case .nonFiniteExposedValue(let row, let column, let channel, let exposureEV) =
                    error as? SceneLinearExposureError else { return false }
            return row == 0 && column == 1 && channel == .green && exposureEV == 1
        }
    }

    /// The same value at `0 EV` is finite, so it renders — and clips to white
    /// rather than failing. The contrast is the point: the failure above is
    /// about the arithmetic, not about the value being large.
    @Test("The largest finite magnitude renders at 0 EV and clips high")
    func aHugeButRepresentableValueClipsInstead() throws {
        let rendered = try DisplayPreviewTestData.renderPreview(DisplayPreviewTestData.pixel(.greatestFiniteMagnitude, 0.5, 0))
        #expect(rendered.bytes[0] == 255)
        #expect(rendered.processing.clippedHighSampleCount == 1)
    }

    // MARK: - Non-finite input

    @Test(
        "NaN, +infinity and -infinity inputs are refused",
        arguments: [Float.nan, .infinity, -.infinity]
    )
    func nonFiniteInputsAreRefused(poison: Float) {
        for channel in RAWLinearRGBChannel.allCases {
            var values = (0..<12).map { Float($0) * 0.05 }
            values[(1 * 2 + 0) * 3 + channel.storageOffset] = poison
            let image = DisplayPreviewTestData.image(width: 2, height: 2, values: values)

            #expect {
                _ = try DisplayPreviewTestData.renderPreview(image)
            } throws: { error in
                guard case .nonFiniteSceneLinearInput(let row, let column, let reported, _) =
                        error as? SceneLinearExposureError else { return false }
                return row == 1 && column == 0 && reported == channel
            }
        }
    }

    /// An infinite input is reported as an **input** problem, not as an
    /// exposure overflow. The two are different findings and must not be
    /// confused: one means the image was already broken, the other means the
    /// settings were.
    @Test("An infinite input is named as an input, not as an exposure failure")
    func nonFiniteInputIsNotReportedAsAnExposureFailure() {
        #expect {
            _ = try DisplayPreviewTestData.renderPreview(DisplayPreviewTestData.pixel(.infinity, 0.5, 0.5), exposureEV: 2)
        } throws: { error in
            guard case .nonFiniteSceneLinearInput(_, _, let channel, let value) =
                    error as? SceneLinearExposureError else { return false }
            return channel == .red && value == .infinity
        }
    }

    // MARK: - Geometry

    @Test("An image whose buffer does not match its dimensions is refused")
    func inconsistentGeometryIsRefused() {
        let renderer = DisplayPreviewRenderer()
        // Declares 2×2 (12 values) and holds 9.
        let short = DisplayPreviewTestData.leveledImage(
            width: 2, height: 2, values: [Float](repeating: 0.5, count: 9)
        )
        #expect {
            _ = try renderer.render(short, settings: DisplayPreviewTestData.settings)
        } throws: { error in
            guard case .invalidGeometry = error as? DisplayRenderingError else { return false }
            return true
        }

        let empty = DisplayPreviewTestData.leveledImage(width: 0, height: 4, values: [])
        #expect {
            _ = try renderer.render(empty, settings: DisplayPreviewTestData.settings)
        } throws: { error in
            guard case .invalidGeometry = error as? DisplayRenderingError else { return false }
            return true
        }
    }

    /// Geometry is checked before exposure, so a broken image reports the
    /// broken image rather than whatever the settings happen to be. The stage
    /// that reports it is now the exposer, which is the first of the three to
    /// see the image — and that is the point rather than an accident: the
    /// chain refuses at its earliest boundary instead of carrying a broken
    /// image further down it.
    @Test("Geometry is refused before the exposure is even considered")
    func geometryIsCheckedFirst() {
        let short = DisplayPreviewTestData.image(
            width: 4, height: 4, values: [Float](repeating: 0.5, count: 3)
        )
        #expect {
            _ = try DisplayPreviewTestData.renderPreview(short, exposureEV: .nan)
        } throws: { error in
            guard case .invalidGeometry = error as? SceneLinearExposureError else {
                return false
            }
            return true
        }
    }

    // MARK: - Error surface

    @Test("Every case carries a description and a reason")
    func errorsDescribeThemselves() {
        let errors: [DisplayRenderingError] = [
            .invalidGeometry(reason: "2x2 needs 12 values, buffer holds 9."),
            .nonFiniteLinearInput(row: 3, column: 4, channel: .green, value: .infinity),
            .displayImageUnavailable(reason: "CoreGraphics declined."),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.failureReason?.isEmpty == false)
        }
        #expect(errors[1].failureReason?.contains("row 3, column 4") == true)
    }

    /// The two exposure cases are **gone** from this error type, not merely
    /// unused. An error case that cannot occur describes a stage that no
    /// longer exists, and a reader handling it would be handling nothing.
    @Test("The display error surface is exactly three cases")
    func theErrorSurfaceCarriesNoExposureCases() {
        // Written as an exhaustive switch: adding a case to
        // `DisplayRenderingError` without deciding what it means fails to
        // compile here.
        func describe(_ error: DisplayRenderingError) -> String {
            switch error {
            case .invalidGeometry: return "geometry"
            case .nonFiniteLinearInput: return "input"
            case .displayImageUnavailable: return "platform"
            }
        }
        #expect(describe(.invalidGeometry(reason: "x")) == "geometry")
        #expect(
            describe(
                .nonFiniteLinearInput(row: 0, column: 0, channel: .red, value: .nan)
            ) == "input"
        )
        #expect(describe(.displayImageUnavailable(reason: "x")) == "platform")
    }
}
