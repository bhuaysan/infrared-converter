import Foundation

/// Where a camera-to-working-space matrix came from, and therefore what it is
/// entitled to claim.
///
/// The matrix alone is nine numbers; the same nine numbers mean different
/// things depending on how they were arrived at. This is the half that says
/// which, and it is what `RAWWorkingColorProcessing` records so a rendered
/// image can be audited after the fact.
///
/// Exactly three origins exist in this milestone. Filter-profile and
/// IR-calibration cases are absent because filter profiles and IR calibrations
/// do not exist yet, and a provenance case that names a subsystem the project
/// has not built would be a claim about nothing.
public enum RAWCameraToWorkingColorTransformSource: Equatable, Sendable {
    /// The sensor's own R, G and B responses were assigned to the working
    /// space's R, G and B axes, deliberately and without a colour
    /// calibration. See
    /// `RAWCameraToWorkingColorTransform.sensorRGBIdentityFalseColor`.
    case sensorRGBIdentityFalseColor
    /// A matrix supplied deliberately by application logic, a caller, or — in
    /// future — a profile system. The project makes no claim about it beyond
    /// that its coefficients are finite.
    case explicit
    /// Derived from the file's own `rgbFromCamera` matrix, which is vendor or
    /// decoder data **calibrated for visible light**. Opt-in only, never a
    /// default and never a fallback; see
    /// `RAWCameraToWorkingColorTransform.visibleLightMetadata(from:)`.
    case visibleLightMetadataRGBFromCamera

    /// Whether this origin is a validated infrared colour calibration.
    ///
    /// `false` for every case, on purpose, and written as an exhaustive switch
    /// rather than a constant so that adding a source forces an author to
    /// answer the question rather than inherit an answer:
    ///
    /// - identity false colour is an axis assignment, not a measurement;
    /// - an explicit matrix is whatever its author made it, unvalidated here;
    /// - `rgbFromCamera` is calibrated for visible light, and an
    ///   infrared-converted camera is precisely the case it was not calibrated
    ///   for.
    public var isValidatedInfraredCalibration: Bool {
        switch self {
        case .sensorRGBIdentityFalseColor: return false
        case .explicit: return false
        case .visibleLightMetadataRGBFromCamera: return false
        }
    }

    /// A label for diagnostics and provenance reports, worded so a reader
    /// cannot mistake it for a claim of colour accuracy.
    public var diagnosticDescription: String {
        switch self {
        case .sensorRGBIdentityFalseColor:
            return "identity false-colour axis assignment (not a camera calibration)"
        case .explicit:
            return "explicit caller-supplied matrix (no calibration claim)"
        case .visibleLightMetadataRGBFromCamera:
            return """
                visible-light metadata transform from rgbFromCamera \
                (diagnostic only for an IR capture; not an IR calibration)
                """
        }
    }
}

/// A complete instruction for placing linear camera-native RGB into a defined
/// working colour space: which space, by which matrix, obtained how.
///
/// ```text
/// DemosaicedRAWRGBImage          linear camera-native sensor RGB
///         ↓
/// RAWCameraToWorkingColorTransform     ← this type: space + matrix + source
///         ↓
/// RAWWorkingColorConverter
///         ↓
/// WorkingColorRGBImage           extended linear sRGB coordinates
/// ```
///
/// ## Why the matrix is never handed round on its own
///
/// A bare matrix plus a separately supplied provenance label can be
/// mismatched: an identity matrix described as having come from metadata, or a
/// metadata-derived matrix described as a deliberate false-colour assignment.
/// The mistake is not hypothetical — it is the same one
/// `RAWWhiteBalanceEstimate` exists to prevent for gains.
///
/// So the pairing is enforced by the type, not by call-site discipline:
///
/// - all three properties are `let`, so no half can be replaced afterwards;
/// - the memberwise initialiser is module-internal, so no caller outside the
///   module can mint a transform whose matrix and source never met;
/// - the only ways in are the three factories below, each of which sets the
///   source that genuinely describes what it did.
///
/// ## There is no default
///
/// This type has no `.default`, no `.standard` and no zero-argument factory,
/// and `RAWWorkingColorConverter` has no defaulted transform parameter. Which
/// mapping is appropriate for an infrared capture is a decision the project
/// cannot make on the caller's behalf today, so it is made at the call site,
/// visibly.
public struct RAWCameraToWorkingColorTransform: Equatable, Sendable {
    /// The coordinate system the output values will be in.
    public let workingColorSpace: RAWWorkingColorSpace
    /// The 3×3 matrix, in the column-vector convention `RAWColorMatrix3x3`
    /// documents: rows are output channels, columns are input camera
    /// channels.
    public let matrix: RAWColorMatrix3x3
    /// How `matrix` was obtained, and therefore what it may be said to be.
    public let source: RAWCameraToWorkingColorTransformSource

