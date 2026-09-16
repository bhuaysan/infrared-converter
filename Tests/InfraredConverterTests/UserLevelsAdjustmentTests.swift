import Testing
import Foundation
@testable import InfraredConverter

/// What a persisted levels decision may hold, and what it refuses.
///
/// The theme: nothing is clamped, reordered or substituted. A pair we could
/// not read and a deliberate decision to leave the levels alone are different
/// facts, and only one of them is neutral.
@Suite("UserLevelsAdjustment")
struct UserLevelsAdjustmentTests {

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func encoded(_ adjustment: UserLevelsAdjustment) throws -> String {
        String(decoding: try encoder.encode(adjustment), as: UTF8.self)
    }

    static func decode(_ json: String) throws -> UserLevelsAdjustment {
        try JSONDecoder().decode(UserLevelsAdjustment.self, from: Data(json.utf8))
    }

    // MARK: - The neutral value

    @Test("Neutral is black 0, white 1, and is the identity")
    func neutralIsTheIdentity() {
        #expect(UserLevelsAdjustment.neutral.blackPoint == 0)
        #expect(UserLevelsAdjustment.neutral.whitePoint == 1)
        #expect(UserLevelsAdjustment.neutral.span == 1)
        #expect(UserLevelsAdjustment.neutral.isIdentity)
        #expect(LinearLevels(UserLevelsAdjustment.neutral).isIdentity)
    }

    @Test("A fresh adjustment record carries neutral levels")
    func aFreshRecordIsNeutral() {
        #expect(ImageAdjustments.none.levels == .neutral)
        #expect(ImageAdjustments().levels == .neutral)
        #expect(ImageAdjustments.none.isDefault)
    }

    /// `isDefault` is written out field by field so that adding an adjustment
    /// without deciding its default fails to compile. This is the assertion
    /// that the new field took part.
    @Test("Non-neutral levels stop the record being default")
    func levelsParticipateInIsDefault() throws {
        let record = ImageAdjustments(
            levels: try UserLevelsAdjustment(blackPoint: 0.05, whitePoint: 1)
        )
        #expect(!record.isDefault)
        #expect(record.orientation == .identity)
        #expect(record.channelMix == .identity)
        #expect(record.exposure == .neutral)
        #expect(record.whiteBalance == .defaultNeutralPatch)
    }

    // MARK: - What is accepted

    @Test(
        "Ordered finite pairs are accepted, inside the unit interval and well outside it",
        arguments: [
            (0.0, 1.0), (0.1, 0.9), (-0.25, 2.0), (-0.5, 1.5), (0.999, 1.0),
            (-100.0, 100.0), (1.0, 1_000.0), (-1e300, 1e300),
        ]
    )
    func orderedFinitePairsAreAccepted(blackPoint: Double, whitePoint: Double) throws {
        let adjustment = try UserLevelsAdjustment(
            blackPoint: blackPoint, whitePoint: whitePoint
        )
        #expect(adjustment.blackPoint == blackPoint)
        #expect(adjustment.whitePoint == whitePoint)
        #expect(LinearLevels(adjustment).isApplicable)
    }

