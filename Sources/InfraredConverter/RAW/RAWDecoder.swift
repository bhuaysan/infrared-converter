import Foundation

/// The application-facing RAW decoding boundary.
///
/// Everything above this protocol works in terms of `RAWMetadata`, `RAWImage`
/// and `RAWDecoderProcessing`; nothing above it knows that LibRaw exists.
///
/// The protocol is deliberately narrow. It covers exactly what the current
/// milestone needs: read metadata, and decode a file into an interleaved
/// high-bit-depth buffer whose provenance is fully described.
public protocol RAWDecoder: Sendable {
    /// Reads metadata without decoding pixel data.
    func readMetadata(at url: URL) throws -> RAWMetadata

    /// Decodes a RAW file into pixels plus the metadata and an explicit
    /// description of what the decoder did to produce them.
    func decode(at url: URL, options: RAWDecodeOptions) throws -> DecodedRAW
}

extension RAWDecoder {
    public func decode(at url: URL) throws -> DecodedRAW {
        try decode(at: url, options: .init())
    }
}

/// The result of a successful decode.
public struct DecodedRAW: Sendable {
    public let url: URL
    public let metadata: RAWMetadata
    public let image: RAWImage
    /// What the decoder applied, so later pipeline stages do not repeat it.
    public let processing: RAWDecoderProcessing

    public init(
        url: URL,
        metadata: RAWMetadata,
        image: RAWImage,
        processing: RAWDecoderProcessing
    ) {
        self.url = url
        self.metadata = metadata
        self.image = image
        self.processing = processing
    }
}

/// Caller-selectable decoding behaviour.
///
/// The defaults are chosen so the decoder makes no irreversible colour decision.
/// Anything that would prejudge infrared rendering is off.
public struct RAWDecodeOptions: Equatable, Sendable {
    /// Demosaicing algorithm. The decoder must interpolate to hand back an RGB
    /// buffer; a future milestone will consume the mosaic directly instead.
    public enum Demosaic: Int, Equatable, Sendable {
        case bilinear = 0
        case vng = 1
        case ppg = 2
        case ahd = 3
    }

    /// Whether the decoder should orient the image using the camera's flip.
    public var applyCameraOrientation: Bool
    /// Half-resolution decode: one output pixel per CFA cell, no interpolation.
    /// Useful for fast previews; it is not a different pipeline.
    public var halfSize: Bool
    public var demosaic: Demosaic

    public init(
        applyCameraOrientation: Bool = true,
        halfSize: Bool = false,
        demosaic: Demosaic = .ahd
    ) {
        self.applyCameraOrientation = applyCameraOrientation
        self.halfSize = halfSize
        self.demosaic = demosaic
    }
}

/// An explicit record of which pipeline stages the decoder already performed.
///
/// This exists so application stages are never applied twice because the
/// decoder silently did them first. Every field is a statement of fact about
/// the buffer in the accompanying `RAWImage`.
public struct RAWDecoderProcessing: Equatable, Sendable {
    /// Identifies the decoder and its version, e.g. `"LibRaw 0.22.2-Release"`.
    /// Produced by `LibRawDecoder` from the vendored library, never hardcoded.
    public var decoderIdentifier: String
    /// Black level subtracted from the samples.
    public var blackLevelSubtracted: Bool
    /// Samples linearly rescaled so the saturation level maps to full range.
    public var normalizedToFullRange: Bool
    /// White-balance multipliers the decoder applied, per channel.
    /// All-ones means the decoder made no white-balance decision.
    public var appliedWhiteBalanceMultipliers: [Float]
    /// Whether `appliedWhiteBalanceMultipliers` are all 1.0.
    public var whiteBalanceIsUnity: Bool { appliedWhiteBalanceMultipliers.allSatisfy { $0 == 1.0 } }
    /// The demosaicing algorithm the caller requested, if any.
    /// `nil` in half-size mode, where no interpolation is requested at all.
    public var requestedDemosaic: RAWDecodeOptions.Demosaic?
    /// The demosaicing algorithm that actually ran, if any.
    ///
    /// May differ from `requestedDemosaic`: LibRaw can silently substitute AHD
    /// when the requested algorithm is unavailable for a given file (see
    /// `Warning.fallbackToAHDDemosaic`). `nil` when no demosaicing happened
    /// (half-size mode).
    public var appliedDemosaic: RAWDecodeOptions.Demosaic?
    /// Whether a camera/vendor colour matrix was applied to the samples.
    public var cameraColorMatrixApplied: Bool
    /// Whether an automatic brightness/exposure scaling was applied.
    public var autoBrightnessApplied: Bool
    /// Whether the decoder reconstructed clipped highlights.
    public var highlightReconstructionApplied: Bool
    /// Whether any noise reduction or sharpening was applied.
    public var noiseReductionApplied: Bool

