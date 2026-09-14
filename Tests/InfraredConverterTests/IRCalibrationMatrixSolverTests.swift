import Testing
import Foundation
@testable import InfraredConverter

/// The least-squares 3x3 fit on its own: that it recovers a known transform
/// exactly, that noise degrades it honestly rather than silently, and that
/// degenerate data is refused instead of producing enormous coefficients.
///
/// Every input here is synthetic. The solver is arithmetic, and arithmetic is
/// the one part of a calibration that can be tested without measuring anything.
@Suite("IRCalibrationMatrixSolver")
struct IRCalibrationMatrixSolverTests {

    static func samples(
        _ inputs: [(Double, Double, Double)],
        through matrix: RAWColorMatrix3x3,
        noise: [(Double, Double, Double)] = []
    ) -> [IRCalibrationMatrixSolver.Sample] {
        inputs.enumerated().map { index, input in
            let vector = SIMD3(input.0, input.1, input.2)
            let output = IRCalibrationFitter.apply(matrix, to: vector)
            let offset = index < noise.count ? noise[index] : (0, 0, 0)
            return IRCalibrationMatrixSolver.Sample(
                label: String(format: "%02d", index + 1),
                input: vector,
                output: SIMD3(
                    output.x + offset.0, output.y + offset.1, output.z + offset.2
                )
            )
        }
    }

    static let wellSpread = CalibrationTestData.syntheticCameraResponses()

    // MARK: - Exact recovery

    @Test("A known matrix is recovered from noiseless samples, to Double precision")
    func exactRecovery() throws {
        let known = CalibrationTestData.syntheticMatrix
        let solution = try IRCalibrationMatrixSolver()
            .solve(Self.samples(Self.wellSpread, through: known))

        // The normal equations square the data, so roughly half the available
        // significant digits are spent. 1e-10 is comfortably inside what
        // Double leaves for well-conditioned input of this scale, and far
        // tighter than any measurement could ever justify.
        let difference = CalibrationTestData.maximumCoefficientDifference(
            solution.matrix, known
        )
        #expect(difference < 1e-10, "recovered matrix differs by \(difference)")
    }

