import Testing
import Foundation
@testable import InfraredConverter

/// The user's creative channel-mix decision: what the three states mean, what
/// processing value each derives, and what a persisted record may not be.
@Suite("UserChannelMixAdjustment")
struct UserChannelMixAdjustmentTests {

    // MARK: - The three states

    @Test("Each state derives the processing mix that matches it")
    func eachStateDerivesItsMix() throws {
        #expect(UserChannelMixAdjustment.identity.mix == IRChannelMix.identity)
        #expect(UserChannelMixAdjustment.identity.mix.source == .identity)
        #expect(UserChannelMixAdjustment.identity.matrix.isIdentity)

        #expect(UserChannelMixAdjustment.redBlueSwap.mix == IRChannelMix.redBlueSwap)
        #expect(UserChannelMixAdjustment.redBlueSwap.mix.source == .redBlueSwap)
        #expect(UserChannelMixAdjustment.redBlueSwap.matrix == IRChannelMix.redBlueSwap.matrix)

        let matrix = try RAWColorMatrix3x3(
            m00: 0.1, m01: 0.2, m02: 0.3,
            m10: 0.4, m11: 0.5, m12: 0.6,
            m20: 0.7, m21: 0.8, m22: 0.9
        )
        let explicit = UserChannelMixAdjustment.explicit(matrix)
        #expect(explicit.mix == IRChannelMix.explicit(matrix: matrix))
        #expect(explicit.mix.source == .explicit)
        #expect(explicit.matrix == matrix)
    }

