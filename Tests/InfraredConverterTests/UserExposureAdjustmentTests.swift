import Testing
import Foundation
@testable import InfraredConverter

/// The user's exposure decision: what it means, which values a record may
/// hold, how it persists, and how the workspace slider maps onto it.
@Suite("UserExposureAdjustment")
struct UserExposureAdjustmentTests {

    // MARK: - Meaning

    @Test("Neutral is exactly 0 EV and has no effect")
    func neutralIsZero() {
        #expect(UserExposureAdjustment.neutral.ev == 0)
        #expect(UserExposureAdjustment.neutral.isIdentity)
        #expect(UserExposureAdjustment.neutral.signedDescription == "+0.00 EV")
    }

    @Test(
        "Any finite value inside the range is held exactly, without rounding",
        arguments: [-10.0, -3.3333333333, -0.05, 0.1, 0.73000001, 1.25, 7.99, 10]
    )
    func valuesAreHeldExactly(ev: Double) throws {
        let adjustment = try UserExposureAdjustment(ev: ev)
        #expect(adjustment.ev.bitPattern == ev.bitPattern)
        #expect(!adjustment.isIdentity)
    }

    @Test("Negative zero is the identity and reads as +0.00")
    func negativeZeroIsTheIdentity() throws {
        let adjustment = try UserExposureAdjustment(ev: -0.0)
        #expect(adjustment.isIdentity)
        #expect(adjustment == .neutral)
        #expect(adjustment.signedDescription == "+0.00 EV")
    }

    @Test("The description is signed with two decimals")
    func theDescriptionIsSigned() throws {
        #expect(try UserExposureAdjustment(ev: 1.25).signedDescription == "+1.25 EV")
        #expect(try UserExposureAdjustment(ev: -0.3).signedDescription == "-0.30 EV")
        #expect(try UserExposureAdjustment(ev: 0.7).signedDescription == "+0.70 EV")
    }

    @Test("The supported range is the documented, symmetric one")
    func theSupportedRangeIsStated() {
        #expect(UserExposureAdjustment.supportedRange == -10...10)
        // Its endpoints are exact binary values, so a bound is not a rounding.
        #expect(exp2(UserExposureAdjustment.supportedRange.upperBound) == 1024)
        #expect(exp2(UserExposureAdjustment.supportedRange.lowerBound) == 1.0 / 1024)
    }

    // MARK: - Refusals