    /// Whether the caller asked the decoder to honour the camera's recorded
    /// orientation (`RAWDecodeOptions.applyCameraOrientation`).
    ///
    /// This is a statement about the *request*, not the outcome: a camera
    /// whose recorded orientation is already "normal" (`flip == 0`) needs no
    /// geometric transform even when handling was requested. Use
    /// `orientationTransformApplied` for whether a transform actually
    /// happened.
    public var orientationHandlingRequested: Bool
    /// The orientation flip actually reflected in the returned buffer's
    /// geometry, using the same convention as `RAWMetadata.Geometry.flip`
    /// (`0` means no transform). Always `0` when
    /// `orientationHandlingRequested` is `false`; otherwise this is the
    /// camera's own recorded flip, which may itself be `0`.
    public var appliedOrientationFlip: Int
    /// True only when a geometric orientation transform actually changed the
    /// buffer: orientation handling was requested *and* the camera's
    /// recorded flip was non-zero.
    public var orientationTransformApplied: Bool { appliedOrientationFlip != 0 }

    /// Application-level warnings the decoder raised that affect
    /// interpretation of the result, translated from LibRaw's
    /// `process_warnings` bitfield. See `Warning` for which LibRaw flags this
    /// build can reliably interpret.
    public var warnings: [Warning]
    /// The complete, uninterpreted `process_warnings` bitfield LibRaw
    /// reported, including bits `warnings` could not map to an
    /// application-level meaning. Diagnostic/logging use only — never surface
    /// this bitfield in UI.
    public var rawWarningBits: UInt32

    public init(
        decoderIdentifier: String,
        blackLevelSubtracted: Bool,
        normalizedToFullRange: Bool,
        appliedWhiteBalanceMultipliers: [Float],
        requestedDemosaic: RAWDecodeOptions.Demosaic?,
        appliedDemosaic: RAWDecodeOptions.Demosaic?,
        cameraColorMatrixApplied: Bool,
        autoBrightnessApplied: Bool,
        highlightReconstructionApplied: Bool,
        noiseReductionApplied: Bool,
        orientationHandlingRequested: Bool,
        appliedOrientationFlip: Int,
        warnings: [Warning] = [],
        rawWarningBits: UInt32 = 0
    ) {
        self.decoderIdentifier = decoderIdentifier
        self.blackLevelSubtracted = blackLevelSubtracted
        self.normalizedToFullRange = normalizedToFullRange
        self.appliedWhiteBalanceMultipliers = appliedWhiteBalanceMultipliers
        self.requestedDemosaic = requestedDemosaic
        self.appliedDemosaic = appliedDemosaic
        self.cameraColorMatrixApplied = cameraColorMatrixApplied
        self.autoBrightnessApplied = autoBrightnessApplied
        self.highlightReconstructionApplied = highlightReconstructionApplied
        self.noiseReductionApplied = noiseReductionApplied
        self.orientationHandlingRequested = orientationHandlingRequested
        self.appliedOrientationFlip = appliedOrientationFlip
        self.warnings = warnings
        self.rawWarningBits = rawWarningBits
    }
}

extension RAWDecoderProcessing {
    /// Application-level interpretation of LibRaw's `process_warnings`
    /// bitfield (`enum LibRaw_warnings`,
    /// `Sources/CLibRawVendor/libraw/libraw_const.h`).
    ///
    /// Only flags this build can actually raise, given the LibRaw features we
    /// compile in and the options this decoder always passes, are
    /// represented here. See `decode(rawWarningBits:)` for the full mapping
    /// decision, including which flags were deliberately left unmapped and
    /// why.
    public enum Warning: Hashable, Sendable {
        /// `LIBRAW_WARN_BAD_CAMERA_WB`: the file's as-shot white balance could
        /// not be read; `RAWMetadata.ColorMetadata.cameraMultipliers` is
        /// unreliable or absent.
        case badCameraWhiteBalance
        /// `LIBRAW_WARN_NO_JPEGLIB`: this format needs JPEG decompression
        /// (Kodak JPEG-compressed RAW, or lossy-compressed DNG) but this
        /// build has no JPEG library (`NO_JPEG` is defined); the file could
        /// not be decoded as a result.
        case jpegDecodingUnavailable
        /// `LIBRAW_WARN_FALLBACK_TO_AHD`: the requested demosaic algorithm
        /// was unavailable for this file, and LibRaw substituted AHD.
        /// `RAWDecoderProcessing.appliedDemosaic` reflects this fallback
        /// (`.ahd`); `RAWDecoderProcessing.requestedDemosaic` still reflects
        /// what the caller originally asked for.
        case fallbackToAHDDemosaic
        /// `LIBRAW_WARN_PARSEFUJI_PROCESSED`: Fujifilm-specific parsing (e.g.
        /// Super CCD / EXR sensor geometry) was applied while interpreting
        /// this file.
        case fujiProcessingApplied
        /// `LIBRAW_WARN_VENDOR_CROP_SUGGESTED`: the vendor's own metadata
        /// suggests a crop different from the active area LibRaw reports in
        /// `RAWMetadata.Geometry`.
        case vendorCropSuggested

