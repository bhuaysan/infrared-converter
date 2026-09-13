import Foundation

/// A full-resolution export failing, at the step that failed.
///
/// Five distinguishable problems rather than one "export failed", because
/// they call for five different responses: a corrupt RAW file, an orientation
/// this version does not model, an image the encoder refuses, a destination
/// that cannot be created, and a write that could not be completed.
public enum FullResolutionExportError: Error {
    /// The RAW file could not be decoded or processed into the working
    /// representation. Carries whatever the stage reported —
    /// `RAWDecodingError` or `RAWProcessingError`.
    case rawPreparationFailed(url: URL, underlying: any Error)
    /// One of the canonical adjustments could not be applied.
    case adjustmentProcessingFailed(stage: AdjustmentStage, underlying: any Error)
    /// The adjusted image could not be encoded for export.
    case encodingFailed(underlying: ExportEncodingError)
    /// The encoded image could not be written to a file.
    case writingFailed(underlying: TIFFExportError)

    /// Which adjustment stage refused the image.
    public enum AdjustmentStage: String, Equatable, Sendable {
        case channelMix
        case orientation
        case exposure

        public var diagnosticDescription: String {
            switch self {
            case .channelMix: return "the creative channel mix"
            case .orientation: return "the orientation"
            case .exposure: return "the exposure"
            }
        }
    }
}

extension FullResolutionExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .rawPreparationFailed:
            return "The RAW file could not be processed for export."
        case .adjustmentProcessingFailed:
            return "The adjustments could not be applied at full resolution."
        case .encodingFailed:
            return "The rendered image could not be encoded for export."
        case .writingFailed(let underlying):
            return underlying.errorDescription
        }
    }

    public var failureReason: String? {
        switch self {
        case .rawPreparationFailed(let url, let underlying):
            return """
                \(url.lastPathComponent): \(Self.describe(underlying)) The export starts \
                from the RAW file, so nothing was written.
                """
        case .adjustmentProcessingFailed(let stage, let underlying):
            return """
                Applying \(stage.diagnosticDescription) failed: \(Self.describe(underlying))
                """
        case .encodingFailed(let underlying):
            return Self.describe(underlying)
        case .writingFailed(let underlying):
            return underlying.failureReason
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError).flatMap { $0.failureReason ?? $0.errorDescription }
            ?? error.localizedDescription
    }
}

/// One export's rendered pixels: scene-linear, full resolution, every
/// canonical adjustment applied, nothing encoded yet.
///
/// The hand-over point between RAW processing and file encoding, and the
/// value a test inspects to see that a red/blue swap, a quarter turn and a
/// stop of exposure all happened — and happened *before* anything was clipped
/// or quantised.
public struct FullResolutionExportRender: Sendable {
    /// The adjusted scene-linear image, at the sensor's own resolution.
    public let image: ExposedSceneLinearRGBImage
    /// The RAW-state metadata the chain was processed against.
    public let metadata: RAWMetadata
    /// The snapshot this was rendered from.
    public let request: ExportRequest
    /// The region the white balance was estimated from, in full-resolution
    /// sensor (pre-orientation) active-area coordinates.
    public let neutralPatch: RAWActiveAreaRegion

    init(
        image: ExposedSceneLinearRGBImage,
        metadata: RAWMetadata,
        request: ExportRequest,
        neutralPatch: RAWActiveAreaRegion
    ) {
        self.image = image
        self.metadata = metadata
        self.request = request
        self.neutralPatch = neutralPatch
    }

    /// Width in pixels, as viewed — after orientation.
    public var pixelWidth: Int { image.width }
    /// Height in pixels, as viewed.
    public var pixelHeight: Int { image.height }
    /// The orientation the pixels were actually permuted by.
    public var orientation: RAWImageOrientation { image.processing.orientation }
    /// The mix the creative stage actually applied.
    public var mix: IRChannelMix { image.processing.mix }
    /// The exposure the scene-linear stage actually applied.
    public var exposureEV: Double { image.processing.exposureEV }
}

