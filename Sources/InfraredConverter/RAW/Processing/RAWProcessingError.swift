import Foundation

/// Failures the application-owned RAW processing stages can report.
///
/// Deliberately separate from `RAWDecodingError`: that type describes the
/// decoder boundary (what LibRaw could or could not do with a file), while
/// these describe our own processing refusing to proceed on decoded input.
/// Sharing one type would blur the boundary the pipeline is built around, and
/// would make a processing bug read like a file problem in the UI.
///
/// Decoded metadata is treated as untrusted input here: a black or white
/// level that cannot produce a meaningful normalisation is reported, never
/// silently substituted with a plausible one.
public enum RAWProcessingError: Error, Equatable {
    /// The input mosaic's declared geometry does not add up (non-positive
    /// dimensions, a stride narrower than the width, a buffer too small, or
    /// arithmetic that would overflow).
    case invalidGeometry(reason: String)
    /// The sensor colour layout could not name a colour plane for a
    /// coordinate inside the mosaic, so the effective black level for that
    /// sample is unknown. Layouts with no per-pixel mosaic (Foveon, already
    /// full-colour files) and LibRaw's non-standard 16×16 CFA reach this.
    case missingColorPlane(row: Int, column: Int)
    /// The white level is not above the effective black level at this
    /// sample, so `white - black` is zero or negative and no normalisation
    /// denominator exists. Reported rather than worked around: substituting
    /// a different white level would silently change what every value in the
    /// image means.
    case invalidNormalizationRange(
        whiteLevel: UInt32,
        blackLevel: UInt32,
        row: Int,
        column: Int,
        colorPlane: Int
    )
    /// A white-balance gain is not a usable multiplier: it is zero, negative,
    /// NaN, or infinite. There is deliberately no upper bound — infrared
    /// white balance legitimately needs extreme multipliers — so only these
    /// four kinds of value are refused.
    ///
    /// Note that `==` on this case is `false` when `value` is NaN, since
    /// `Float` comparison says so; match the case rather than comparing
    /// whole errors when the offending value may be NaN.
    case invalidWhiteBalanceGain(colorPlane: Int, value: Float)
    /// The sensor colour layout named a colour plane the supplied gains have
    /// no slot for, so this sample has no defined multiplier. Reported rather
    /// than folded onto an existing plane: reducing the index modulo the slot
    /// count would silently apply the wrong colour's gain.
    case missingWhiteBalanceGain(row: Int, column: Int, colorPlane: Int)
    /// An input value was NaN or infinite. The normalisation stage cannot
    /// produce either, so this means a hand-constructed or otherwise
    /// unvalidated mosaic reached a processing stage; it is reported rather
    /// than multiplied and propagated silently.
    case nonFiniteInputValue(row: Int, column: Int, value: Float)
    /// A finite input multiplied by a finite gain overflowed `Float32`. The
    /// result is reported rather than clamped to
    /// `Float.greatestFiniteMagnitude` or otherwise substituted: an image
    /// containing a silently invented value is worse than a failed stage.
    case nonFiniteWhiteBalanceResult(
        row: Int,
        column: Int,
        colorPlane: Int,
        input: Float,
        gain: Float
    )
    /// A requested active-area region is not a usable selection: a negative
    /// origin, a non-positive width or height, a far edge that overflows
    /// `Int`, or an extent past the mosaic's edge. Reported rather than
    /// cropped — silently shrinking a selection would change which samples a
    /// measurement covers without saying so.
    case invalidActiveAreaRegion(reason: String)
    /// Per-CFA-plane estimation is not meaningful for this sensor colour
    /// layout, so no set of colour planes could be discovered. Foveon,
    /// already-full-colour files, layouts the decoder did not describe,
    /// LibRaw's non-standard 16×16 Bayer code, and malformed X-Trans tables
    /// all reach this.
    case unsupportedSensorLayoutForEstimation(
        pattern: RAWMetadata.SensorColorLayout.Pattern,
        reason: String
    )
    /// The sensor colour layout names a colour-plane index outside
    /// `0..<RAWWhiteBalanceGains.planeCount`, which the four-slot gain model
    /// cannot represent. Reported rather than reduced modulo the slot count
    /// or modulo `colorCount`: either would silently estimate one colour's
    /// gain from another colour's samples.
    case unsupportedColorPlaneIndex(colorPlane: Int)
    /// A colour plane that genuinely exists in the sensor layout received no
    /// samples at all from the requested patch, so there is nothing to
    /// estimate its gain from.
    ///
    /// Deliberately distinct from a plane the layout never produces: an
    /// unused plane gets an identity gain, while this one is a patch too
    /// small or too badly placed to cover the CFA. Inventing a gain here
    /// would be fabricating a measurement.
    case insufficientPatchSamples(colorPlane: Int, region: RAWActiveAreaRegion)
    /// A measured colour plane's arithmetic mean cannot scale to a target:
    /// it is zero, negative, NaN or infinite. Dividing by it would produce an
    /// infinite, negative or undefined gain, none of which is white balance.
    ///
    /// Note that `==` on this case is `false` when `mean` is NaN, since
    /// `Double` comparison says so; match the case rather than comparing
    /// whole errors when the offending value may be NaN.
    case invalidPlaneMean(colorPlane: Int, mean: Double)
    /// `target / planeMean` is not representable as a finite, strictly
    /// positive `Float`, so the plane has no usable gain. Reported rather
    /// than clamped to `Float.greatestFiniteMagnitude`, and there is
    /// deliberately no arbitrary maximum gain: a very small but positive mean
    /// may legitimately produce a very large gain, as long as it stays
    /// finite.
    case nonFiniteEstimatedGain(colorPlane: Int, targetMean: Double, planeMean: Double)
    /// The selected demosaicing algorithm cannot run on this sensor colour
    /// layout.
    ///
    /// `algorithm` is carried so the failure says *which* algorithm refused
    /// the layout. That distinction matters most for X-Trans: the layout is
    /// recognised and fully described, and it is the Bayer-only algorithm
    /// that cannot interpolate it — not the project that fails to understand
    /// the sensor. Reported rather than worked around: there is no silent
    /// fallback to another algorithm, no treating X-Trans as Bayer, no
    /// demosaicing a top-left 2×2 subset, and no routing back through LibRaw.
    ///
    /// Also raised for a CFA whose packed cell does not repeat every two
    /// rows, for a colour plane that `colorDescription` cannot name, for a
    /// filter colour that is not R, G or B, and for a 2×2 cell that is not
    /// one red, one blue and two greens.
    case unsupportedSensorLayoutForDemosaicing(
        pattern: RAWMetadata.SensorColorLayout.Pattern,
        algorithm: RAWDemosaicAlgorithm,
        reason: String
    )
    /// A pixel needs a channel reconstructed and has no in-bounds neighbour
    /// of that colour to reconstruct it from.
    ///
    /// Reachable only for pathologically small geometry — a 1×1 mosaic, or a
    /// single row or column — since any 2×2 Bayer cell supplies every colour
    /// to every pixel in it. Reported rather than filled with zero: an
    /// invented value is indistinguishable from a measured one once it is in
    /// the buffer.
    case missingDemosaicNeighbors(row: Int, column: Int, channel: RAWLinearRGBChannel)
    /// An interpolated channel came out NaN or infinite despite finite
    /// contributors. Reported rather than clamped, for the same reason
    /// `nonFiniteWhiteBalanceResult` is: an image carrying a silently
    /// invented value is worse than a failed stage.
    ///
    /// Unreachable for the documented arithmetic — at most four finite
    /// `Float32` values are summed in `Double` and divided by their count,
    /// which cannot overflow `Float32` — and checked anyway, because the
    /// alternative to checking is trusting.
    case nonFiniteDemosaicResult(row: Int, column: Int, channel: RAWLinearRGBChannel)
    /// A `RAWColorMatrix3x3` coefficient is NaN or infinite, so the matrix
    /// cannot describe any transform. Reported at construction, before a
    /// matrix can reach a pixel. Zero, negative, greater-than-one and singular
    /// coefficients are all legitimate and are not reported here; see
    /// `RAWColorMatrix3x3`.
    ///
    /// Deliberately named for the primitive rather than for a stage: the same
    /// matrix type carries the camera-to-working transform and the creative
    /// infrared channel mix, and its validation belongs to neither.
    ///
    /// Note that `==` on this case is `false` when `value` is NaN, since
    /// `Double` comparison says so; match the case rather than comparing
    /// whole errors when the offending value may be NaN.
    case invalidColorMatrix3x3(row: Int, column: Int, value: Double)
    /// The visible-light metadata transform was requested for a file whose
    /// metadata carries no `rgbFromCamera` matrix. Reported rather than
    /// substituted: there is no default camera matrix in this project, and
    /// synthesising one from `cameraFromXYZ` or from the white-balance
    /// multipliers would be inventing a calibration.
    case missingVisibleLightCameraMatrix
    /// The file's `rgbFromCamera` is structurally unusable: the wrong number
    /// of rows, a row with the wrong number of coefficients, or a coefficient
    /// that is not finite. Reported rather than read past its bounds or
    /// padded into shape.
    case malformedVisibleLightCameraMatrix(reason: String)
    /// The file's `rgbFromCamera` is well-formed but has a non-zero fourth
    /// column, so it describes a contribution from a fourth camera colour
    /// plane that the application-owned three-channel camera-native image
    /// cannot supply.
    ///
    /// Reported rather than truncated: dropping a non-zero fourth coefficient
    /// would silently change the transform and still call the result a
    /// metadata transform. There is deliberately no epsilon — the fourth
    /// channel contributes exactly zero, or the matrix is not representable
    /// here.
    case incompatibleVisibleLightCameraMatrix(row: Int, value: Float)
    /// A camera-native RGB input value was NaN or infinite. The demosaicing
    /// stage cannot produce either, so this means a hand-constructed or
    /// otherwise unvalidated image reached the working-colour stage; it is
    /// reported rather than multiplied and propagated silently.
    case nonFiniteWorkingColorInput(
        row: Int,
        column: Int,
        channel: RAWLinearRGBChannel,
        value: Float
    )
    /// A camera-to-working dot product did not produce a finite `Float32`:
    /// either the `Double` accumulation itself was not finite, or a finite
    /// `Double` result overflowed on the single narrowing to `Float`.
    ///
    /// Reported rather than clamped to `Float.greatestFiniteMagnitude`, for
    /// the same reason `nonFiniteWhiteBalanceResult` is: an image carrying a
    /// silently invented value is worse than a failed stage.
    case nonFiniteWorkingColorResult(row: Int, column: Int, channel: RAWLinearRGBChannel)
}