        var libRawBit: UInt32 {
            switch self {
            case .badCameraWhiteBalance: return 1 << 2
            case .jpegDecodingUnavailable: return 1 << 4
            case .fallbackToAHDDemosaic: return 1 << 15
            case .fujiProcessingApplied: return 1 << 16
            case .vendorCropSuggested: return 1 << 25
            }
        }

        /// A short, human-readable description suitable for logging.
        public var logDescription: String {
            switch self {
            case .badCameraWhiteBalance:
                return "LibRaw could not read the camera's as-shot white balance"
            case .jpegDecodingUnavailable:
                return "This file needs JPEG decompression, unavailable in this build"
            case .fallbackToAHDDemosaic:
                return "LibRaw fell back to AHD demosaicing"
            case .fujiProcessingApplied:
                return "Fujifilm-specific sensor parsing was applied"
            case .vendorCropSuggested:
                return "The camera vendor suggests a different crop than reported"
            }
        }

        /// Every warning this build maps, in a stable order, for decoding
        /// `process_warnings` bitfields.
        static let allMapped: [Warning] = [
            .badCameraWhiteBalance, .jpegDecodingUnavailable, .fallbackToAHDDemosaic,
            .fujiProcessingApplied, .vendorCropSuggested
        ]
    }

    /// Translates LibRaw's raw `process_warnings` bitfield into the mapped
    /// `[Warning]` this build can interpret.
    ///
    /// Deliberately unmapped, with the reason recorded here rather than
    /// guessed at:
    /// - `LIBRAW_WARN_NO_METADATA`: declared by this LibRaw version's header
    ///   but never raised by any source file it compiles — there is no
    ///   observable behaviour to map.
    /// - `LIBRAW_WARN_NO_EMBEDDED_PROFILE`, `LIBRAW_WARN_NO_INPUT_PROFILE`,
    ///   `LIBRAW_WARN_BAD_OUTPUT_PROFILE`: only raised from
    ///   `LibRaw::apply_profile`, which compiles to nothing because this
    ///   project defines no `USE_LCMS`/`USE_LCMS2` (LibRaw's own headers then
    ///   define `NO_LCMS`); this decoder also never calls that API.
    /// - `LIBRAW_WARN_NO_BADPIXELMAP`, `LIBRAW_WARN_BAD_DARKFRAME_FILE`,
    ///   `LIBRAW_WARN_BAD_DARKFRAME_DIM`: only raised when a bad-pixel map or
    ///   dark-frame path is supplied; this decoder always passes `nullptr`
    ///   for both (see `ir_libraw_apply_options`), so these are unreachable.
    /// - `LIBRAW_WARN_RAWSPEED_*`, `LIBRAW_WARN_RAWSPEED3_*`: guarded by
    ///   `USE_RAWSPEED`/`USE_RAWSPEED3`, which this project does not define.
    /// - `LIBRAW_WARN_DNGSDK_PROCESSED`, `LIBRAW_WARN_DNG_IMAGES_REORDERED`,
    ///   `LIBRAW_WARN_DNG_STAGE2_APPLIED`, `LIBRAW_WARN_DNG_STAGE3_APPLIED`,
    ///   `LIBRAW_WARN_DNG_NOT_PROCESSED`, `LIBRAW_WARN_DNG_NOT_PARSED`: only
    ///   raised from `Sources/CLibRawVendor/src/integration/dngsdk_glue.cpp`,
    ///   which `Package.swift` excludes from the build entirely.
    ///
    /// All bits, mapped or not, remain available uninterpreted in
    /// `rawWarningBits` for logging.
    static func decode(rawWarningBits: UInt32) -> [Warning] {
        Warning.allMapped.filter { rawWarningBits & $0.libRawBit != 0 }
    }