/// The full-resolution end path: a RAW file and one canonical adjustment
/// state, rendered at the sensor's own resolution and written to a file.
///
/// ```text
/// ExportRequest = RAW URL + ImageAdjustments
///     ↓  RAWWorkingImagePipeline      the SHARED front half
/// WorkingColorRGBImage                full resolution, scene-linear, pre-creative
///     ↓  IRChannelMixer               adjustments.channelMix
/// IRChannelMixedRGBImage
///     ↓  ImageOrienter                file orientation + adjustments.orientation
/// OrientedSceneLinearRGBImage
///     ↓  SceneLinearExposer           adjustments.exposure
/// ExposedSceneLinearRGBImage          ← the full-resolution render
///     ↓  ExportImageEncoder           clip, sRGB, 16-bit quantisation
/// ExportEncodedImage
///     ↓  TIFFExporter                 temp file → finalise → move
/// a 16-bit RGB TIFF
/// ```
///
/// See `docs/decisions/0018-full-resolution-tiff-export.md`.
///
/// ## Why this starts from the file, every time
///
/// Because preview pixels are not the photograph. The interactive workspace
/// holds a reduced, disposable rendition — 2048 pixels on its longest edge
/// where the reference camera records 4056 — and an export that started from
/// it would be an upscaled preview wearing a 16-bit file's clothes. So this
/// path takes a URL and re-reads it. There is no overload that accepts an
/// image, a preview, a `Source` or a `CGImage`, and adding one would be the
/// defect rather than the convenience.
///
/// ## Why it is not a second colour pipeline
///
/// Everything before the reduction point is `RAWWorkingImagePipeline`, the
/// same code the preview runs. Everything between the reduction point and the
/// encoder is the same three stages the preview's `render` runs, in the same
/// order, called with the same adjustment values. The paths diverge at exactly
/// two places, and both are deliberate:
///
/// ```text
///                  interactive preview            full-resolution export
/// resolution       reduced by a size policy       the sensor's own
/// destination      8-bit sRGB CGImage on screen   16-bit sRGB TIFF on disk
/// ```
///
/// `PreviewResolutionPolicy` is not a parameter of anything here. It cannot
/// influence an export, because it never reaches one.
///
/// ## Cost and memory
///
/// The most expensive thing the application does, and deliberately so. For the
/// 4056×3040 reference frame one full-resolution `Float32` RGB buffer is about
/// 148 MB, and the four the adjustment stages produce — working, mixed,
/// oriented, exposed — are all in scope inside `applyAdjustments`, so the
/// conservative bound is about 592 MB while the last is being written. Once
/// `render` returns only the exposed image survives, and the encoder's 74 MB
/// `UInt16` buffer is allocated beside that one alone.
///
/// An identity mix, an upright orientation and a `0 EV` exposure each hand
/// their input's buffer back rather than copying it, so a neutral export
/// allocates one `Float32` image and the result.
///
/// It belongs off the main thread, and `DocumentState` runs it there.
///
/// ## Cancellation
///
/// The three adjustment stages and the encoder poll `cancellation` once per
/// row. The RAW front half does not — none of its stages does — so an export
/// cancelled during decoding stops at the task boundary rather than inside the
/// pass. A cancelled export throws `CancellationError`, which is deliberately
/// not a `FullResolutionExportError`: nobody wanting the result is not the
/// same as being unable to produce it.
public struct FullResolutionExportPipeline: Sendable {
    public init() {}

    /// The range policy and encoding every export uses.
    ///
    /// An application choice, stated here rather than defaulted inside the
    /// encoder — the same reason `WorkspacePreviewPipeline` states the display
    /// path's.
    public static let settings = ExportRenderSettings.standard