    /// The working colour space is derived, never chosen by the adjustment and
    /// never persisted. One exists (ADR 0006), and a sidecar that could name
    /// another would be a sidecar that selects a colour space.
    @Test("Every state's mix is authored for the project's one working space")
    func everyMixNamesTheWorkingSpace() throws {
        let explicit = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [1, 2, 3, 4, 5, 6, 7, 8, 9]
        )
        for adjustment in [UserChannelMixAdjustment.identity, .redBlueSwap, explicit] {
            #expect(adjustment.mix.workingColorSpace == .extendedLinearSRGB)
        }
    }

    @Test("The kinds and the selectable cases are the documented ones")
    func theKindsAreStated() {
        #expect(UserChannelMixAdjustment.identity.kind == .identity)
        #expect(UserChannelMixAdjustment.redBlueSwap.kind == .redBlueSwap)
        #expect(UserChannelMixAdjustment.explicit(.identity).kind == .matrix)
        #expect(UserChannelMixAdjustment.Kind.allCases.count == 3)

        // A control offers the two a person can reach. `.explicit` is
        // persistable and applicable and has no editor, so it is not offered.
        #expect(UserChannelMixAdjustment.selectableCases == [.identity, .redBlueSwap])
    }

    // MARK: - isIdentity is a net effect, not a provenance

    @Test("An explicit identity matrix has no effect and is still not .identity")
    func explicitIdentityIsNotTheIdentityCase() throws {
        let explicit = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
        )
        // No net effect on the image...
        #expect(explicit.isIdentity)
        // ...and a different decision, which persists differently and carries
        // different provenance. ADR 0007, Decision 19.
        #expect(explicit != .identity)
        #expect(explicit.mix.source == .explicit)
        #expect(UserChannelMixAdjustment.identity.mix.source == .identity)
    }

    @Test("The swap has an effect and an explicit swap matrix does too")
    func theSwapIsNotTheIdentity() throws {
        #expect(!UserChannelMixAdjustment.redBlueSwap.isIdentity)
        let explicitSwap = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [0, 0, 1, 0, 1, 0, 1, 0, 0]
        )
        #expect(!explicitSwap.isIdentity)
        #expect(explicitSwap != .redBlueSwap)
        #expect(explicitSwap.matrix == UserChannelMixAdjustment.redBlueSwap.matrix)
    }

    // MARK: - It is a state, not a history

    /// There is no "swap again". Asking for a mix replaces whatever was asked
    /// for, which is the editing model's half of "mixes never compose".
    @Test("Asking twice for the same mix is one state, not two operations")
    func askingTwiceIsOneState() {
        var mix = UserChannelMixAdjustment.identity
        mix = .redBlueSwap
        mix = .redBlueSwap
        #expect(mix == .redBlueSwap)
        // Had it been an operation, two swaps would be the identity.
        #expect(!mix.isIdentity)
    }

    // MARK: - Persistence

    @Test("The persisted shape is the documented one")
    func thePersistedShapeIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        #expect(
            String(decoding: try encoder.encode(UserChannelMixAdjustment.identity), as: UTF8.self)
                == #"{"kind":"identity"}"#
        )
        #expect(
            String(
                decoding: try encoder.encode(UserChannelMixAdjustment.redBlueSwap),
                as: UTF8.self
            ) == #"{"kind":"redBlueSwap"}"#
        )
        let explicit = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [0, 0.5, -1, 2, 1, 0, 0, 0, 0.25]
        )
        #expect(
            String(decoding: try encoder.encode(explicit), as: UTF8.self)
                == #"{"kind":"matrix","matrix":[0,0.5,-1,2,1,0,0,0,0.25]}"#
        )
    }

    @Test("The coefficients persist row-major, in the matrix's own convention")
    func theCoefficientsAreRowMajor() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: 11, m01: 12, m02: 13,
            m10: 21, m11: 22, m12: 23,
            m20: 31, m21: 32, m22: 33
        )
        let persisted = try #require(UserChannelMixAdjustment.explicit(matrix).persistedMatrix)
        #expect(persisted == [11, 12, 13, 21, 22, 23, 31, 32, 33])

        // And back again, unchanged.
        let restored = try UserChannelMixAdjustment.explicit(persistedMatrix: persisted)
        #expect(restored.matrix == matrix)
    }

    @Test("A built-in persists as its token alone, with no coefficients")
    func builtInsCarryNoMatrix() {
        #expect(UserChannelMixAdjustment.identity.persistedMatrix == nil)
        #expect(UserChannelMixAdjustment.redBlueSwap.persistedMatrix == nil)
    }

    @Test("Every state round-trips")
    func everyStateRoundTrips() throws {
        let explicit = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [-0.5, 0, 1.25, 3, -2, 0, 0, 0.75, 1]
        )
        for adjustment in [UserChannelMixAdjustment.identity, .redBlueSwap, explicit] {
            let data = try JSONEncoder().encode(adjustment)
            let decoded = try JSONDecoder().decode(UserChannelMixAdjustment.self, from: data)
            #expect(decoded == adjustment)
            #expect(decoded.kind == adjustment.kind)
            #expect(decoded.matrix == adjustment.matrix)
        }
    }

    // MARK: - Refusals

    /// The one refusal strict JSON cannot express, so it is reached through
    /// the factory the decoder itself uses. A NaN coefficient describes no
    /// transform at all, and no matrix built here may contain one.
    @Test(
        "A non-finite coefficient is refused",
        arguments: [Double.nan, .infinity, -.infinity, .signalingNaN]
    )
    func nonFiniteCoefficientsAreRefused(value: Double) {
        for index in 0..<9 {
            var coefficients = Array(repeating: 1.0, count: 9)
            coefficients[index] = value
            #expect(throws: ImageAdjustmentError.self) {
                _ = try UserChannelMixAdjustment.explicit(persistedMatrix: coefficients)
            }
        }
    }

    @Test("A non-finite coefficient is reported with its index")
    func nonFiniteCoefficientsNameTheirIndex() {
        var coefficients = Array(repeating: 1.0, count: 9)
        coefficients[4] = .infinity
        #expect(
            throws: ImageAdjustmentError.nonFiniteChannelMixCoefficient(
                index: 4, value: .infinity
            )
        ) {
            _ = try UserChannelMixAdjustment.explicit(persistedMatrix: coefficients)
        }
    }

    @Test(
        "A matrix that is not nine coefficients is refused",
        arguments: [0, 1, 3, 6, 8, 10, 12]
    )
    func aMalformedMatrixIsRefused(count: Int) {
        #expect(
            throws: ImageAdjustmentError.malformedChannelMixMatrix(
                coefficientCount: count, expected: 9
            )
        ) {
            _ = try UserChannelMixAdjustment.explicit(
                persistedMatrix: Array(repeating: 1.0, count: count)
            )
        }
    }

    // MARK: - A built-in is its token alone

    /// Regressions A and B. These records used to decode, with the
    /// coefficients silently ignored — including coefficients that are not
    /// the built-in's matrix at all.
    @Test(
        "A built-in carrying a matrix is refused, whatever the coefficients",
        arguments: [
            ("identity", "[9,9,9,9,9,9,9,9,9]"),
            ("identity", "[1,0,0,0,1,0,0,0,1]"),
            ("redBlueSwap", "[9,9,9,9,9,9,9,9,9]"),
            ("redBlueSwap", "[0,0,1,0,1,0,1,0,0]"),
            ("redBlueSwap", "[1,2,3]"),
            ("identity", "[]"),
            ("redBlueSwap", "null"),
        ]
    )
    func aBuiltInCarryingAMatrixIsRefused(kind: String, matrix: String) {
        let json = Data(#"{"kind":"\#(kind)","matrix":\#(matrix)}"#.utf8)
        #expect(
            throws: ImageAdjustmentError.unexpectedChannelMixField(field: "matrix", kind: kind)
        ) {
            try JSONDecoder().decode(UserChannelMixAdjustment.self, from: json)
        }
    }

    /// Regression C: the ordinary built-in records are unaffected, and an
    /// unrelated extra key is not this type's business.
    @Test("A built-in token on its own still reads")
    func aBareBuiltInStillReads() throws {
        #expect(
            try JSONDecoder().decode(
                UserChannelMixAdjustment.self, from: Data(#"{"kind":"identity"}"#.utf8)
            ) == .identity
        )
        #expect(
            try JSONDecoder().decode(
                UserChannelMixAdjustment.self, from: Data(#"{"kind":"redBlueSwap"}"#.utf8)
            ) == .redBlueSwap
        )
        #expect(
            try JSONDecoder().decode(
                UserChannelMixAdjustment.self,
                from: Data(#"{"kind":"redBlueSwap","note":"by hand"}"#.utf8)
            ) == .redBlueSwap
        )
    }

    /// Regression D, and the remaining rows of the wire-format table.
    @Test("A matrix record reads with nine finite coefficients and only then")
    func aMatrixRecordNeedsExactlyNineFiniteCoefficients() throws {
        let valid = Data(#"{"kind":"matrix","matrix":[0.5,0,0,0,1,0,0,0,2]}"#.utf8)
        #expect(
            try JSONDecoder().decode(UserChannelMixAdjustment.self, from: valid)
                == .explicit(try RAWColorMatrix3x3(
                    m00: 0.5, m01: 0, m02: 0, m10: 0, m11: 1, m12: 0, m20: 0, m21: 0, m22: 2
                ))
        )

        #expect(throws: ImageAdjustmentError.missingChannelMixField(field: "matrix")) {
            try JSONDecoder().decode(
                UserChannelMixAdjustment.self, from: Data(#"{"kind":"matrix"}"#.utf8)
            )
        }
        #expect(
            throws: ImageAdjustmentError.malformedChannelMixMatrix(coefficientCount: 8, expected: 9)
        ) {
            try JSONDecoder().decode(
                UserChannelMixAdjustment.self,
                from: Data(#"{"kind":"matrix","matrix":[1,0,0,0,1,0,0,0]}"#.utf8)
            )
        }
        // Non-finite coefficients cannot be written in strict JSON; the
        // factory the decoder uses refuses them, as tested above.
        #expect(throws: ImageAdjustmentError.self) {
            _ = try UserChannelMixAdjustment.explicit(
                persistedMatrix: [1, 0, 0, 0, .nan, 0, 0, 0, 1]
            )
        }
    }

    @Test("The contradiction refusal names the field and the kind")
    func theContradictionRefusalIsInformative() {
        let error = ImageAdjustmentError.unexpectedChannelMixField(
            field: "matrix", kind: "redBlueSwap"
        )
        #expect(error.errorDescription?.isEmpty == false)
        #expect(error.failureReason?.contains("matrix") == true)
        #expect(error.failureReason?.contains("redBlueSwap") == true)
    }

    @Test("An unknown kind is refused, never read as identity")
    func anUnknownKindIsRefused() {
        let json = Data(#"{"kind":"candychrome"}"#.utf8)
        #expect(throws: ImageAdjustmentError.unknownChannelMixKind(token: "candychrome")) {
            try JSONDecoder().decode(UserChannelMixAdjustment.self, from: json)
        }
        #expect((try? JSONDecoder().decode(UserChannelMixAdjustment.self, from: json)) == nil)
    }

    /// What is accepted, stated as plainly as `RAWColorMatrix3x3` states it:
    /// finiteness is the whole contract, and every creative shape a mix can
    /// have is legitimate.
    @Test("Negative, amplifying and singular matrices are all accepted")
    func creativeMatricesAreAccepted() throws {
        let negative = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [1, -0.5, 0, 0, 1, 0, 0, 0, 1]
        )
        #expect(negative.matrix.m01 == -0.5)

        let amplifying = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [4, 0, 0, 0, 4, 0, 0, 0, 4]
        )
        #expect(amplifying.matrix.m00 == 4)

        // A rank-1 monochrome collapse. Nothing inverts a mix, so nothing
        // requires it to be invertible.
        let monochrome = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [0.2, 0.7, 0.1, 0.2, 0.7, 0.1, 0.2, 0.7, 0.1]
        )
        #expect(monochrome.matrix.determinant == 0)

        // Rows are not normalised and nothing is rescaled.
        let unnormalised = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [0.3, 0.3, 0.3, 1, 1, 1, 0, 0, 0]
        )
        #expect(unnormalised.matrix.rows[0] == [0.3, 0.3, 0.3])
    }

    @Test("The descriptions say the mix is creative, not calibrated")
    func theDescriptionsAreHonest() {
        for adjustment in [
            UserChannelMixAdjustment.identity, .redBlueSwap, .explicit(.identity),
        ] {
            #expect(!adjustment.shortDescription.isEmpty)
            #expect(!adjustment.diagnosticDescription.isEmpty)
            #expect(!adjustment.diagnosticDescription.lowercased().contains("calibrat")
                || adjustment.diagnosticDescription.lowercased().contains("no calibration"))
        }
        #expect(
            UserChannelMixAdjustment.redBlueSwap.diagnosticDescription.contains("creative")
        )
    }
}
