import Foundation

/// How well-determined a fit was by the data it was given.
///
/// Reported alongside every solution, not only failures. A fit that only just
/// cleared the conditioning floor is a different claim from one over a chart
/// whose patches genuinely differ, and the number that distinguishes them
/// belongs in the artefact rather than in a log line.
public struct IRCalibrationConditioning: Equatable, Sendable {

    /// The determinant of the Gram matrix of the **column-normalised** camera
    /// responses.
    ///
    /// Between `0` and `1` by construction. `1` would mean the three camera
    /// channels are mutually orthogonal over the measured patches — as
    /// independent as this data can be. `0` means they are linearly dependent
    /// and no unique transform exists. Normalising the columns first is what
    /// makes the number comparable between captures: an unnormalised
    /// determinant scales with the cube of exposure, so it would say more about
    /// how bright the chart was than about whether it was informative.
    public let normalizedGramDeterminant: Double

    /// The Euclidean norm of each camera channel's column, before
    /// normalisation.
    ///
    /// Kept because a channel with a tiny norm is a channel the fit knows
    /// almost nothing about, even when the determinant looks acceptable.
    public let channelNorms: [Double]

    public let sampleCount: Int

    /// Samples beyond the three a 3x3 row needs.
    ///
    /// Zero means the fit is exact by construction and its residuals are
    /// zero for arithmetic reasons rather than for measurement reasons.
    public var degreesOfFreedom: Int { max(0, sampleCount - 3) }

    init(normalizedGramDeterminant: Double, channelNorms: [Double], sampleCount: Int) {
        self.normalizedGramDeterminant = normalizedGramDeterminant
        self.channelNorms = channelNorms
        self.sampleCount = sampleCount
    }

    public var diagnosticDescription: String {
        String(
            format: "normalised Gram determinant %.6g over %d samples (%d degrees of freedom)",
            normalizedGramDeterminant, sampleCount, degreesOfFreedom
        )
    }
}

/// A deterministic ordinary-least-squares fit of a 3x3 matrix.
///
/// ## What it computes
///
/// ```text
/// minimise   Σ  || M · cᵢ  −  rᵢ ||²
///            i
///
/// cᵢ   camera response of patch i, an (R, G, B) column vector
/// rᵢ   reference value of patch i, an (R, G, B) column vector
/// M    the 3x3 transform
/// ```
///
/// **Matrix convention: `output = M × input`, column vectors, channel order
/// R, G, B.** Row `k` of `M` produces output channel `k`. That is the
/// convention ``RAWColorMatrix3x3`` and ``RAWWorkingColorConverter`` already
/// use, and this project has exactly one; a solver that returned the transpose
/// would be a second convention hiding behind a type that looks like the first.
///
/// ## What it deliberately does not compute
///
/// - **No offset term.** The model is a pure linear map, not affine. An
///   intercept would absorb a black-level error into the transform and make it
///   impossible to tell the two apart — and black level is already handled, in
///   one place, upstream.
/// - **No regularisation.** Not ridge, not a prior, not a nudge towards the
///   identity. A fit stabilised by an undocumented prior is not a measurement
///   of anything, and the failure mode is silent: it always succeeds. Ill-
///   conditioned data is refused instead.
/// - **No weighting.** Every included patch counts once. Weighting schemes are
///   a modelling decision that needs justification from real data, and none
///   exists.
///
/// ## Determinism
///
/// Fixed traversal order, no randomness, no iteration to a tolerance, no
/// parallel reduction. The same samples in the same order give bit-identical
/// coefficients, which is what makes a stored calibration checkable by
/// recomputing it.
///
/// Arithmetic is `Double` throughout, including the accumulation of the normal
/// equations, even though the measured means arrive as `Double` from `Float`
/// samples. The normal equations square the data, which costs roughly half the
/// available significant digits; doing that in `Float` would leave a
/// twenty-four-patch fit with fewer digits than the measurements have.
public struct IRCalibrationMatrixSolver: Sendable {

