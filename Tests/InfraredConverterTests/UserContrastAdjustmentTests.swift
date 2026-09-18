import Foundation
import Testing
@testable import InfraredConverter

/// The contrast adjustment's supported domain, and what it refuses.
///
/// The domain is `−1 … +1` **by definition of the control**, not because the
/// arithmetic runs out — which is the opposite of `UserLevelsAdjustment`,
/// whose bounds are derived from IEEE 754. These tests assert the definition.
@Suite("User contrast adjustment")
struct UserContrastAdjustmentTests {

    // MARK: - What the domain admits

    @Test(
        "Every amount in the supported range is accepted exactly",
        arguments: [
            -1.0, -0.999, -0.5, -0.01, -0.0, 0.0, 0.01, 0.35, 0.5, 0.999, 1.0,
            // A finer value than the slider can produce: a hand-edited sidecar
            // or a future recipe may hold one, and it is not rounded.
            0.355, -0.123_456_789, 1e-300,
        ]
    )
    func theSupportedRangeIsAccepted(amount: Double) throws {
        let adjustment = try UserContrastAdjustment(amount: amount)
        #expect(adjustment.amount == amount)
    }

    @Test("Both endpoints are inside the domain, not outside it")
    func theEndpointsAreIncluded() throws {
        #expect(try UserContrastAdjustment(amount: -1).amount == -1)
        #expect(try UserContrastAdjustment(amount: 1).amount == 1)
        #expect(UserContrastAdjustment.supportedRange == -1...1)
    }

    @Test("Neutral is exactly zero and is the identity")
    func neutralIsZero() {
        #expect(UserContrastAdjustment.neutral.amount == 0)
        #expect(UserContrastAdjustment.neutral.isIdentity)
        #expect(GlobalContrastCurve(UserContrastAdjustment.neutral).exponent == 1)
    }

    @Test("A negative zero is the identity, because 2^-0.0 is exactly 1")
    func negativeZeroIsIdentity() throws {
        let adjustment = try UserContrastAdjustment(amount: -0.0)
        #expect(adjustment.isIdentity)
        #expect(adjustment == .neutral)
        #expect(GlobalContrastCurve(adjustment).exponent == 1)
    }

    @Test("Any non-zero amount is not the identity")
    func nonZeroIsNotIdentity() throws {
        #expect(!(try UserContrastAdjustment(amount: 1e-300).isIdentity))
        #expect(!(try UserContrastAdjustment(amount: -1).isIdentity))
        #expect(!(try UserContrastAdjustment(amount: 1).isIdentity))
    }

    // MARK: - What it refuses, and never clamps

    @Test(
        "An amount outside the range is refused rather than clamped",
        arguments: [-1.000_000_1, -1.5, -2.0, -100.0, 1.000_000_1, 1.5, 2.0, 100.0]
    )
    func outOfRangeIsRefused(amount: Double) {
        #expect(
            throws: ImageAdjustmentError.contrastAdjustmentOutOfRange(
                amount: amount, supported: -1...1
            )
        ) {
            try UserContrastAdjustment(amount: amount)
        }
    }

    @Test(
        "A non-finite amount is refused",
        arguments: [Double.nan, .infinity, -.infinity, .signalingNaN]
    )
    func nonFiniteIsRefused(amount: Double) {
        #expect(throws: ImageAdjustmentError.self) {
            try UserContrastAdjustment(amount: amount)
        }
    }

    /// The refusal names the value, so a person reading a log can see what the
    /// record actually held.
    @Test("The refusals carry the value and the range")
    func theRefusalsAreInformative() {
        let range = ImageAdjustmentError.contrastAdjustmentOutOfRange(
            amount: 1.5, supported: -1...1
        )
        #expect(range.errorDescription?.isEmpty == false)
        #expect(range.failureReason?.contains("1.5") == true)
        // It says the range is the control's definition, not the arithmetic's.
        #expect(range.failureReason?.contains("not a limit of the arithmetic") == true)

        let nonFinite = ImageAdjustmentError.nonFiniteContrastAdjustment(amount: .nan)
        #expect(nonFinite.errorDescription?.isEmpty == false)
        #expect(nonFinite.failureReason?.contains("neutral") == true)
    }

    // MARK: - Persistence

    @Test(
        "The wire format is a bare number and round-trips exactly",
        arguments: [-1.0, -0.5, 0.0, 0.35, 0.355, 1.0]
    )
    func theWireFormatIsABareNumber(amount: Double) throws {
        let adjustment = try UserContrastAdjustment(amount: amount)
        let data = try JSONEncoder().encode(adjustment)
        let text = String(decoding: data, as: UTF8.self)
        // A bare JSON number: no object, no unit string, no exponent field.
        #expect(!text.contains("{"))
        #expect(!text.contains("k"))
        #expect(!text.contains("exponent"))

        let decoded = try JSONDecoder().decode(UserContrastAdjustment.self, from: data)
        #expect(decoded == adjustment)
        #expect(decoded.amount == amount)
    }

    @Test("Decoding refuses exactly what construction refuses")
    func decodingRefusesTheSameValues() {
        for text in ["1.5", "-1.5", "2", "-100"] {
            #expect(throws: ImageAdjustmentError.self) {
                try JSONDecoder().decode(
                    UserContrastAdjustment.self, from: Data(text.utf8)
                )
            }
        }
    }

    @Test("A finer persisted value is not rounded to the slider's step")
    func aFinerValueSurvivesDecoding() throws {
        let decoded = try JSONDecoder().decode(
            UserContrastAdjustment.self, from: Data("0.355".utf8)
        )
        #expect(decoded.amount == 0.355)
        #expect(decoded.amount != 0.36)
        #expect(decoded.amount != 0.35)
    }

    // MARK: - Presentation

    @Test("The description is a signed control value with no percent sign")
    func theDescriptionIsSignedAndUnitless() throws {
        #expect(try UserContrastAdjustment(amount: 0.35).signedDescription == "+35")
        #expect(try UserContrastAdjustment(amount: -0.2).signedDescription == "-20")
        #expect(UserContrastAdjustment.neutral.signedDescription == "+0")
        #expect(try UserContrastAdjustment(amount: -0.0).signedDescription == "+0")
        for amount in [-1.0, -0.35, 0.0, 0.35, 1.0] {
            #expect(!(try UserContrastAdjustment(amount: amount).signedDescription
                .contains("%")))
        }
    }

    @Test("The diagnostic description names the exponent, not only the amount")
    func theDiagnosticNamesTheExponent() throws {
        let text = try UserContrastAdjustment(amount: 1).diagnosticDescription
        #expect(text.contains("+1.000"))
        #expect(text.contains("2.000000"))
    }
}
