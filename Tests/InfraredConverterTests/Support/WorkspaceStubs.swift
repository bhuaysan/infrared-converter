import CoreGraphics
import Foundation
@testable import InfraredConverter

/// A decoder that never touches the filesystem, so the application layer can
/// be tested without a RAW fixture.
struct WorkspaceStubDecoder: RAWDecoder {
    var result: Result<DecodedRAW, RAWDecodingError>
    var mosaic: Result<DecodedRAWMosaic, RAWDecodingError>?

    func readMetadata(at url: URL) throws -> RAWMetadata { try result.get().metadata }

    func decode(at url: URL, options: RAWDecodeOptions) throws -> DecodedRAW {
        try result.get()
    }

    func decodeMosaic(at url: URL) throws -> DecodedRAWMosaic {
        guard let mosaic else {
            throw RAWDecodingError.unsupportedRawStorage(
                url, reason: "WorkspaceStubDecoder does not implement decodeMosaic"
            )
        }
        return try mosaic.get()
    }
}

/// A decoder that counts what it is asked to do.
///
/// The point is the count. Asserting that an orientation change produces the
/// right picture says nothing about what it cost; asserting that
/// `decodeMosaic` ran exactly once across an open and five rotations says that
/// nothing below the retained preview source ran again — no decode, and
/// therefore no normalisation, no white-balance estimate, no demosaic, no
/// camera conversion and no reduction, because every one of those is reachable
/// only through `WorkspacePreviewPipeline.prepare`, which begins with this
/// call.
final class CountingStubDecoder: RAWDecoder, @unchecked Sendable {
    private let lock = NSLock()
    private var mosaicDecodes = 0
    private var processedDecodes = 0

    private let result: Result<DecodedRAW, RAWDecodingError>
    private let mosaicResult: Result<DecodedRAWMosaic, RAWDecodingError>

    init(
        result: Result<DecodedRAW, RAWDecodingError>,
        mosaic: Result<DecodedRAWMosaic, RAWDecodingError>
    ) {
        self.result = result
        self.mosaicResult = mosaic
    }

    /// How many times the application-owned pipeline read the file.
    var mosaicDecodeCount: Int { withLock { mosaicDecodes } }
    /// How many times the LibRaw diagnostic reference read it.
    var processedDecodeCount: Int { withLock { processedDecodes } }

    func readMetadata(at url: URL) throws -> RAWMetadata { try result.get().metadata }

    func decode(at url: URL, options: RAWDecodeOptions) throws -> DecodedRAW {
        withLock { processedDecodes += 1 }
        return try result.get()
    }