extension RAWProcessingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidGeometry:
            return "The RAW mosaic's dimensions are inconsistent and cannot be processed."
        case .missingColorPlane:
            return "This sensor colour layout does not describe a colour plane for every sample."
        case .invalidNormalizationRange:
            return "The file's black and white levels do not describe a usable range."
        case .invalidWhiteBalanceGain:
            return "A white-balance gain is not a usable multiplier."
        case .missingWhiteBalanceGain:
            return "The white-balance gains do not cover every colour plane in this sensor layout."
        case .nonFiniteInputValue:
            return "The image data contains a value that is not a finite number."
        case .nonFiniteWhiteBalanceResult:
            return "These white-balance gains produce values too large to represent."
        case .invalidActiveAreaRegion:
            return "The selected image region is not a usable selection."
        case .unsupportedSensorLayoutForEstimation:
            return "White balance cannot be estimated from this sensor's colour layout."
        case .unsupportedColorPlaneIndex:
            return "This sensor layout names a colour plane the white-balance model cannot hold."
        case .insufficientPatchSamples:
            return "The selected region does not cover every colour of the sensor's filter array."
        case .invalidPlaneMean:
            return "The selected region is not bright enough in every colour to balance from."
        case .nonFiniteEstimatedGain:
            return "The selected region needs a white-balance gain too large to represent."
        case .unsupportedSensorLayoutForDemosaicing:
            return "This sensor's colour layout cannot be demosaiced by the selected algorithm."
        case .missingDemosaicNeighbors:
            return "The image is too small for every pixel to receive all three colours."
        case .nonFiniteDemosaicResult:
            return "Demosaicing produced a value that is not a finite number."
        case .invalidColorMatrix3x3:
            return "A colour-matrix coefficient is not a finite number."
        case .missingVisibleLightCameraMatrix:
            return "This file carries no visible-light camera colour matrix."
        case .malformedVisibleLightCameraMatrix:
            return "This file's visible-light camera colour matrix is not the expected shape."
        case .incompatibleVisibleLightCameraMatrix:
            return """
                This file's visible-light camera colour matrix uses a fourth colour channel \
                that the demosaiced image does not have.
                """
        case .nonFiniteWorkingColorInput:
            return "The image data contains a value that is not a finite number."
        case .nonFiniteWorkingColorResult:
            return "This colour transform produces values too large to represent."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidGeometry(let reason):
            return reason
        case .missingColorPlane(let row, let column):
            return "No colour plane at row \(row), column \(column)."
        case .invalidNormalizationRange(let white, let black, let row, let column, let plane):
            return """
                White level \(white) is not above the effective black level \(black) \
                at row \(row), column \(column), colour plane \(plane).
                """
        case .invalidWhiteBalanceGain(let plane, let value):
            return """
                Gain \(value) for colour plane \(plane) is not finite and greater than zero.
                """
        case .missingWhiteBalanceGain(let row, let column, let plane):
            return """
                No gain for colour plane \(plane), sampled at row \(row), column \(column).
                """
        case .nonFiniteInputValue(let row, let column, let value):
            return "Value \(value) at row \(row), column \(column) is not finite."
        case .nonFiniteWhiteBalanceResult(let row, let column, let plane, let input, let gain):
            return """
                \(input) x \(gain) overflows Float32 at row \(row), column \(column), \
                colour plane \(plane).
                """
        case .invalidActiveAreaRegion(let reason):
            return reason
        case .unsupportedSensorLayoutForEstimation(let pattern, let reason):
            return "Sensor layout \(pattern): \(reason)"
        case .unsupportedColorPlaneIndex(let plane):
            return """
                Colour plane \(plane) is outside 0..<\(RAWWhiteBalanceGains.planeCount), \
                which the gain model cannot address.
                """
        case .insufficientPatchSamples(let plane, let region):
            return """
                Colour plane \(plane) exists in this sensor layout but received no samples \
                from the region at row \(region.originRow), column \(region.originColumn), \
                size \(region.width)x\(region.height).
                """
        case .invalidPlaneMean(let plane, let mean):
            return """
                Colour plane \(plane) has arithmetic mean \(mean), which is not finite and \
                greater than zero.
                """
        case .nonFiniteEstimatedGain(let plane, let target, let mean):
            return """
                Target mean \(target) divided by colour plane \(plane)'s mean \(mean) is not \
                a finite positive Float32.
                """
        case .unsupportedSensorLayoutForDemosaicing(let pattern, let algorithm, let reason):
            return "Sensor layout \(pattern), algorithm \(algorithm): \(reason)"
        case .missingDemosaicNeighbors(let row, let column, let channel):
            return """
                The pixel at row \(row), column \(column) has no in-bounds neighbouring \
                sample of colour \(channel) to interpolate its \(channel) channel from.
                """
        case .nonFiniteDemosaicResult(let row, let column, let channel):
            return """
                The interpolated \(channel) channel at row \(row), column \(column) is not \
                finite.
                """
        case .invalidColorMatrix3x3(let row, let column, let value):
            return """
                Colour-matrix coefficient \(value) at row \(row), column \(column) is not \
                finite.
                """
        case .missingVisibleLightCameraMatrix:
            return """
                The metadata carries no rgbFromCamera matrix, and this project has no default \
                camera matrix to fall back to.
                """
        case .malformedVisibleLightCameraMatrix(let reason):
            return reason
        case .incompatibleVisibleLightCameraMatrix(let row, let value):
            return """
                rgbFromCamera row \(row) has fourth-column coefficient \(value), which is not \
                zero. The camera-native RGB image has three input channels, so dropping that \
                coefficient would change the transform.
                """
        case .nonFiniteWorkingColorInput(let row, let column, let channel, let value):
            return """
                Camera-native \(channel) value \(value) at row \(row), column \(column) is \
                not finite.
                """
        case .nonFiniteWorkingColorResult(let row, let column, let channel):
            return """
                The working-space \(channel) coordinate at row \(row), column \(column) is \
                not a finite Float32.
                """
        }
    }
}
