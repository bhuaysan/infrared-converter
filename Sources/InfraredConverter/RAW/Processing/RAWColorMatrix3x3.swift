import Foundation

/// A fixed 3×3 colour matrix: nine finite `Double` coefficients, immutable,
/// with one documented multiplication convention.
///
/// ## The convention, stated once
///
/// **Column-vector semantics.** The input is a column of camera-native
/// channels and the matrix multiplies it from the left:
///
/// ```text
///              ⎡ m00 m01 m02 ⎤   ⎡ cameraR ⎤
/// workingRGB = ⎢ m10 m11 m12 ⎥ × ⎢ cameraG ⎥
///              ⎣ m20 m21 m22 ⎦   ⎣ cameraB ⎦
/// ```
///
/// which written out is:
///
/// ```text
/// workingR = m00*cameraR + m01*cameraG + m02*cameraB
/// workingG = m10*cameraR + m11*cameraG + m12*cameraB
/// workingB = m20*cameraR + m21*cameraG + m22*cameraB
/// ```
///
/// So **rows are output channels and columns are input camera channels**:
/// `m12` is how much camera *blue* (column 2) contributes to working *green*
/// (row 1). Every consumer in the project uses this convention, and the tests
/// use deliberately non-symmetric matrices so a transposed implementation
/// cannot pass by coincidence.
///
/// ## Nine scalars, not nested arrays
///
/// The shape is part of the type. A `[[Double]]` can be 2×4 or ragged and has
/// to be validated at every use; this cannot be malformed, so size validation
/// belongs only where variable-shaped data actually enters the project — the
/// visible-light metadata adapter on `RAWCameraToWorkingColorTransform`.
///
/// ## Double coefficients, Float32 images
///
/// Coefficients are `Double`; there are nine of them, so their memory cost is
/// irrelevant, and carrying them at higher precision keeps the per-pixel dot
/// products from losing bits to the matrix itself. Image storage stays
/// `Float32` — see `RAWWorkingColorConverter` for how the arithmetic narrows.
///
/// ## What is validated, and what deliberately is not
///
/// Every coefficient must be **finite**. That is the whole contract.
///
/// ```text
/// rejected   NaN, +infinity, -infinity
///
/// accepted   zero coefficients
///            negative coefficients
///            coefficients above 1
///            singular matrices (determinant 0)
///            channel-swap matrices
///            rows that do not sum to 1
/// ```
///
/// Requiring positivity, invertibility, normalisation or unit row sums would
/// be importing conventional visible-light colour-matrix expectations into a
/// project whose subject is infrared false colour, where a channel swap, a
/// deliberately singular monochrome collapse and negative mixing coefficients
/// are all legitimate. A non-finite coefficient is different in kind: it
/// cannot describe any transform at all.
public struct RAWColorMatrix3x3: Equatable, Sendable {
    /// Rows and columns of the fixed shape. Always `3`.
    public static let dimension = 3

    /// Row 0 (working red), column 0 (camera red).
    public let m00: Double
    /// Row 0 (working red), column 1 (camera green).
    public let m01: Double
    /// Row 0 (working red), column 2 (camera blue).
    public let m02: Double
    /// Row 1 (working green), column 0 (camera red).
    public let m10: Double
    /// Row 1 (working green), column 1 (camera green).
    public let m11: Double
    /// Row 1 (working green), column 2 (camera blue).
    public let m12: Double
    /// Row 2 (working blue), column 0 (camera red).
    public let m20: Double
    /// Row 2 (working blue), column 1 (camera green).
    public let m21: Double
    /// Row 2 (working blue), column 2 (camera blue).
    public let m22: Double

    /// Builds a matrix without checking its coefficients.
    ///
    /// Private, and used only for literal constants written in this file whose
    /// finiteness is visible on the page. Every other route into the type
    /// validates, which is what lets the rest of the project treat "a
    /// `RAWColorMatrix3x3` exists" as "its nine coefficients are finite".
    private init(
        unchecked m00: Double, _ m01: Double, _ m02: Double,
        _ m10: Double, _ m11: Double, _ m12: Double,
        _ m20: Double, _ m21: Double, _ m22: Double
    ) {
        self.m00 = m00
        self.m01 = m01
        self.m02 = m02
        self.m10 = m10
        self.m11 = m11
        self.m12 = m12
        self.m20 = m20
        self.m21 = m21
        self.m22 = m22
    }

    /// Builds a matrix from nine coefficients in row-major order, rejecting
    /// any that is not finite.
    ///
    /// - Throws: `RAWProcessingError.invalidWorkingColorMatrix`, carrying the
    ///   row, the column and the offending value — reported at construction so
    ///   a matrix that cannot describe a transform never reaches a pixel.
    public init(
        m00: Double, m01: Double, m02: Double,
        m10: Double, m11: Double, m12: Double,
        m20: Double, m21: Double, m22: Double
    ) throws {
        let coefficients = [
            (0, 0, m00), (0, 1, m01), (0, 2, m02),
            (1, 0, m10), (1, 1, m11), (1, 2, m12),
            (2, 0, m20), (2, 1, m21), (2, 2, m22),
        ]
        for (row, column, value) in coefficients where !value.isFinite {
            throw RAWProcessingError.invalidWorkingColorMatrix(
                row: row, column: column, value: value
            )
        }
        self.init(
            unchecked: m00, m01, m02,
            m10, m11, m12,
            m20, m21, m22
        )
    }

    /// The identity matrix.
    ///
    /// ```text
    /// 1 0 0
    /// 0 1 0
    /// 0 0 1
    /// ```
    ///
    /// As a *matrix* this is arithmetically neutral and nothing more. What it
    /// means as a camera-to-working transform — that sensor responses are
    /// being assigned to working-space axes deliberately, without a colour
    /// calibration — is a separate statement, made by
    /// `RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor`.
    public static let identity = RAWColorMatrix3x3(
        unchecked: 1, 0, 0,
        0, 1, 0,
        0, 0, 1
    )

    /// True when this is exactly the identity matrix.
    ///
    /// Uses `Double` equality, so a coefficient of `-0.0` counts as zero. That
    /// is deliberate: `-0.0` and `+0.0` differ only in the sign of a zero
    /// contribution, and the bit-preserving identity path a match selects is
    /// the more faithful of the two treatments — see
    /// `RAWWorkingColorConverter`.
    public var isIdentity: Bool { self == .identity }

    /// One coefficient by position, or `nil` when either index is outside
    /// `0..<3`. For diagnostics and tests; the per-pixel path reads the stored
    /// properties directly.
    public func coefficient(row: Int, column: Int) -> Double? {
        switch (row, column) {
        case (0, 0): return m00
        case (0, 1): return m01
        case (0, 2): return m02
        case (1, 0): return m10
        case (1, 1): return m11
        case (1, 2): return m12
        case (2, 0): return m20
        case (2, 1): return m21
        case (2, 2): return m22
        default: return nil
        }
    }

    /// The nine coefficients as three rows of three, row-major, for reporting.
    /// Not the storage representation and not the per-pixel path.
    public var rows: [[Double]] {
        [[m00, m01, m02], [m10, m11, m12], [m20, m21, m22]]
    }

    /// The determinant, as a diagnostic only.
    ///
    /// Nothing in the project requires it to be non-zero: a singular matrix is
    /// a legitimate transform — collapsing three channels to a monochrome
    /// working image is exactly that — and this stage never inverts anything.
    public var determinant: Double {
        m00 * (m11 * m22 - m12 * m21)
            - m01 * (m10 * m22 - m12 * m20)
            + m02 * (m10 * m21 - m11 * m20)
    }
}