    /// The identifier stored with a fit, so a reader knows what produced it.
    public static let algorithm = "least-squares-3x3"

    /// Bumped when the arithmetic changes in a way that changes coefficients.
    public static let algorithmVersion = 1

    /// The fewest patches this solver will fit from.
    ///
    /// Three is the algebraic minimum: three independent samples determine a
    /// 3x3 map exactly. The fourth is required because a fit with no degrees of
    /// freedom has zero residuals for arithmetic reasons, and a calibration
    /// whose error metrics are zero by construction is exactly the false
    /// confidence this subsystem exists to prevent.
    ///
    /// This is a stated engineering floor, not a scientific threshold. The
    /// protocol asks for a full chart.
    public static let minimumSamples = 4

    /// The conditioning floor, below which the data is refused.
    ///
    /// A numerical-degeneracy guard, not a quality threshold: it separates
    /// "this data determines no unique transform" from "this data determines a
    /// poor one". Poor fits are reported with their residuals and left for a
    /// person to judge. The value is the point at which the normalised Gram
    /// determinant is small enough that the solution is dominated by rounding
    /// in `Double` rather than by the measurements.
    public static let minimumNormalizedGramDeterminant = 1e-9

    /// One patch's pair: what the camera produced, and what it should become.
    public struct Sample: Equatable, Sendable {

        /// Identifies the sample in refusals. Not used in the arithmetic.
        public let label: String

        /// Camera response, `(R, G, B)`.
        public let input: SIMD3<Double>

        /// Reference value, `(R, G, B)`.
        public let output: SIMD3<Double>

        public init(label: String, input: SIMD3<Double>, output: SIMD3<Double>) {
            self.label = label
            self.input = input
            self.output = output
        }
    }

    public struct Solution: Equatable, Sendable {
        public let matrix: RAWColorMatrix3x3
        public let conditioning: IRCalibrationConditioning
    }

    public init() {}

    public func solve(_ samples: [Sample]) throws(IRCalibrationFitError) -> Solution {
        guard samples.count >= Self.minimumSamples else {
            throw .insufficientSamples(
                found: samples.count, minimum: Self.minimumSamples
            )
        }

        let channelNames = ["red", "green", "blue"]

        for sample in samples {
            for index in 0..<3 {
                let input = sample.input[index]
                guard input.isFinite else {
                    throw .nonFiniteSample(
                        patch: sample.label,
                        field: "camera \(channelNames[index])",
                        value: input
                    )
                }
                let output = sample.output[index]
                guard output.isFinite else {
                    throw .nonFiniteSample(
                        patch: sample.label,
                        field: "reference \(channelNames[index])",
                        value: output
                    )
                }
            }
        }

        // Gram matrix G = CᵀC and right-hand side B = CᵀR, accumulated in one
        // pass. Symmetric, so only the upper triangle is summed and mirrored.
        var gram = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        var rhs = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)

        for sample in samples {
            for row in 0..<3 {
                for column in row..<3 {
                    gram[row][column] += sample.input[row] * sample.input[column]
                }
                for channel in 0..<3 {
                    rhs[row][channel] += sample.input[row] * sample.output[channel]
                }
            }
        }
        for row in 1..<3 {
            for column in 0..<row {
                gram[row][column] = gram[column][row]
            }
        }

        // Column norms come straight off the Gram diagonal: G[j][j] = Σᵢ cᵢⱼ².
        let norms = (0..<3).map { gram[$0][$0].squareRoot() }
        for (index, norm) in norms.enumerated() {
            guard norm.isFinite else {
                throw .nonFiniteCoefficient(row: index, column: index)
            }
            guard norm > 0 else {
                throw .zeroChannelVariation(channel: channelNames[index])
            }
        }

        // Conditioning is judged on the column-normalised Gram, so that the
        // verdict does not depend on how bright the chart happened to be.
        var normalized = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for row in 0..<3 {
            for column in 0..<3 {
                normalized[row][column] = gram[row][column] / (norms[row] * norms[column])
            }
        }
        let determinant = Self.determinant3x3(normalized)
        let conditioning = IRCalibrationConditioning(
            normalizedGramDeterminant: determinant,
            channelNorms: norms,
            sampleCount: samples.count
        )