    /// Module-internal, deliberately: see the type's note above. Only the
    /// factories below pair a matrix with the source that describes it.
    init(
        workingColorSpace: RAWWorkingColorSpace,
        matrix: RAWColorMatrix3x3,
        source: RAWCameraToWorkingColorTransformSource
    ) {
        self.workingColorSpace = workingColorSpace
        self.matrix = matrix
        self.source = source
    }

    // MARK: - Identity false colour

    /// Assigns the sensor's own responses to the working space's axes,
    /// unchanged:
    ///
    /// ```text
    /// camera sensor R  →  working-space R coordinate
    /// camera sensor G  →  working-space G coordinate
    /// camera sensor B  →  working-space B coordinate
    ///
    /// 1 0 0
    /// 0 1 0
    /// 0 0 1
    /// ```
    ///
    /// ## What this is
    ///
    /// A **deliberate false-colour axis assignment**. It is the
    /// assumption-minimal way to put an infrared capture's sensor responses
    /// into a defined RGB coordinate system: the coordinates become
    /// well-defined — extended linear sRGB, so later stages know what the
    /// numbers mean — while no claim is made about how those responses relate
    /// to any colour a person would perceive.
    ///
    /// ## What this is NOT
    ///
    /// It is **not** a camera calibration, not "correct colour", not "accurate
    /// sRGB", and not a claim that this sensor's red response is the sRGB red
    /// primary. For an infrared-modified camera no such claim is available at
    /// all: the filter, the conversion and the illumination together decide
    /// what each channel recorded, and none of that is characterised here.
    ///
    /// The distinction is visible in the source (`.sensorRGBIdentityFalseColor`),
    /// in this documentation, in the provenance the converter records, and in
    /// the wording of the fixture diagnostics.
    ///
    /// ## Numerically neutral
    ///
    /// `RAWWorkingColorConverter` gives this matrix a dedicated path that
    /// copies values through bit for bit — `-0.0`, negatives, values above `1`
    /// and very large finite values included. What changes is the semantic
    /// interpretation and the provenance, not a single number.
    public static let sensorRGBIdentityFalseColor = RAWCameraToWorkingColorTransform(
        workingColorSpace: .extendedLinearSRGB,
        matrix: .identity,
        source: .sensorRGBIdentityFalseColor
    )

    // MARK: - Explicit

    /// A matrix supplied deliberately by the caller.
    ///
    /// This is the route for application logic, experiments, and — later — a
    /// profile system that has decided which transform an infrared capture
    /// configuration deserves. Provenance records `.explicit`; the matrix
    /// itself is stored once, on the transform, and never duplicated inside
    /// the source.
    ///
    /// The working space is not a parameter because exactly one exists. When a
    /// second is implemented, this gains one.
    ///
    /// ### Where validation happens
    ///
    /// At `RAWColorMatrix3x3`'s initialiser, which refuses non-finite
    /// coefficients, so an unusable matrix cannot reach this factory in the
    /// first place — and this one therefore cannot fail. Negative, zero,
    /// greater-than-one and singular matrices are all accepted here, as they
    /// are there.
    public static func explicit(matrix: RAWColorMatrix3x3) -> RAWCameraToWorkingColorTransform {
        RAWCameraToWorkingColorTransform(
            workingColorSpace: .extendedLinearSRGB,
            matrix: matrix,
            source: .explicit
        )
    }

    // MARK: - Visible-light metadata adapter