    /// Renders one export request at full resolution, stopping before any
    /// encoding.
    ///
    /// - Throws: `FullResolutionExportError`, or `CancellationError`.
    public func render(
        _ request: ExportRequest,
        using decoder: RAWDecoder,
        cancellation: ProcessingCancellation = .none
    ) throws -> FullResolutionExportRender {
        let prepared: PreparedWorkingImage
        do {
            prepared = try RAWWorkingImagePipeline().prepare(
                decoding: request.rawURL, using: decoder
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FullResolutionExportError.rawPreparationFailed(
                url: request.rawURL, underlying: error
            )
        }

        // The adjustments are applied in their own scope so that the working,
        // mixed and oriented buffers — each the size of a full-resolution
        // Float32 RGB image — become unreachable as soon as the exposed
        // result exists.
        let exposed = try Self.applyAdjustments(
            to: prepared,
            adjustments: request.adjustments,
            cancellation: cancellation
        )

        return FullResolutionExportRender(
            image: exposed,
            metadata: prepared.metadata,
            request: request,
            neutralPatch: prepared.neutralPatch
        )
    }

    /// Encodes a rendered export into 16-bit samples.
    ///
    /// - Throws: `FullResolutionExportError.encodingFailed`, or
    ///   `CancellationError`.
    public func encode(
        _ rendered: FullResolutionExportRender,
        settings: ExportRenderSettings = FullResolutionExportPipeline.settings,
        cancellation: ProcessingCancellation = .none
    ) throws -> ExportEncodedImage {
        do {
            return try ExportImageEncoder().encode(
                rendered.image, settings: settings, cancellation: cancellation
            )
        } catch let error as ExportEncodingError {
            throw FullResolutionExportError.encodingFailed(underlying: error)
        }
    }

    /// Renders, encodes and writes one export request.
    ///
    /// The whole end path, and the call the application makes. It takes a URL
    /// and gives back a receipt; nothing that resembles a preview passes
    /// through it in either direction.
    ///
    /// - Throws: `FullResolutionExportError`, or `CancellationError`.
    @discardableResult
    public func export(
        _ request: ExportRequest,
        to destination: URL,
        using decoder: RAWDecoder,
        settings: ExportRenderSettings = FullResolutionExportPipeline.settings,
        cancellation: ProcessingCancellation = .none
    ) throws -> TIFFExportResult {
        let rendered = try render(request, using: decoder, cancellation: cancellation)
        let encoded = try encode(rendered, settings: settings, cancellation: cancellation)
        do {
            return try TIFFExporter().write(
                encoded,
                to: destination,
                metadata: rendered.metadata,
                sourceURL: request.rawURL,
                adjustments: request.adjustments
            )
        } catch let error as TIFFExportError {
            throw FullResolutionExportError.writingFailed(underlying: error)
        }
    }

    // MARK: - The adjustable stages

    /// Mix, then orientation, then exposure — the same three stages the
    /// interactive preview runs, in the same order, from the same values.
    ///
    /// The order is fixed and is not a matter of taste: the mix is a colour
    /// operation on a scene-linear representation, the orientation is discrete
    /// geometry, and exposure is a scalar on light. Colour, then geometry,
    /// then exposure — matching the preview exactly, because the claim this
    /// milestone makes is that the two are the same rendering.
    private static func applyAdjustments(
        to prepared: PreparedWorkingImage,
        adjustments: ImageAdjustments,
        cancellation: ProcessingCancellation
    ) throws -> ExposedSceneLinearRGBImage {
        // The bare-image overloads throughout: the wrapper overloads keep the
        // whole upstream chain reachable through `source`, and at full
        // resolution that is several hundred megabytes nobody needs.
        let mixed: IRChannelMixedRGBImage
        do {
            mixed = try IRChannelMixer().apply(
                to: prepared.image,
                mix: adjustments.channelMix.mix,
                cancellation: cancellation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FullResolutionExportError.adjustmentProcessingFailed(
                stage: .channelMix, underlying: error
            )
        }

        let oriented: OrientedSceneLinearRGBImage
        do {
            let orientation = try RAWWorkingImagePipeline.effectiveOrientation(
                for: prepared.metadata, adjustments: adjustments
            )
            oriented = try ImageOrienter().apply(
                to: mixed, orientation: orientation.applied, cancellation: cancellation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FullResolutionExportError.adjustmentProcessingFailed(
                stage: .orientation, underlying: error
            )
        }

        do {
            return try SceneLinearExposer().apply(
                to: oriented,
                exposure: SceneLinearExposure(adjustments.exposure),
                cancellation: cancellation
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FullResolutionExportError.adjustmentProcessingFailed(
                stage: .exposure, underlying: error
            )
        }
    }
}