    /// Determines the demosaic algorithm that actually ran, from what was
    /// requested, whether this was a half-size decode, and the decoded
    /// warnings.
    ///
    /// - Half-size decode performs no interpolation at all: `nil`.
    /// - Otherwise, if LibRaw reported `Warning.fallbackToAHDDemosaic`, it
    ///   silently substituted AHD regardless of what was requested.
    /// - Otherwise, the requested algorithm ran as asked.
    static func appliedDemosaic(
        requested: RAWDecodeOptions.Demosaic?,
        halfSize: Bool,
        warnings: [Warning]
    ) -> RAWDecodeOptions.Demosaic? {
        if halfSize { return nil }
        if warnings.contains(.fallbackToAHDDemosaic) { return .ahd }
        return requested
    }
}

/// Failures the RAW boundary can report.
///
/// Underlying decoder diagnostics are preserved in `DecoderDiagnostic` so they
/// remain available for logging without the UI ever seeing an integer code.
public enum RAWDecodingError: Error, Equatable {
    /// Diagnostic detail from the underlying decoder.
    ///
    /// `code` is an opaque LibRaw integer that means nothing to a user; it
    /// must never reach UI. It stays available on this type for logging.
    /// `description` (and every other user-facing surface derived from this
    /// type) deliberately omits it — use `logDescription` when the code is
    /// wanted.
    public struct DecoderDiagnostic: Equatable, Sendable, CustomStringConvertible {
        public let code: Int32
        public let message: String

        public init(code: Int32, message: String) {
            self.code = code
            self.message = message
        }

        /// Safe to show a user: the decoder's message, with no internal code.
        public var userFacingSummary: String { message }

        /// `CustomStringConvertible` conformance mirrors `userFacingSummary`
        /// so that reaching for the general-purpose string form (e.g. string
        /// interpolation, `"\(diagnostic)"`) can never reintroduce the code
        /// into user-facing text.
        public var description: String { userFacingSummary }

        /// Full diagnostic detail, including the underlying decoder's
        /// integer code. For logging only — never display this in UI.
        public var logDescription: String { "\(message) (code \(code))" }
    }

    case fileNotFound(URL)
    case fileNotReadable(URL)
    case unsupportedFormat(URL, DecoderDiagnostic)
    case openFailed(URL, DecoderDiagnostic)
    case unpackFailed(URL, DecoderDiagnostic)
    case processingFailed(URL, DecoderDiagnostic)
    case imageExtractionFailed(URL, DecoderDiagnostic)
    /// The decoder returned a buffer whose geometry does not add up.
    case invalidDecodedImage(URL, reason: String)
    case outOfMemory(URL)
    /// The decoder could not be created at all.
    case decoderUnavailable
}

extension RAWDecodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "The file “\(url.lastPathComponent)” could not be found."
        case .fileNotReadable(let url):
            return "The file “\(url.lastPathComponent)” could not be read."
        case .unsupportedFormat(let url, _):
            return "“\(url.lastPathComponent)” is not a RAW format this decoder supports."
        case .openFailed(let url, _):
            return "“\(url.lastPathComponent)” could not be opened as a RAW file."
        case .unpackFailed(let url, _):
            return "The RAW data in “\(url.lastPathComponent)” could not be unpacked."
        case .processingFailed(let url, _):
            return "The RAW data in “\(url.lastPathComponent)” could not be decoded."
        case .imageExtractionFailed(let url, _):
            return "No image could be extracted from “\(url.lastPathComponent)”."
        case .invalidDecodedImage(let url, let reason):
            return "The decoded image from “\(url.lastPathComponent)” is invalid: \(reason)"
        case .outOfMemory(let url):
            return "There was not enough memory to decode “\(url.lastPathComponent)”."
        case .decoderUnavailable:
            return "The RAW decoder could not be initialised."
        }
    }

    public var failureReason: String? {
        diagnostic?.userFacingSummary
    }

    /// The underlying decoder diagnostic, when the failure came from the decoder.
    public var diagnostic: DecoderDiagnostic? {
        switch self {
        case .unsupportedFormat(_, let d),
             .openFailed(_, let d),
             .unpackFailed(_, let d),
             .processingFailed(_, let d),
             .imageExtractionFailed(_, let d):
            return d
        case .fileNotFound, .fileNotReadable, .invalidDecodedImage, .outOfMemory, .decoderUnavailable:
            return nil
        }
    }
}
