import Testing
import Foundation
@testable import InfraredConverter

/// The three ways a camera-to-working transform can come into existence, and
/// what each one is allowed to claim.
@Suite("RAWCameraToWorkingColorTransform")
struct RAWCameraToWorkingColorTransformTests {

    /// Metadata carrying a well-formed 3×4 `rgbFromCamera` with an exactly
    /// zero fourth column, plus deliberately absurd white-balance multipliers
    /// that no code path may read.
    static func colorMetadata(
        rgbFromCamera: [[Float]]?,
        cameraFromXYZ: [[Float]]? = nil
    ) -> RAWMetadata.ColorMetadata {
        RAWMetadata.ColorMetadata(
            cameraMultipliers: [1000, 0.001, 12345, 7],
            daylightMultipliers: [-5, 99999, 0.0001, 3],
            rgbFromCamera: rgbFromCamera,
            cameraFromXYZ: cameraFromXYZ,
            asShotWhiteBalanceApplied: false
        )
    }

    static let wellFormedRows: [[Float]] = [
        [1.5, -0.25, 0.75, 0],
        [0.5, 2.0, -1.25, 0],
        [-0.125, 0.375, 3.0, 0],
    ]

    // MARK: - Identity false colour

    @Test("Identity false colour is the identity matrix in extended linear sRGB")
    func identityFalseColorIsIdentity() {
        let transform = RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor
        #expect(transform.matrix == .identity)
        #expect(transform.matrix.rows == [[1, 0, 0], [0, 1, 0], [0, 0, 1]])
        #expect(transform.workingColorSpace == .extendedLinearSRGB)
        #expect(transform.source == .sensorRGBIdentityFalseColor)
    }