    @Test("An infinity is refused and named")
    func infinitiesAreRefused() {
        #expect(throws: ImageAdjustmentError.nonFiniteExposureAdjustment(ev: .infinity)) {
            _ = try UserExposureAdjustment(ev: .infinity)
        }
        #expect(throws: ImageAdjustmentError.nonFiniteExposureAdjustment(ev: -.infinity)) {
            _ = try UserExposureAdjustment(ev: -.infinity)
        }
    }

    /// NaN is not equal to itself, so the typed case is matched by pattern
    /// rather than by equality.
    @Test("NaN is refused as non-finite, never read as 0 EV", arguments: [Double.nan, .signalingNaN])
    func nanIsRefused(value: Double) {
        do {
            _ = try UserExposureAdjustment(ev: value)
            Issue.record("NaN was accepted")
        } catch let error as ImageAdjustmentError {
            guard case .nonFiniteExposureAdjustment(let ev) = error, ev.isNaN else {
                Issue.record("Expected .nonFiniteExposureAdjustment(NaN), got \(error)")
                return
            }
        } catch {
            Issue.record("Expected an ImageAdjustmentError, got \(error)")
        }
    }

    @Test(
        "A finite value outside the range is refused, not clamped",
        arguments: [10.000000001, -10.5, 12, -64, 1e300, -Double.greatestFiniteMagnitude]
    )
    func outOfRangeValuesAreRefused(ev: Double) {
        #expect(
            throws: ImageAdjustmentError.exposureAdjustmentOutOfRange(
                ev: ev, supported: UserExposureAdjustment.supportedRange
            )
        ) {
            _ = try UserExposureAdjustment(ev: ev)
        }
    }

    @Test("The refusals name the value that was refused")
    func theRefusalsNameTheValue() {
        let outOfRange = ImageAdjustmentError.exposureAdjustmentOutOfRange(
            ev: 12.5, supported: UserExposureAdjustment.supportedRange
        )
        #expect(outOfRange.errorDescription?.isEmpty == false)
        #expect(outOfRange.failureReason?.contains("12.5") == true)
        #expect(outOfRange.failureReason?.contains("10") == true)

        let nonFinite = ImageAdjustmentError.nonFiniteExposureAdjustment(ev: .infinity)
        #expect(nonFinite.errorDescription?.isEmpty == false)
        #expect(nonFinite.failureReason?.contains("inf") == true)
    }

    // MARK: - Persistence

    @Test("It persists as a bare number")
    func itPersistsAsABareNumber() throws {
        let encoder = JSONEncoder()
        #expect(
            String(decoding: try encoder.encode([try UserExposureAdjustment(ev: 1.25)]), as: UTF8.self)
                == "[1.25]"
        )
        #expect(
            String(decoding: try encoder.encode([UserExposureAdjustment.neutral]), as: UTF8.self)
                == "[0]"
        )
        #expect(
            try JSONDecoder().decode([UserExposureAdjustment].self, from: Data("[-0.3]".utf8))
                == [try UserExposureAdjustment(ev: -0.3)]
        )
    }

    @Test("Decoding an out-of-range number refuses with the construction error")
    func decodingRefusesOutOfRange() {
        #expect(
            throws: ImageAdjustmentError.exposureAdjustmentOutOfRange(
                ev: 20, supported: UserExposureAdjustment.supportedRange
            )
        ) {
            _ = try JSONDecoder().decode([UserExposureAdjustment].self, from: Data("[20]".utf8))
        }
    }

    // MARK: - The workspace slider

    @Test("The slider range lies inside the supported range, and steps in twentieths")
    func theSliderRangeIsStated() {
        #expect(ExposureControlScale.range == -4...4)
        #expect(UserExposureAdjustment.supportedRange.contains(ExposureControlScale.range.lowerBound))
        #expect(UserExposureAdjustment.supportedRange.contains(ExposureControlScale.range.upperBound))
        #expect(ExposureControlScale.stepsPerStop == 20)
    }

    @Test("A slider write is quantised to the closest decimal twentieth of a stop")
    func sliderWritesAreQuantised() throws {
        let from = UserExposureAdjustment.neutral
        #expect(ExposureControlScale.adjustment(forSliderValue: 0.3012, current: from)?.ev == 0.3)
        #expect(ExposureControlScale.adjustment(forSliderValue: 0.7249, current: from)?.ev == 0.7)
        #expect(ExposureControlScale.adjustment(forSliderValue: -1.2376, current: from)?.ev == -1.25)
        // The written value is the shortest decimal, not 0.30000000000000004.
        let written = try JSONEncoder().encode(
            [try #require(ExposureControlScale.adjustment(forSliderValue: 0.3, current: from))]
        )
        #expect(String(decoding: written, as: UTF8.self) == "[0.3]")
    }

    @Test("A write that asks for no change produces no decision")
    func noChangeIsNoDecision() throws {
        let current = try UserExposureAdjustment(ev: 0.5)
        // The echo of the displayed position.
        #expect(ExposureControlScale.adjustment(forSliderValue: 0.5, current: current) == nil)
        // A different position that quantises back to the same value.
        #expect(ExposureControlScale.adjustment(forSliderValue: 0.51, current: current) == nil)
        #expect(ExposureControlScale.adjustment(forSliderValue: .nan, current: current) == nil)
    }

    /// A saved value beyond the slider is displayed at the end stop and not
    /// changed by being displayed. Only a real move writes.
    @Test("A saved value beyond the slider is kept until the slider is moved")
    func aValueBeyondTheSliderIsKept() throws {
        let saved = try UserExposureAdjustment(ev: 6)
        #expect(ExposureControlScale.isBeyondSlider(saved))
        #expect(ExposureControlScale.sliderPosition(for: saved) == 4)
        // The slider echoing its end stop is not a decision.
        #expect(ExposureControlScale.adjustment(forSliderValue: 4, current: saved) == nil)
        // A real drag is.
        #expect(ExposureControlScale.adjustment(forSliderValue: 3.5, current: saved)?.ev == 3.5)

        let low = try UserExposureAdjustment(ev: -9.75)
        #expect(ExposureControlScale.sliderPosition(for: low) == -4)
        #expect(ExposureControlScale.adjustment(forSliderValue: -4, current: low) == nil)
        #expect(!ExposureControlScale.isBeyondSlider(try UserExposureAdjustment(ev: 4)))
    }

    @Test("A fine saved value is not rewritten by being displayed")
    func aFineValueIsNotRewritten() throws {
        let saved = try UserExposureAdjustment(ev: 0.73)
        #expect(ExposureControlScale.sliderPosition(for: saved) == 0.73)
        #expect(ExposureControlScale.adjustment(forSliderValue: 0.73, current: saved) == nil)
    }
}