    /// Derives a transform from the file's own `rgbFromCamera` matrix.
    ///
    /// ## Opt-in only. Read this before using it.
    ///
    /// `RAWMetadata.ColorMetadata.rgbFromCamera` is a Camera-RGB → sRGB matrix
    /// **calibrated for visible light** by the camera vendor or the decoder.
    /// An infrared-converted body photographing through a 720 nm filter is
    /// exactly the situation that calibration does not describe. Using it is
    /// therefore a diagnostic act — "what would the visible-light matrix do to
    /// this data?" — not a colour-managed one.
    ///
    /// Because of that, nothing selects this automatically. There is no
    /// converter entry point that discovers `rgbFromCamera`, no fallback that
    /// reaches for it when a profile is missing, and no default argument that
    /// lands on it. A caller has to name it, here, in one call.
    ///
    /// ## The 3×4 problem
    ///
    /// LibRaw's matrix has four columns, one per possible camera colour plane,
    /// while the application-owned demosaiced image has exactly three input
    /// channels — camera R, G and B. The fourth column is **never silently
    /// dropped**: it is representable only when it is exactly zero, in which
    /// case it contributes nothing and can be removed without changing the
    /// transform.
    ///
    /// ```text
    /// ⎡ r0 r1 r2 0 ⎤        ⎡ r0 r1 r2 ⎤
    /// ⎢ g0 g1 g2 0 ⎥   →    ⎢ g0 g1 g2 ⎥
    /// ⎣ b0 b1 b2 0 ⎦        ⎣ b0 b1 b2 ⎦
    /// ```
    ///
    /// Both `+0.0` and `-0.0` count as zero. There is deliberately **no
    /// epsilon**: a fourth coefficient of `0.01` is a real contribution from a
    /// fourth colour plane, and discarding it would change the transform while
    /// reporting success. Such a matrix is refused instead.
    ///
    /// ## What this adapter does not read
    ///
    /// Only `rgbFromCamera`. Not `cameraMultipliers`, not
    /// `daylightMultipliers` — white balance already happened, in the mosaic
    /// domain, and applying camera or daylight multipliers here would be a
    /// second white balance. Not `cameraFromXYZ`: nothing in this milestone
    /// inverts a matrix, and an XYZ round trip is a different decision that
    /// has not been made. When `rgbFromCamera` is absent this fails; it does
    /// not synthesise a substitute from the other fields.
    ///
    /// - Throws: `RAWProcessingError.missingVisibleLightCameraMatrix`,
    ///   `.malformedVisibleLightCameraMatrix` or
    ///   `.incompatibleVisibleLightCameraMatrix`.
    public static func visibleLightMetadata(
        from colorMetadata: RAWMetadata.ColorMetadata
    ) throws -> RAWCameraToWorkingColorTransform {
        guard let rows = colorMetadata.rgbFromCamera else {
            throw RAWProcessingError.missingVisibleLightCameraMatrix
        }
        guard rows.count == RAWColorMatrix3x3.dimension else {
            throw RAWProcessingError.malformedVisibleLightCameraMatrix(
                reason: """
                    rgbFromCamera has \(rows.count) rows; the visible-light adapter needs \
                    exactly \(RAWColorMatrix3x3.dimension) (one per output channel).
                    """
            )
        }
        // Read defensively: a malformed nested array must produce an error,
        // never an out-of-range subscript.
        for (index, row) in rows.enumerated() where row.count != expectedMetadataColumnCount {
            throw RAWProcessingError.malformedVisibleLightCameraMatrix(
                reason: """
                    rgbFromCamera row \(index) has \(row.count) coefficients; the visible-light \
                    adapter needs exactly \(expectedMetadataColumnCount).
                    """
            )
        }
        for (rowIndex, row) in rows.enumerated() {
            for (columnIndex, value) in row.enumerated() where !value.isFinite {
                throw RAWProcessingError.malformedVisibleLightCameraMatrix(
                    reason: """
                        rgbFromCamera coefficient at row \(rowIndex), column \(columnIndex) \
                        is \(value), which is not finite.
                        """
                )
            }
        }
        // The fourth column must contribute exactly nothing. `== 0` is true
        // for both +0.0 and -0.0, and true for nothing else.
        for (rowIndex, row) in rows.enumerated() {
            let fourth = row[expectedMetadataColumnCount - 1]
            guard fourth == 0 else {
                throw RAWProcessingError.incompatibleVisibleLightCameraMatrix(
                    row: rowIndex, value: fourth
                )
            }
        }

        let matrix = try RAWColorMatrix3x3(
            m00: Double(rows[0][0]), m01: Double(rows[0][1]), m02: Double(rows[0][2]),
            m10: Double(rows[1][0]), m11: Double(rows[1][1]), m12: Double(rows[1][2]),
            m20: Double(rows[2][0]), m21: Double(rows[2][1]), m22: Double(rows[2][2])
        )
        return RAWCameraToWorkingColorTransform(
            workingColorSpace: .extendedLinearSRGB,
            matrix: matrix,
            source: .visibleLightMetadataRGBFromCamera
        )
    }

    /// How many coefficients each `rgbFromCamera` row carries: four, one per
    /// possible camera colour plane, which is what LibRaw's `rgb_cam` is.
    private static let expectedMetadataColumnCount = 4
}