        guard determinant.isFinite else {
            throw .singularNormalEquations(
                reason: "The normalised Gram determinant is not a finite number."
            )
        }
        guard determinant >= Self.minimumNormalizedGramDeterminant else {
            throw .illConditioned(
                normalizedGramDeterminant: determinant,
                minimum: Self.minimumNormalizedGramDeterminant
            )
        }

        // Solve G X = B. Column k of X is the coefficient vector of output
        // channel k, so M = Xᵀ.
        let solution = try Self.solveLinearSystem(gram, rhs)

        let matrix: RAWColorMatrix3x3
        do {
            matrix = try RAWColorMatrix3x3(
                m00: solution[0][0], m01: solution[1][0], m02: solution[2][0],
                m10: solution[0][1], m11: solution[1][1], m12: solution[2][1],
                m20: solution[0][2], m21: solution[1][2], m22: solution[2][2]
            )
        } catch {
            // `RAWColorMatrix3x3` refuses non-finite coefficients, and reports
            // which one. Restated in this domain's own vocabulary rather than
            // leaked as a RAW-processing error.
            guard case RAWProcessingError.invalidColorMatrix3x3(let row, let column, _) = error
            else {
                throw .singularNormalEquations(
                    reason: "The solved coefficients were refused: \(error.localizedDescription)"
                )
            }
            throw .nonFiniteCoefficient(row: row, column: column)
        }

        return Solution(matrix: matrix, conditioning: conditioning)
    }

    // MARK: - Linear algebra

    private static func determinant3x3(_ m: [[Double]]) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }

    /// Gaussian elimination with partial pivoting, solving `A X = B` for a 3x3
    /// `A` and a 3x3 `B`, all three right-hand sides at once.
    ///
    /// Partial pivoting rather than none: the normal equations of a chart whose
    /// channels differ in scale have a poorly scaled diagonal, and eliminating
    /// on a small pivot loses digits for no reason. Not full pivoting, which
    /// would reorder the unknowns and buy nothing here — the conditioning gate
    /// above has already refused the cases where it would matter.
    private static func solveLinearSystem(
        _ a: [[Double]], _ b: [[Double]]
    ) throws(IRCalibrationFitError) -> [[Double]] {
        var a = a
        var x = b

        for pivot in 0..<3 {
            var best = pivot
            var bestMagnitude = abs(a[pivot][pivot])
            for row in (pivot + 1)..<3 where abs(a[row][pivot]) > bestMagnitude {
                best = row
                bestMagnitude = abs(a[row][pivot])
            }
            guard bestMagnitude > 0 else {
                throw .singularNormalEquations(
                    reason: """
                        Elimination reached column \(pivot) with no non-zero pivot available, \
                        so the measured camera responses are linearly dependent.
                        """
                )
            }
            if best != pivot {
                a.swapAt(pivot, best)
                x.swapAt(pivot, best)
            }

            let pivotValue = a[pivot][pivot]
            for row in (pivot + 1)..<3 {
                let factor = a[row][pivot] / pivotValue
                guard factor.isFinite else {
                    throw .singularNormalEquations(
                        reason: "Elimination produced a non-finite multiplier at row \(row)."
                    )
                }
                for column in pivot..<3 {
                    a[row][column] -= factor * a[pivot][column]
                }
                for channel in 0..<3 {
                    x[row][channel] -= factor * x[pivot][channel]
                }
            }
        }

        for row in stride(from: 2, through: 0, by: -1) {
            for channel in 0..<3 {
                var value = x[row][channel]
                for column in (row + 1)..<3 {
                    value -= a[row][column] * x[column][channel]
                }
                let solved = value / a[row][row]
                guard solved.isFinite else {
                    throw .nonFiniteCoefficient(row: channel, column: row)
                }
                x[row][channel] = solved
            }
        }

        return x
    }
}