    /// The naming and the provenance both have to keep saying this, because
    /// the whole point of the identity transform is that it is *not* a
    /// calibration — it is a deliberate false-colour axis assignment.
    @Test("No transform source claims to be an infrared calibration")
    func noSourceClaimsCalibration() throws {
        let sources: [RAWCameraToWorkingColorTransformSource] = [
            .sensorRGBIdentityFalseColor,
            .explicit,
            .visibleLightMetadataRGBFromCamera,
        ]
        for source in sources {
            #expect(!source.isValidatedInfraredCalibration)
        }
        #expect(
            RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor
                .source.diagnosticDescription.contains("not a camera calibration")
        )
        #expect(
            RAWCameraToWorkingColorTransformSource.visibleLightMetadataRGBFromCamera
                .diagnosticDescription.contains("not an IR calibration")
        )
    }

    // MARK: - Explicit

    @Test("An explicit matrix is carried literally, with explicit provenance")
    func explicitCarriesTheMatrix() throws {
        let matrix = try RAWColorMatrix3x3Tests.asymmetric()
        let transform = RAWCameraToWorkingColorTransform.explicit(matrix: matrix)
        #expect(transform.matrix == matrix)
        #expect(transform.source == .explicit)
        #expect(transform.workingColorSpace == .extendedLinearSRGB)

        // An explicitly supplied identity is still explicit provenance: the
        // matrix and the source are independent facts, and neither is
        // inferred from the other.
        let explicitIdentity = RAWCameraToWorkingColorTransform.explicit(matrix: .identity)
        #expect(explicitIdentity.matrix.isIdentity)
        #expect(explicitIdentity.source == .explicit)
        #expect(explicitIdentity != .sensorRGBIdentityFalseColor)
    }

    // MARK: - Visible-light metadata adapter

    /// The 3×4 → 3×3 derivation, exactly as documented: the first three
    /// columns, in order, not transposed.
    @Test("A representable 3x4 matrix derives the expected 3x3")
    func validMetadataMatrixDerivesTheExpected3x3() throws {
        let transform = try RAWCameraToWorkingColorTransform.visibleLightMetadata(
            from: Self.colorMetadata(rgbFromCamera: Self.wellFormedRows)
        )
        #expect(transform.source == .visibleLightMetadataRGBFromCamera)
        #expect(transform.workingColorSpace == .extendedLinearSRGB)
        #expect(transform.matrix.rows == [[1.5, -0.25, 0.75], [0.5, 2.0, -1.25], [-0.125, 0.375, 3.0]])

        // Not transposed: m01 is metadata row 0 column 1, not row 1 column 0.
        #expect(transform.matrix.m01 == -0.25)
        #expect(transform.matrix.m10 == 0.5)
    }

    @Test("A negative-zero fourth column counts as zero")
    func negativeZeroFourthColumnIsAccepted() throws {
        let rows: [[Float]] = [
            [1.5, -0.25, 0.75, -0.0],
            [0.5, 2.0, -1.25, -0.0],
            [-0.125, 0.375, 3.0, 0.0],
        ]
        let transform = try RAWCameraToWorkingColorTransform.visibleLightMetadata(
            from: Self.colorMetadata(rgbFromCamera: rows)
        )
        #expect(transform.matrix.m00 == 1.5)
        #expect(transform.matrix.m22 == 3.0)
    }

    @Test("A missing rgbFromCamera fails, and nothing is synthesised in its place")
    func missingMatrixFails() {
        // Only cameraFromXYZ present. It is not inverted, not adapted, and
        // not used as a fallback.
        let metadata = Self.colorMetadata(
            rgbFromCamera: nil,
            cameraFromXYZ: [[1, 0, 0], [0, 1, 0], [0, 0, 1], [0, 0, 0]]
        )
        #expect {
            _ = try RAWCameraToWorkingColorTransform.visibleLightMetadata(from: metadata)
        } throws: { error in
            guard case .missingVisibleLightCameraMatrix = error as? RAWProcessingError else {
                return false
            }
            return true
        }
    }

    @Test("A wrong row count fails")
    func wrongRowCountFails() {
        for rows in [
            [[1, 0, 0, 0], [0, 1, 0, 0]] as [[Float]],
            [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 0]] as [[Float]],
            [] as [[Float]],
        ] {
            #expect {
                _ = try RAWCameraToWorkingColorTransform.visibleLightMetadata(
                    from: Self.colorMetadata(rgbFromCamera: rows)
                )
            } throws: { error in
                guard case .malformedVisibleLightCameraMatrix =
                        error as? RAWProcessingError else { return false }
                return true
            }
        }
    }

    @Test("A row that is not four coefficients long fails, without indexing past it")
    func wrongColumnCountFails() {
        for rows in [
            [[1, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]] as [[Float]],
            [[1, 0, 0, 0], [0, 1, 0, 0, 0], [0, 0, 1, 0]] as [[Float]],
            [[1, 0, 0, 0], [0, 1, 0, 0], []] as [[Float]],
        ] {
            #expect {
                _ = try RAWCameraToWorkingColorTransform.visibleLightMetadata(
                    from: Self.colorMetadata(rgbFromCamera: rows)
                )
            } throws: { error in
                guard case .malformedVisibleLightCameraMatrix =
                        error as? RAWProcessingError else { return false }
                return true
            }
        }
    }

    @Test("A non-finite coefficient fails, wherever it is")
    func nonFiniteCoefficientFails() {
        let cases: [[[Float]]] = [
            [[.nan, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0]],
            [[1, 0, 0, 0], [0, .infinity, 0, 0], [0, 0, 1, 0]],
            [[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, -.infinity]],
        ]
        for rows in cases {
            #expect {
                _ = try RAWCameraToWorkingColorTransform.visibleLightMetadata(
                    from: Self.colorMetadata(rgbFromCamera: rows)
                )
            } throws: { error in
                guard case .malformedVisibleLightCameraMatrix =
                        error as? RAWProcessingError else { return false }
                return true
            }
        }
    }

    /// A clearly non-zero fourth coefficient, not a rounding-near-zero one:
    /// the contract is exact, and there is no epsilon to argue about.
    @Test("A non-zero fourth column is refused, never truncated")
    func nonZeroFourthColumnIsRefused() {
        let rows: [[Float]] = [
            [1.5, -0.25, 0.75, 0],
            [0.5, 2.0, -1.25, 0.25],
            [-0.125, 0.375, 3.0, 0],
        ]
        #expect {
            _ = try RAWCameraToWorkingColorTransform.visibleLightMetadata(
                from: Self.colorMetadata(rgbFromCamera: rows)
            )
        } throws: { error in
            guard case .incompatibleVisibleLightCameraMatrix(let row, let value) =
                    error as? RAWProcessingError else { return false }
            return row == 1 && value == 0.25
        }

        // Even a small but genuinely non-zero coefficient is refused. No
        // epsilon exists to let it through.
        let tiny: [[Float]] = [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, Float.leastNormalMagnitude],
        ]
        #expect {
            _ = try RAWCameraToWorkingColorTransform.visibleLightMetadata(
                from: Self.colorMetadata(rgbFromCamera: tiny)
            )
        } throws: { error in
            guard case .incompatibleVisibleLightCameraMatrix(let row, _) =
                    error as? RAWProcessingError else { return false }
            return row == 2
        }
    }

    @Test("The adapter reads rgbFromCamera and nothing else")
    func adapterReadsOnlyRGBFromCamera() throws {
        // Same rgbFromCamera, wildly different everything else.
        let first = RAWMetadata.ColorMetadata(
            cameraMultipliers: [1, 1, 1, 1],
            daylightMultipliers: [1, 1, 1, 1],
            rgbFromCamera: Self.wellFormedRows,
            cameraFromXYZ: nil,
            asShotWhiteBalanceApplied: false
        )
        let second = RAWMetadata.ColorMetadata(
            cameraMultipliers: [-1e9, 1e9, 0.5, 42],
            daylightMultipliers: [1e-9, 7, -3, 0],
            rgbFromCamera: Self.wellFormedRows,
            cameraFromXYZ: [[9, 9, 9], [9, 9, 9], [9, 9, 9], [9, 9, 9]],
            asShotWhiteBalanceApplied: true
        )
        let a = try RAWCameraToWorkingColorTransform.visibleLightMetadata(from: first)
        let b = try RAWCameraToWorkingColorTransform.visibleLightMetadata(from: second)
        #expect(a == b)
    }
}