    /// The point of the previous test, stated as the rule it demonstrates:
    /// the valid domain is not a photographic range, and a control's range
    /// never reaches this type.
    @Test("Values far outside the slider's range are perfectly valid decisions")
    func theSliderRangeIsNotTheValidityRule() throws {
        let beyond = try UserLevelsAdjustment(blackPoint: -4, whitePoint: 9)
        #expect(!LevelsControlScale.range.contains(beyond.blackPoint))
        #expect(!LevelsControlScale.range.contains(beyond.whitePoint))
        #expect(LevelsControlScale.isBeyondSliders(beyond))
        // And it is not altered by being displayed: the thumbs pin, the value
        // does not move.
        #expect(LevelsControlScale.blackSliderPosition(for: beyond)
            == LevelsControlScale.range.lowerBound)
        #expect(LevelsControlScale.whiteSliderPosition(for: beyond)
            == LevelsControlScale.range.upperBound)
        #expect(beyond.blackPoint == -4)
        #expect(beyond.whitePoint == 9)
    }

    // MARK: - What is refused

    @Test(
        "A non-finite black point is refused by name",
        arguments: [Double.nan, .infinity, -.infinity]
    )
    func aNonFiniteBlackPointIsRefused(poison: Double) {
        #expect {
            _ = try UserLevelsAdjustment(blackPoint: poison, whitePoint: 1)
        } throws: { error in
            guard case .nonFiniteLevelsBound(let field, let value) =
                    error as? ImageAdjustmentError else { return false }
            return field == "blackPoint" && (poison.isNaN ? value.isNaN : value == poison)
        }
    }

    @Test(
        "A non-finite white point is refused by name",
        arguments: [Double.nan, .infinity, -.infinity]
    )
    func aNonFiniteWhitePointIsRefused(poison: Double) {
        #expect {
            _ = try UserLevelsAdjustment(blackPoint: 0, whitePoint: poison)
        } throws: { error in
            guard case .nonFiniteLevelsBound(let field, let value) =
                    error as? ImageAdjustmentError else { return false }
            return field == "whitePoint" && (poison.isNaN ? value.isNaN : value == poison)
        }
    }

    @Test("Equal endpoints are refused, not nudged apart")
    func equalEndpointsAreRefused() {
        #expect {
            _ = try UserLevelsAdjustment(blackPoint: 0.5, whitePoint: 0.5)
        } throws: { error in
            guard case .levelsNotOrdered(let black, let white) =
                    error as? ImageAdjustmentError else { return false }
            return black == 0.5 && white == 0.5
        }
    }

    @Test("Reversed endpoints are refused, not swapped")
    func reversedEndpointsAreRefused() {
        #expect {
            _ = try UserLevelsAdjustment(blackPoint: 0.9, whitePoint: 0.1)
        } throws: { error in
            guard case .levelsNotOrdered(let black, let white) =
                    error as? ImageAdjustmentError else { return false }
            // Reported in the order they were given. Swapping them would
            // invert the photograph, which is a decision nobody made.
            return black == 0.9 && white == 0.1
        }
    }

    /// The one bound that is not obvious, and it is derived from IEEE 754
    /// rather than from photography: an interval whose span or whose
    /// reciprocal is not representable cannot be applied to any pixel.
    @Test("An interval that overflows the subtraction is refused")
    func anOverflowingSpanIsRefused() {
        #expect {
            _ = try UserLevelsAdjustment(
                blackPoint: -.greatestFiniteMagnitude,
                whitePoint: .greatestFiniteMagnitude
            )
        } throws: { error in
            guard case .levelsSpanNotRepresentable(_, _, let span, let scale) =
                    error as? ImageAdjustmentError else { return false }
            // Finite-looking scale, infinite span: exactly the case a check on
            // the scale alone would let through, and it would render black.
            return !span.isFinite && scale == 0
        }
    }

    @Test("An interval whose reciprocal overflows is refused")
    func aVanishingSpanIsRefused() {
        #expect {
            _ = try UserLevelsAdjustment(
                blackPoint: 0, whitePoint: .leastNonzeroMagnitude
            )
        } throws: { error in
            guard case .levelsSpanNotRepresentable(_, _, let span, let scale) =
                    error as? ImageAdjustmentError else { return false }
            return span.isFinite && !scale.isFinite
        }
    }

    @Test("Every levels error carries a description and a reason")
    func errorsDescribeThemselves() {
        let errors: [ImageAdjustmentError] = [
            .missingLevelsField(field: "whitePoint"),
            .nonFiniteLevelsBound(field: "blackPoint", value: .nan),
            .levelsNotOrdered(blackPoint: 0.9, whitePoint: 0.1),
            .levelsSpanNotRepresentable(
                blackPoint: 0, whitePoint: 1, span: .infinity, scale: 0
            ),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
            #expect(error.failureReason?.isEmpty == false)
        }
        #expect(errors[0].failureReason?.contains("whitePoint") == true)
        #expect(errors[2].failureReason?.contains("0.9") == true)
    }

    // MARK: - The wire format

    @Test("The encoded shape is an object of two required numbers")
    func theWireShapeIsStable() throws {
        #expect(
            try Self.encoded(.neutral) == #"{"blackPoint":0,"whitePoint":1}"#
        )
        #expect(
            try Self.encoded(
                try UserLevelsAdjustment(blackPoint: 0.05, whitePoint: 1.2)
            ) == #"{"blackPoint":0.05,"whitePoint":1.2}"#
        )
        #expect(
            try Self.encoded(
                try UserLevelsAdjustment(blackPoint: -0.25, whitePoint: 2)
            ) == #"{"blackPoint":-0.25,"whitePoint":2}"#
        )
    }

    @Test(
        "Every publicly constructible value round-trips",
        arguments: [
            (0.0, 1.0), (0.05, 1.2), (-0.25, 2.0), (-1.5, -0.5), (3.0, 4.0),
            (0.1, 0.9), (-1e6, 1e6),
        ]
    )
    func everyValueRoundTrips(blackPoint: Double, whitePoint: Double) throws {
        let original = try UserLevelsAdjustment(
            blackPoint: blackPoint, whitePoint: whitePoint
        )
        let decoded = try Self.decode(try Self.encoded(original))
        #expect(decoded == original)
        #expect(decoded.blackPoint == blackPoint)
        #expect(decoded.whitePoint == whitePoint)
    }

    @Test(
        "A missing endpoint is refused rather than defaulted",
        arguments: [
            (#"{"whitePoint":1}"#, "blackPoint"),
            (#"{"blackPoint":0}"#, "whitePoint"),
            ("{}", "blackPoint"),
            (#"{"blackPoint":null,"whitePoint":1}"#, "blackPoint"),
        ]
    )
    func aMissingEndpointIsRefused(json: String, field: String) {
        #expect {
            _ = try Self.decode(json)
        } throws: { error in
            guard case .missingLevelsField(let reported) =
                    error as? ImageAdjustmentError else { return false }
            return reported == field
        }
    }

    @Test("A persisted pair in the wrong order is refused, not read leniently")
    func aReversedRecordIsRefused() {
        #expect {
            _ = try Self.decode(#"{"blackPoint":1.2,"whitePoint":0.3}"#)
        } throws: { error in
            guard case .levelsNotOrdered = error as? ImageAdjustmentError else {
                return false
            }
            return true
        }
        #expect {
            _ = try Self.decode(#"{"blackPoint":0.5,"whitePoint":0.5}"#)
        } throws: { error in
            guard case .levelsNotOrdered = error as? ImageAdjustmentError else {
                return false
            }
            return true
        }
    }

    /// The decoder takes the same path construction does, so a persisted pair
    /// cannot reach an adjustment that `init` would have refused.
    @Test("Decoding enforces exactly what construction enforces")
    func decodingAndConstructionAgree() {
        #expect {
            _ = try Self.decode(#"{"blackPoint":0,"whitePoint":5e-324}"#)
        } throws: { error in
            guard case .levelsSpanNotRepresentable =
                    error as? ImageAdjustmentError else { return false }
            return true
        }
    }

    @Test("The description a control shows is the pair, not a judgement")
    func theDescriptionIsThePair() throws {
        let adjustment = try UserLevelsAdjustment(blackPoint: 0.05, whitePoint: 1.2)
        #expect(adjustment.levelsDescription == "black 0.050, white 1.200")
    }
}
