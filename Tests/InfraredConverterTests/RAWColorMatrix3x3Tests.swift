import Testing
import Foundation
@testable import InfraredConverter

/// The fixed 3×3 matrix type: what it accepts, what it refuses, and the one
/// multiplication convention the whole project reads it under.
///
/// The type is representation-neutral — the camera-to-working transform and
/// the creative infrared channel mix both interpret it — so nothing here
/// assumes an input is camera RGB or an output is working RGB.
@Suite("RAWColorMatrix3x3")
struct RAWColorMatrix3x3Tests {

    /// Deliberately non-symmetric, so an implementation that transposed the
    /// matrix could not agree with these expectations by coincidence. Every
    /// coefficient is an exact binary fraction, so the arithmetic below is
    /// exact and can be compared with `==`.
    static func asymmetric() throws -> RAWColorMatrix3x3 {
        try RAWColorMatrix3x3(
            m00: 1.5, m01: -0.25, m02: 0.75,
            m10: 0.5, m11: 2.0, m12: -1.25,
            m20: -0.125, m21: 0.375, m22: 3.0
        )
    }

    // MARK: - Convention

    @Test("Rows are output channels and columns are input channels")
    func rowsAreOutputsColumnsAreInputs() throws {
        let matrix = try Self.asymmetric()

        // m12 is row 1 (output green), column 2 (input blue).
        #expect(matrix.m12 == -1.25)
        #expect(matrix.coefficient(row: 1, column: 2) == -1.25)
        #expect(matrix.rows[1][2] == -1.25)

        // The full row-major reading, spelled out.
        #expect(matrix.rows == [[1.5, -0.25, 0.75], [0.5, 2.0, -1.25], [-0.125, 0.375, 3.0]])

        // Out-of-range indices return nil rather than trapping.
        #expect(matrix.coefficient(row: 3, column: 0) == nil)
        #expect(matrix.coefficient(row: 0, column: -1) == nil)
    }

    @Test("The matrix is not its own transpose, so orientation tests can bite")
    func matrixIsNotSymmetric() throws {
        let matrix = try Self.asymmetric()
        let transposed = try RAWColorMatrix3x3(
            m00: matrix.m00, m01: matrix.m10, m02: matrix.m20,
            m10: matrix.m01, m11: matrix.m11, m12: matrix.m21,
            m20: matrix.m02, m21: matrix.m12, m22: matrix.m22
        )
        #expect(matrix != transposed)
    }

    // MARK: - Identity

    @Test("Identity is exactly the identity, and knows it")
    func identityIsIdentity() throws {
        let identity = RAWColorMatrix3x3.identity
        #expect(identity.rows == [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
        #expect(identity.isIdentity)
        #expect(identity.determinant == 1)

        // Built by hand, it is the same value.
        let handBuilt = try RAWColorMatrix3x3(
            m00: 1, m01: 0, m02: 0,
            m10: 0, m11: 1, m12: 0,
            m20: 0, m21: 0, m22: 1
        )
        #expect(handBuilt == identity)
        #expect(handBuilt.isIdentity)

        // A negative zero off the diagonal is still a zero contribution, and
        // `Double` equality says so.
        let negativeZeros = try RAWColorMatrix3x3(
            m00: 1, m01: -0.0, m02: -0.0,
            m10: -0.0, m11: 1, m12: -0.0,
            m20: -0.0, m21: -0.0, m22: 1
        )
        #expect(negativeZeros.isIdentity)

        #expect(!(try Self.asymmetric().isIdentity))
    }

    // MARK: - Validation

    @Test("A non-finite coefficient is refused, with its position")
    func nonFiniteCoefficientsAreRefused() {
        #expect {
            _ = try RAWColorMatrix3x3(
                m00: 1, m01: 0, m02: 0,
                m10: 0, m11: .nan, m12: 0,
                m20: 0, m21: 0, m22: 1
            )
        } throws: { error in
            guard case .invalidColorMatrix3x3(let row, let column, let value) =
                    error as? RAWProcessingError else { return false }
            return row == 1 && column == 1 && value.isNaN
        }

        #expect {
            _ = try RAWColorMatrix3x3(
                m00: .infinity, m01: 0, m02: 0,
                m10: 0, m11: 1, m12: 0,
                m20: 0, m21: 0, m22: 1
            )
        } throws: { error in
            guard case .invalidColorMatrix3x3(let row, let column, let value) =
                    error as? RAWProcessingError else { return false }
            return row == 0 && column == 0 && value == .infinity
        }

        #expect {
            _ = try RAWColorMatrix3x3(
                m00: 1, m01: 0, m02: 0,
                m10: 0, m11: 1, m12: 0,
                m20: 0, m21: 0, m22: -.infinity
            )
        } throws: { error in
            guard case .invalidColorMatrix3x3(let row, let column, let value) =
                    error as? RAWProcessingError else { return false }
            return row == 2 && column == 2 && value == -.infinity
        }
    }

    /// The coefficients conventional colour work would refuse and infrared
    /// false-colour work legitimately needs.
    @Test("Zero, negative, above-one and singular matrices are all accepted")
    func unconventionalMatricesAreAccepted() throws {
        let allZero = try RAWColorMatrix3x3(
            m00: 0, m01: 0, m02: 0,
            m10: 0, m11: 0, m12: 0,
            m20: 0, m21: 0, m22: 0
        )
        #expect(allZero.determinant == 0)

        let negative = try RAWColorMatrix3x3(
            m00: -1, m01: -2, m02: -3,
            m10: -4, m11: -5, m12: -6,
            m20: -7, m21: -8, m22: -10
        )
        #expect(negative.m00 == -1)

        let large = try RAWColorMatrix3x3(
            m00: 1000, m01: 0, m02: 0,
            m10: 0, m11: 2500.5, m12: 0,
            m20: 0, m21: 0, m22: 9999
        )
        #expect(large.m11 == 2500.5)

        // Rows 0 and 1 are linearly dependent: determinant 0, no inverse,
        // accepted anyway. Nothing in the project inverts a matrix.
        let singular = try RAWColorMatrix3x3(
            m00: 1, m01: 2, m02: 3,
            m10: 2, m11: 4, m12: 6,
            m20: 0, m21: 1, m22: 0
        )
        #expect(singular.determinant == 0)

        // Rows that do not sum to 1, and a channel swap.
        let swap = try RAWColorMatrix3x3(
            m00: 0, m01: 0, m02: 1,
            m10: 0, m11: 1, m12: 0,
            m20: 1, m21: 0, m22: 0
        )
        #expect(swap.determinant == -1)
    }

    @Test("The shape is fixed, so there is no size to validate")
    func theShapeIsFixed() throws {
        #expect(RAWColorMatrix3x3.dimension == 3)
        let matrix = try Self.asymmetric()
        #expect(matrix.rows.count == 3)
        #expect(matrix.rows.allSatisfy { $0.count == 3 })
    }
}
