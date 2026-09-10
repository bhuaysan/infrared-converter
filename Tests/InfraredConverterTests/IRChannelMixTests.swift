import Testing
import Foundation
@testable import InfraredConverter

/// The creative channel-mix configuration: which working space it was authored
/// for, which matrix it applies, and where it came from.
///
/// Nothing here processes a pixel. The point of this suite is the pairing —
/// that a matrix and the provenance describing it cannot be separated or
/// mismatched — and the exact coefficients of the two built-ins.
@Suite("IRChannelMix")
struct IRChannelMixTests {

    // MARK: - Identity

    @Test("Identity is the identity matrix, in the working space, provenance .identity")
    func identityIsIdentity() {
        let mix = IRChannelMix.identity
        #expect(mix.matrix == .identity)
        #expect(mix.matrix.rows == [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
        #expect(mix.matrix.isIdentity)
        #expect(mix.workingColorSpace == .extendedLinearSRGB)
        #expect(mix.source == .identity)
    }

    // MARK: - Red/blue swap

    @Test("Red/blue swap is exactly the outer-channel permutation")
    func redBlueSwapMatrixIsExact() {
        let mix = IRChannelMix.redBlueSwap
        #expect(mix.matrix.rows == [[0, 0, 1], [0, 1, 0], [1, 0, 0]])
        #expect(mix.matrix.m00 == 0)
        #expect(mix.matrix.m01 == 0)
        #expect(mix.matrix.m02 == 1)
        #expect(mix.matrix.m10 == 0)
        #expect(mix.matrix.m11 == 1)
        #expect(mix.matrix.m12 == 0)
        #expect(mix.matrix.m20 == 1)
        #expect(mix.matrix.m21 == 0)
        #expect(mix.matrix.m22 == 0)
        #expect(!mix.matrix.isIdentity)
        #expect(mix.workingColorSpace == .extendedLinearSRGB)
        #expect(mix.source == .redBlueSwap)

        // Reading it under the project's convention — rows are output
        // channels, columns input channels — says output red comes from input
        // blue and nothing else.
        #expect(mix.matrix.coefficient(row: 0, column: 2) == 1)
        #expect(mix.matrix.coefficient(row: 2, column: 0) == 1)
        // A permutation is invertible; it is its own inverse.
        #expect(mix.matrix.determinant == -1)
    }

    // MARK: - Explicit

    @Test("An explicit mix records .explicit and stores the matrix unchanged")
    func explicitStoresTheMatrixUnchanged() throws {
        let matrix = try RAWColorMatrix3x3(
            m00: 1.5, m01: -0.25, m02: 0.75,
            m10: 0.5, m11: 2.0, m12: -1.25,
            m20: -0.125, m21: 0.375, m22: 3.0
        )
        let mix = IRChannelMix.explicit(matrix: matrix)
        #expect(mix.source == .explicit)
        #expect(mix.workingColorSpace == .extendedLinearSRGB)
        // Not normalised, not rescaled, not reordered.
        #expect(mix.matrix == matrix)
        #expect(mix.matrix.rows == matrix.rows)
    }

    @Test("An explicit matrix equal to a built-in keeps .explicit provenance")
    func explicitMatchingABuiltInStaysExplicit() throws {
        let swapMatrix = try RAWColorMatrix3x3(
            m00: 0, m01: 0, m02: 1,
            m10: 0, m11: 1, m12: 0,
            m20: 1, m21: 0, m22: 0
        )
        let explicitSwap = IRChannelMix.explicit(matrix: swapMatrix)
        #expect(explicitSwap.matrix == IRChannelMix.redBlueSwap.matrix)
        #expect(explicitSwap.source == .explicit)
        #expect(explicitSwap != IRChannelMix.redBlueSwap)

        let explicitIdentity = IRChannelMix.explicit(matrix: .identity)
        #expect(explicitIdentity.matrix == IRChannelMix.identity.matrix)
        #expect(explicitIdentity.source == .explicit)
        #expect(explicitIdentity != IRChannelMix.identity)
    }

    /// The coefficients conventional colour work would refuse and infrared
    /// creative work legitimately needs. The mix imposes no policy of its own;
    /// the matrix primitive has already checked the only thing that is
    /// checked, which is finiteness.
    @Test("Negative, above-one, singular and non-normalised mixes are all accepted")
    func creativeMatricesAreAccepted() throws {
        let negative = IRChannelMix.explicit(matrix: try RAWColorMatrix3x3(
            m00: 1.2, m01: -0.2, m02: 0,
            m10: 0, m11: 1, m12: 0,
            m20: 0, m21: 0, m22: 1
        ))
        #expect(negative.matrix.m01 == -0.2)
        // Row sums are left alone: 1.2 + (-0.2) = 1.0 here only by accident,
        // and nothing requires it.
        #expect(negative.matrix.rows[0].reduce(0, +) == 1.0)

        let monochrome = IRChannelMix.explicit(matrix: try RAWColorMatrix3x3(
            m00: 0.3, m01: 0.59, m02: 0.11,
            m10: 0.3, m11: 0.59, m12: 0.11,
            m20: 0.3, m21: 0.59, m22: 0.11
        ))
        #expect(monochrome.matrix.determinant == 0)

        let amplifying = IRChannelMix.explicit(matrix: try RAWColorMatrix3x3(
            m00: 4, m01: 0, m02: 0,
            m10: 0, m11: 4, m12: 0,
            m20: 0, m21: 0, m22: 4
        ))
        #expect(amplifying.matrix.m00 == 4)
    }

    @Test("A non-finite coefficient is refused by the matrix, before a mix exists")
    func nonFiniteCoefficientsNeverReachAMix() {
        #expect {
            _ = IRChannelMix.explicit(matrix: try RAWColorMatrix3x3(
                m00: 1, m01: 0, m02: 0,
                m10: 0, m11: .nan, m12: 0,
                m20: 0, m21: 0, m22: 1
            ))
        } throws: { error in
            guard case .invalidColorMatrix3x3(let row, let column, let value) =
                    error as? RAWProcessingError else { return false }
            return row == 1 && column == 1 && value.isNaN
        }
    }

    // MARK: - Provenance sources

    @Test("Exactly three provenance cases exist, and they are distinct")
    func provenanceCasesAreDistinct() {
        let sources: [IRChannelMixSource] = [.identity, .redBlueSwap, .explicit]
        #expect(Set(sources.map(\.diagnosticDescription)).count == 3)
        #expect(IRChannelMixSource.identity != .redBlueSwap)
        #expect(IRChannelMixSource.redBlueSwap != .explicit)
        #expect(IRChannelMixSource.explicit != .identity)
    }
}