    func decodeMosaic(at url: URL) throws -> DecodedRAWMosaic {
        withLock { mosaicDecodes += 1 }
        return try mosaicResult.get()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

enum WorkspaceStubs {
    /// A deliberately **non-square** RGGB mosaic whose samples all differ, so
    /// every one of the eight orientations produces a distinguishable result
    /// and a dimension swap cannot hide.
    static func mosaic(
        url: URL,
        width: Int = 8,
        height: Int = 6,
        flip: Int = 0
    ) -> DecodedRAWMosaic {
        var samples = [UInt16]()
        for index in 0..<(width * height) {
            // Wrapped into the 12-bit range the metadata's white level
            // declares, so a mosaic large enough to be worth reducing does not
            // run past what a `UInt16` sample may legitimately hold. The
            // stride is coprime with the modulus, so neighbouring samples
            // still differ and every orientation stays distinguishable.
            samples.append(UInt16((500 + index * 37) % 4096))
        }
        var metadata = RAWTestData.metadata()
        metadata.levels = .init(black: 0, perPlaneBlack: [0, 0, 0, 0], maximum: 4095)
        metadata.geometry.flip = flip
        return DecodedRAWMosaic(
            url: url,
            metadata: metadata,
            mosaic: RAWMosaic(
                width: width,
                height: height,
                bytesPerRow: width * 2,
                samples: samples.withUnsafeBufferPointer { Data(buffer: $0) },
                sampleFormat: .uint16,
                sourceRawBitDepth: 12,
                sensorColorLayout: RAWTestData.bayerLayout()
            ),
            processing: RAWMosaicProcessing(
                decoderIdentifier: "Stub",
                sourceStorage: .singleChannel,
                sourceRowPitch: width,
                destinationRowStride: width
            )
        )
    }

    /// A `DocumentState` wired to the stub, with the owned pipeline able to
    /// run end to end.
    ///
    /// The adjustment store is in-memory and fresh for every call, and that is
    /// not incidental. The production store writes a sidecar beside the RAW
    /// file, so a test using it would leave a file next to a real photograph
    /// and — because these suites share stand-in URLs — would hand one test's
    /// saved rotation to the next test's open. A test that wants persistence
    /// asks for it explicitly.
    @MainActor
    static func documentState(
        url: URL,
        width: Int = 8,
        height: Int = 6,
        flip: Int = 0,
        store: any PhotographProcessingStore = StubPhotographProcessingStore(),
        registry: IRCaptureProfileRegistry = .builtin,
        previewPolicy: PreviewResolutionPolicy = WorkspacePreviewPipeline.previewPolicy
    ) -> DocumentState {
        DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: url)),
                mosaic: .success(mosaic(url: url, width: width, height: height, flip: flip))
            ),
            store: store,
            registry: registry,
            previewPolicy: previewPolicy
        )
    }

    /// A `DocumentState` whose decoder counts, so a test can prove what an
    /// adjustment did **not** rerun.
    @MainActor
    static func countingDocumentState(
        url: URL,
        width: Int = 8,
        height: Int = 6,
        flip: Int = 0,
        store: any PhotographProcessingStore = StubPhotographProcessingStore(),
        registry: IRCaptureProfileRegistry = .builtin,
        previewPolicy: PreviewResolutionPolicy = WorkspacePreviewPipeline.previewPolicy
    ) -> (DocumentState, CountingStubDecoder) {
        let decoder = CountingStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(mosaic(url: url, width: width, height: height, flip: flip))
        )
        return (
            DocumentState(
                decoder: decoder,
                store: store,
                registry: registry,
                previewPolicy: previewPolicy
            ),
            decoder
        )
    }

    /// The display-encoded bytes behind a preview's `CGImage`, for
    /// bit-pattern comparison.
    static func pixelBytes(_ image: CGImage) -> Data? {
        image.dataProvider?.data as Data?
    }

    /// Waits until the workspace has a rendered preview for `adjustment`,
    /// matching the **orientation** term only.
    ///
    /// Polls rather than observes, because the render is detached and the
    /// point of the test is the settled result rather than the transition.
    ///
    /// For a suite whose subject is geometry this is the right question; for
    /// one whose subject is the mix, or the pair, use the overload below. A
    /// preview that matches the orientation may still carry an older mix.
    @MainActor
    static func waitForPreview(
        _ state: DocumentState,
        adjustment: UserOrientationAdjustment,
        timeout: Duration = .seconds(2)
    ) async throws -> WorkspacePreview? {
        try await waitForPreview(state, timeout: timeout) {
            $0.userOrientationAdjustment == adjustment
        }
    }

    /// Waits until the workspace has a rendered preview for one **complete**
    /// adjustment state: the orientation, the channel mix, the exposure, the
    /// white balance and the levels.
    ///
    /// Every field is compared, and that is the point rather than thoroughness
    /// for its own sake: a matcher that ignored one of them would match the
    /// *previous* preview whenever only that field had changed, and every test
    /// of that control would then quietly assert against a stale image.
    ///
    /// The mix is compared as the user's adjustment rather than as the
    /// `IRChannelMix` the stage applied, so an `.explicit` matrix equal to a
    /// built-in is not mistaken for the built-in. The exposure and the levels
    /// are each compared both as requested and as rendered, so a preview whose
    /// two disagree is never mistaken for a match. The white balance is
    /// compared as the decision the source was **prepared with**, which is the
    /// one term a render cannot change: a preview matching it is a preview of
    /// the right pixels, not merely of the right request.
    @MainActor
    static func waitForPreview(
        _ state: DocumentState,
        adjustments: ImageAdjustments,
        timeout: Duration = .seconds(2)
    ) async throws -> WorkspacePreview? {
        try await waitForPreview(state, timeout: timeout) {
            $0.userOrientationAdjustment == adjustments.orientation
                && $0.channelMixAdjustment == adjustments.channelMix
                && $0.exposureAdjustment == adjustments.exposure
                && $0.renderedExposureEV == adjustments.exposure.ev
                && $0.whiteBalanceAdjustment == adjustments.whiteBalance
                && $0.levelsAdjustment == adjustments.levels
                && $0.renderedLevels == LinearLevels(adjustments.levels)
        }
    }

    @MainActor
    private static func waitForPreview(
        _ state: DocumentState,
        timeout: Duration,
        matching: (WorkspacePreview) -> Bool
    ) async throws -> WorkspacePreview? {
        let attempts = max(1, Int(timeout / .milliseconds(5)))
        for _ in 0..<attempts {
            if case .decoded(let loaded) = state.status,
               case .rendered(let preview) = loaded.owned,
               matching(preview) {
                return preview
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }
}

// MARK: - Capture profiles a test can install

/// Profiles this build deliberately does **not** ship, so that the selection,
/// invalidation and mismatch paths can be exercised without production growing
/// fake capture configurations to make the tests possible.
///
/// Production has exactly one profile, and a picker with one item is not a
/// choice. See `docs/decisions/0020-ir-capture-profile-foundation.md`,
/// Decision 12.
enum TestCaptureProfiles {

    /// A second profile with the **same** processing basis as the built-in one.
    ///
    /// The metadata-only case: different name, different camera claim,
    /// different filter, identical pixels by construction. Selecting it must
    /// cost a re-render and not a re-preparation.
    static let metadataOnly = IRCaptureProfile(
        id: try! IRCaptureProfileID("user.metadata-only"),
        name: "Metadata Only",
        cameraMatch: .any,
        sensorConversion: .fullSpectrum(vendor: "A Vendor"),
        filter: try! IRFilterDescriptor.longPass(nominalNanometers: 720),
        processingBasis: .uncalibratedSensorRGB
    )

    /// A profile tied to the reference camera's make and model.
    ///
    /// `RAWTestData.metadata()` names a different camera, so this one
    /// mismatches the synthetic fixtures — which is what it is for.
    static let olympusEPL3 = IRCaptureProfile(
        id: try! IRCaptureProfileID("user.olympus-epl3-720nm"),
        name: "Olympus E-PL3 720 nm",
        cameraMatch: .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
        sensorConversion: .fullSpectrum(vendor: nil),
        filter: try! IRFilterDescriptor.longPass(nominalNanometers: 720),
        processingBasis: .uncalibratedSensorRGB
    )

    /// A profile whose **processing basis differs**, so selecting it genuinely
    /// changes pixels.
    ///
    /// The matrix carries no calibration claim — it is
    /// `RAWCameraToWorkingColorTransform.explicit(matrix:)`, whose whole
    /// contract is that the coefficients are finite — and it is deliberately
    /// asymmetric with exact binary-fraction values, so that a rendering made
    /// under it is unmistakably different from one made under the identity.
    static let differentBasis = IRCaptureProfile(
        id: try! IRCaptureProfileID("user-different-basis.experiment"),
        name: "Different Basis (experimental)",
        cameraMatch: .any,
        sensorConversion: .unknown,
        filter: .unknown,
        processingBasis: .explicitMatrix(
            try! RAWColorMatrix3x3(
                m00: 0.5, m01: 0.25, m02: 0,
                m10: 0, m11: 1, m12: 0,
                m20: 0, m21: 0, m22: 2
            )
        )
    )

    /// An identifier no registry in these tests contains.
    static let missingID = try! IRCaptureProfileID("user.does-not-exist")

    /// A registry holding the built-in profile and the metadata-only one.
    static let withMetadataOnly = try! IRCaptureProfileRegistry(
        profiles: [.builtinUncalibrated, metadataOnly]
    )

    /// A registry holding the built-in profile and the camera-specific one.
    static let withCameraSpecific = try! IRCaptureProfileRegistry(
        profiles: [.builtinUncalibrated, olympusEPL3]
    )

    /// A registry holding the built-in profile and the one whose basis differs.
    static let withDifferentBasis = try! IRCaptureProfileRegistry(
        profiles: [.builtinUncalibrated, differentBasis]
    )

    /// Every test profile at once, for a suite that switches between them.
    static let all = try! IRCaptureProfileRegistry(
        profiles: [.builtinUncalibrated, metadataOnly, olympusEPL3, differentBasis]
    )
}