    @Test("The identity is recovered when the reference values are the responses")
    func identityRecovery() throws {
        let solution = try IRCalibrationMatrixSolver()
            .solve(Self.samples(Self.wellSpread, through: .identity))
        #expect(
            CalibrationTestData.maximumCoefficientDifference(solution.matrix, .identity)
                < 1e-12
        )
    }

    /// `output = M × input`, column vectors. A solver returning the transpose
    /// would pass every symmetric test, so the matrix used here is deliberately
    /// asymmetric and the check is on one off-diagonal coefficient.
    @Test("The recovered matrix follows the project's convention: output = M x input")
    func matrixConvention() throws {
        // Output red depends only on input green: row 0 is (0, 2, 0).
        let known = try RAWColorMatrix3x3(
            m00: 0, m01: 2, m02: 0,
            m10: 0, m11: 0, m12: 3,
            m20: 5, m21: 0, m22: 0
        )
        let solution = try IRCalibrationMatrixSolver()
            .solve(Self.samples(Self.wellSpread, through: known))

        #expect(abs(solution.matrix.m01 - 2) < 1e-10)
        #expect(abs(solution.matrix.m10) < 1e-10)
        #expect(abs(solution.matrix.m20 - 5) < 1e-10)

        // And the same convention the working-colour converter uses.
        let input = SIMD3(0.2, 0.5, 0.7)
        let applied = IRCalibrationFitter.apply(solution.matrix, to: input)
        #expect(abs(applied.x - 2 * input.y) < 1e-9)
    }

    @Test("The same samples in the same order give bit-identical coefficients")
    func determinism() throws {
        let samples = Self.samples(Self.wellSpread, through: CalibrationTestData.syntheticMatrix)
        let first = try IRCalibrationMatrixSolver().solve(samples)
        let second = try IRCalibrationMatrixSolver().solve(samples)
        #expect(first.matrix == second.matrix)
        #expect(
            first.conditioning.normalizedGramDeterminant
                == second.conditioning.normalizedGramDeterminant
        )
    }

    // MARK: - Conditioning

    @Test("Well-spread responses report a healthy conditioning number")
    func conditioningReported() throws {
        let solution = try IRCalibrationMatrixSolver()
            .solve(Self.samples(Self.wellSpread, through: CalibrationTestData.syntheticMatrix))

        #expect(solution.conditioning.sampleCount == Self.wellSpread.count)
        #expect(solution.conditioning.degreesOfFreedom == Self.wellSpread.count - 3)
        #expect(solution.conditioning.normalizedGramDeterminant > 1e-3)
        #expect(solution.conditioning.normalizedGramDeterminant <= 1.0000001)
        #expect(solution.conditioning.channelNorms.allSatisfy { $0 > 0 })
    }

    /// The determinant is computed on column-normalised responses precisely so
    /// that it says something about independence rather than about exposure.
    @Test("Conditioning does not change when every response is scaled together")
    func conditioningIsScaleInvariant() throws {
        let matrix = CalibrationTestData.syntheticMatrix
        let base = try IRCalibrationMatrixSolver()
            .solve(Self.samples(Self.wellSpread, through: matrix))
        let scaled = try IRCalibrationMatrixSolver().solve(
            Self.samples(Self.wellSpread.map { ($0.0 / 8, $0.1 / 8, $0.2 / 8) }, through: matrix)
        )

        #expect(
            abs(base.conditioning.normalizedGramDeterminant
                - scaled.conditioning.normalizedGramDeterminant) < 1e-12
        )
        // And the transform itself is unchanged, because a uniform scaling of
        // the inputs with a matching scaling of the outputs is the same map.
        #expect(CalibrationTestData.maximumCoefficientDifference(base.matrix, scaled.matrix) < 1e-9)
    }

    // MARK: - Noise

    @Test("Added noise leaves the fit finite, moves it, and raises the reported error")
    func noisyFit() throws {
        let known = CalibrationTestData.syntheticMatrix
        let clean = Self.samples(Self.wellSpread, through: known)

        // Deterministic, reproducible perturbation — no random number
        // generator, so a failure is the same failure every time.
        let noise = (0..<Self.wellSpread.count).map { index -> (Double, Double, Double) in
            let phase = Double(index)
            return (
                0.01 * sin(phase),
                0.01 * cos(phase * 1.7),
                0.01 * sin(phase * 2.3 + 1)
            )
        }
        let noisy = Self.samples(Self.wellSpread, through: known, noise: noise)

        let cleanSolution = try IRCalibrationMatrixSolver().solve(clean)
        let noisySolution = try IRCalibrationMatrixSolver().solve(noisy)

        for value in noisySolution.matrix.rows.flatMap({ $0 }) {
            #expect(value.isFinite)
        }

        let drift = CalibrationTestData.maximumCoefficientDifference(
            noisySolution.matrix, known
        )
        #expect(drift > 0, "a perturbed fit that matched the known matrix exactly would be suspicious")
        #expect(drift < 0.2, "the perturbation is small; the fit should not be wrecked by it")

        // The honesty check: the noisy fit must not claim to be exact.
        func residualRMSE(
            _ solution: IRCalibrationMatrixSolver.Solution,
            _ samples: [IRCalibrationMatrixSolver.Sample]
        ) -> Double {
            let total = samples.reduce(0.0) { sum, sample in
                let fitted = IRCalibrationFitter.apply(solution.matrix, to: sample.input)
                let error = fitted - sample.output
                return sum + error.x * error.x + error.y * error.y + error.z * error.z
            }
            return (total / Double(samples.count * 3)).squareRoot()
        }

        #expect(residualRMSE(cleanSolution, clean) < 1e-12)
        #expect(residualRMSE(noisySolution, noisy) > 1e-4)
        #expect(CalibrationTestData.maximumCoefficientDifference(cleanSolution.matrix, known) < 1e-10)
    }

    // MARK: - Degenerate data

    @Test("Three samples are refused: an exact fit with no residual measures nothing")
    func tooFewSamples() {
        let samples = Self.samples(
            Array(Self.wellSpread.prefix(3)), through: CalibrationTestData.syntheticMatrix
        )
        #expect(throws: IRCalibrationFitError.insufficientSamples(found: 3, minimum: 4)) {
            try IRCalibrationMatrixSolver().solve(samples)
        }
    }

    @Test("An empty sample list is refused")
    func noSamples() {
        #expect(throws: IRCalibrationFitError.insufficientSamples(found: 0, minimum: 4)) {
            try IRCalibrationMatrixSolver().solve([])
        }
    }

    @Test("Identical samples are refused as ill-conditioned, not fitted")
    func duplicateSamples() {
        let repeated = Array(repeating: (0.4, 0.5, 0.6), count: 12)
        let samples = Self.samples(repeated, through: CalibrationTestData.syntheticMatrix)

        guard let error = Self.refusal(samples) else {
            Issue.record("Expected a refusal for identical samples")
            return
        }
        guard case .illConditioned(let determinant, let minimum) = error else {
            Issue.record("Expected .illConditioned, got \(error)")
            return
        }
        #expect(determinant < minimum)
    }

    @Test("Collinear responses are refused: they determine no unique transform")
    func collinearSamples() {
        // Every response is a multiple of one direction, so the camera
        // "channels" carry one degree of freedom between them.
        let collinear = (1...12).map { index -> (Double, Double, Double) in
            let t = Double(index) / 12
            return (0.2 * t, 0.5 * t, 0.9 * t)
        }
        let samples = Self.samples(collinear, through: CalibrationTestData.syntheticMatrix)

        guard let error = Self.refusal(samples) else {
            Issue.record("Expected a refusal for collinear samples")
            return
        }
        switch error {
        case .illConditioned, .singularNormalEquations:
            break
        default:
            Issue.record("Expected a conditioning refusal, got \(error)")
        }
    }

    /// Two independent directions is one short: the solver must say so rather
    /// than choose arbitrarily in the unconstrained third.
    @Test("Responses spanning only a plane are refused")
    func rankTwoSamples() {
        let planar = (0..<12).map { index -> (Double, Double, Double) in
            let a = Double(index % 4) / 4 + 0.1
            let b = Double(index / 4) / 3 + 0.1
            return (a, b, a + b)
        }
        let samples = Self.samples(planar, through: CalibrationTestData.syntheticMatrix)

        guard let error = Self.refusal(samples) else {
            Issue.record("Expected a refusal for rank-deficient samples")
            return
        }
        switch error {
        case .illConditioned, .singularNormalEquations:
            break
        default:
            Issue.record("Expected a conditioning refusal, got \(error)")
        }
    }

    @Test("A channel that is zero everywhere is named, not silently fitted")
    func zeroChannel() {
        let responses = (0..<12).map { index -> (Double, Double, Double) in
            (Double(index) / 12 + 0.1, 0, Double((index * 5) % 7) / 7 + 0.1)
        }
        let samples = Self.samples(responses, through: CalibrationTestData.syntheticMatrix)

        #expect(throws: IRCalibrationFitError.zeroChannelVariation(channel: "green")) {
            try IRCalibrationMatrixSolver().solve(samples)
        }
    }

    @Test(
        "A non-finite sample is refused, and the refusal names the patch and the field",
        arguments: [Double.nan, .infinity, -.infinity]
    )
    func nonFiniteSample(value: Double) {
        var samples = Self.samples(Self.wellSpread, through: CalibrationTestData.syntheticMatrix)
        samples[5] = IRCalibrationMatrixSolver.Sample(
            label: "06",
            input: SIMD3(samples[5].input.x, value, samples[5].input.z),
            output: samples[5].output
        )

        guard let error = Self.refusal(samples) else {
            Issue.record("Expected a refusal for a non-finite sample")
            return
        }
        guard case .nonFiniteSample(let patch, let field, _) = error else {
            Issue.record("Expected .nonFiniteSample, got \(error)")
            return
        }
        #expect(patch == "06")
        #expect(field == "camera green")
    }

    @Test("A non-finite reference value is refused too")
    func nonFiniteReference() {
        var samples = Self.samples(Self.wellSpread, through: CalibrationTestData.syntheticMatrix)
        samples[2] = IRCalibrationMatrixSolver.Sample(
            label: "03",
            input: samples[2].input,
            output: SIMD3(samples[2].output.x, samples[2].output.y, .nan)
        )

        guard let error = Self.refusal(samples) else {
            Issue.record("Expected a refusal for a non-finite reference value")
            return
        }
        guard case .nonFiniteSample(let patch, let field, _) = error else {
            Issue.record("Expected .nonFiniteSample, got \(error)")
            return
        }
        #expect(patch == "03")
        #expect(field == "reference blue")
    }

    // MARK: - No hidden regularisation

    /// The solver must not nudge an answer towards the identity, towards zero,
    /// or anywhere else. A fit whose off-diagonal coefficients are shrunk is
    /// not a measurement of the data it was given.
    @Test("Large legitimate coefficients are returned as they are, not shrunk")
    func noShrinkage() throws {
        let large = try RAWColorMatrix3x3(
            m00: 12, m01: -8, m02: 3,
            m10: -6, m11: 15, m12: -4,
            m20: 2, m21: -9, m22: 11
        )
        let solution = try IRCalibrationMatrixSolver()
            .solve(Self.samples(Self.wellSpread, through: large))
        #expect(CalibrationTestData.maximumCoefficientDifference(solution.matrix, large) < 1e-9)
    }

    static func refusal(
        _ samples: [IRCalibrationMatrixSolver.Sample]
    ) -> IRCalibrationFitError? {
        do {
            _ = try IRCalibrationMatrixSolver().solve(samples)
            return nil
        } catch {
            return error
        }
    }
}
