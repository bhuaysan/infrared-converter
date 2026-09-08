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
    /// Identifies the decoder, e.g. "LibRaw 0.21.4".
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
    /// Demosaicing the decoder performed, if any.
    public var demosaic: RAWDecodeOptions.Demosaic?
    /// Whether a camera/vendor colour matrix was applied to the samples.
    public var cameraColorMatrixApplied: Bool
    /// Whether an automatic brightness/exposure scaling was applied.
    public var autoBrightnessApplied: Bool
    /// Whether the decoder reconstructed clipped highlights.
    public var highlightReconstructionApplied: Bool
    /// Whether any noise reduction or sharpening was applied.
    public var noiseReductionApplied: Bool
    /// Whether the camera orientation was baked into the buffer.
    public var cameraOrientationApplied: Bool
    /// Warnings the decoder raised that affect interpretation.
    public var warnings: [String]

    public init(
        decoderIdentifier: String,
        blackLevelSubtracted: Bool,
        normalizedToFullRange: Bool,
        appliedWhiteBalanceMultipliers: [Float],
        demosaic: RAWDecodeOptions.Demosaic?,
        cameraColorMatrixApplied: Bool,
        autoBrightnessApplied: Bool,
        highlightReconstructionApplied: Bool,
        noiseReductionApplied: Bool,
        cameraOrientationApplied: Bool,
        warnings: [String] = []
    ) {
        self.decoderIdentifier = decoderIdentifier
        self.blackLevelSubtracted = blackLevelSubtracted
        self.normalizedToFullRange = normalizedToFullRange
        self.appliedWhiteBalanceMultipliers = appliedWhiteBalanceMultipliers
        self.demosaic = demosaic
        self.cameraColorMatrixApplied = cameraColorMatrixApplied
        self.autoBrightnessApplied = autoBrightnessApplied
        self.highlightReconstructionApplied = highlightReconstructionApplied
        self.noiseReductionApplied = noiseReductionApplied
        self.cameraOrientationApplied = cameraOrientationApplied
        self.warnings = warnings
    }
}

/// Failures the RAW boundary can report.
///
/// Underlying decoder diagnostics are preserved in `DecoderDiagnostic` so they
/// remain available for logging without the UI ever seeing an integer code.
public enum RAWDecodingError: Error, Equatable {
    /// Diagnostic detail from the underlying decoder.
    public struct DecoderDiagnostic: Equatable, Sendable, CustomStringConvertible {
        public let code: Int32
        public let message: String

        public init(code: Int32, message: String) {
            self.code = code
            self.message = message
        }

        public var description: String { "\(message) (code \(code))" }
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
        diagnostic?.description
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
