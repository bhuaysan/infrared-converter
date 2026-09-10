import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The workspace. It presents whatever `DocumentState` currently holds and
/// collects the "Open RAW…" action; it performs no decoding of its own.
struct ContentView: View {
    @State private var documentState = DocumentState()

    private static let rawFileExtensions = [
        "orf", "arw", "nef", "nrw", "cr2", "cr3", "raf", "rw2"
    ]

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button("Open RAW…", action: openRAW)
                Spacer()
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private var content: some View {
        switch documentState.status {
        case .empty:
            placeholder("No RAW file selected")

        case .decoding(let url):
            VStack(spacing: 12) {
                ProgressView()
                Text("Decoding \(url.lastPathComponent)…")
                    .foregroundStyle(.secondary)
            }

        case .decoded(let loaded):
            HSplitView {
                OwnedPreviewView(owned: loaded.owned)
                    .frame(minWidth: 320)
                RAWInspectorView(loaded: loaded)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            }

        case .failed(let url, let error):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.headline)
                Text(error.errorDescription ?? "The file could not be decoded.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let diagnostic = error.diagnostic {
                    // `userFacingSummary` is guaranteed free of LibRaw's
                    // internal integer code; the code stays available only
                    // via `diagnostic.logDescription`, for logging.
                    Text(diagnostic.userFacingSummary)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(40)
        }
    }

    private func placeholder(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openRAW() {
        let panel = NSOpenPanel()
        panel.title = "Open RAW File"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.rawFileExtensions.compactMap {
            UTType(filenameExtension: $0)
        }

        if panel.runModal() == .OK, let url = panel.url {
            documentState.open(url)
        }
    }
}

/// Shows the **application-owned** pipeline's pixels, or says why there are
/// none.
///
/// A failure is reported here rather than replaced by the legacy LibRaw image.
/// Falling back would put a visually plausible picture from a different
/// pipeline in the place where this one's result belongs, and nothing on
/// screen would say so.
private struct OwnedPreviewView: View {
    let owned: DocumentState.OwnedPreview

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            switch owned {
            case .rendered(let preview):
                Image(decorative: preview.image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)

            case .unavailable(let reason):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("The preview could not be rendered")
                        .font(.headline)
                    Text(reason)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(40)
            }
        }
    }
}

/// Read-only summary of what the decoder reported.
private struct RAWInspectorView: View {
    let loaded: DocumentState.Loaded

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("File") {
                    row("Name", loaded.url.lastPathComponent)
                    row("Status", "Decoded")
                }

                section("Camera") {
                    row("Make", loaded.metadata.identity.make)
                    row("Model", loaded.metadata.identity.model)
                    row("Lens", loaded.metadata.lens)
                }

                section("Dimensions") {
                    let geometry = loaded.metadata.geometry
                    row("Full image", "\(geometry.outputWidth) × \(geometry.outputHeight)")
                    row("Active area", "\(geometry.visibleWidth) × \(geometry.visibleHeight)")
                    row("Sensor readout", "\(geometry.rawWidth) × \(geometry.rawHeight)")
                }

                ownedPreviewSection

                section("Sensor") {
                    row("Layout", layoutDescription)
                    row("Colour planes", loaded.metadata.sensor.colorDescription)
                    row("Source RAW bit depth", loaded.metadata.sensor.sourceRawBitDepth.map { "\($0) bit" })
                    row("Black level", "\(loaded.metadata.levels.black)")
                    row("Saturation", "\(loaded.metadata.levels.maximum)")
                }

                section("Exposure") {
                    let exposure = loaded.metadata.exposure
                    row("ISO", exposure.iso.map { "\(Int($0))" })
                    row("Shutter", exposure.shutterSeconds.map(Self.shutterDescription))
                    row("Aperture", exposure.aperture.map { String(format: "f/%.1f", $0) })
                    row("Focal length", exposure.focalLength.map { String(format: "%.0f mm", $0) })
                    row("Captured", exposure.captureDate.map {
                        $0.formatted(date: .abbreviated, time: .shortened)
                    })
                }

                section("Camera white balance") {
                    row("As shot", Self.multipliers(loaded.metadata.color.cameraMultipliers))
                    row("Daylight", Self.multipliers(loaded.metadata.color.daylightMultipliers))
                    Text("Reported only. The decoder applied unity multipliers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                section("LibRaw reference (diagnostic)") {
                    let processing = loaded.decoded.processing
                    Text("""
                        A separate, LibRaw-processed decode. It is not what the workspace \
                        shows, and it is not a colour reference.
                        """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let legacyPreview = loaded.legacyPreview {
                        Image(decorative: legacyPreview, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 120)
                    }
                    row("Size", "\(loaded.decoded.image.width) × \(loaded.decoded.image.height)")
                    row("Decoder", processing.decoderIdentifier)
                    row("Pixel format", "\(loaded.decoded.image.channelCount) × "
                        + "\(loaded.decoded.image.bitsPerChannel) bit, interleaved RGB")
                    row("Encoding", loaded.decoded.image.encoding == .linear ? "Linear" : "Gamma encoded")
                    row("Colour", loaded.decoded.image.colorSpace == .cameraNative
                        ? "Camera native (no matrix)" : "sRGB")
                    row("White balance", processing.whiteBalanceIsUnity ? "Unity (none applied)" : "Applied")
                    row("Demosaic", Self.demosaicRowDescription(processing))
                }
            }
            .padding(16)
        }
    }

    /// What the application-owned pipeline did, in the order it did it.
    ///
    /// Every line here is read back from the preview's own provenance record,
    /// so the panel cannot describe a rendering the renderer did not perform.
    @ViewBuilder
    private var ownedPreviewSection: some View {
        section("Owned preview") {
            switch loaded.owned {
            case .rendered(let preview):
                let processing = preview.processing
                row("Size", "\(preview.pixelWidth) × \(preview.pixelHeight)")
                row("White balance", "Neutral patch, \(Self.regionDescription(preview.neutralPatch))")
                row("Camera → working", Self.transformDescription(
                    processing.cameraToWorkingTransformSource
                ))
                row("Channel mix", Self.mixDescription(processing.mixSource))
                row("Exposure", String(format: "%+.2f EV", processing.exposureEV))
                row("Out-of-range", Self.clippingDescription(processing))
                row("Encoding", "sRGB, 8 bit, no alpha")
                Text("""
                    Displayable, not colour-validated: no transform in this pipeline is a \
                    validated infrared calibration.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .unavailable(let reason):
                row("Status", "Failed")
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func regionDescription(_ region: RAWActiveAreaRegion) -> String {
        "\(region.width) × \(region.height) at (\(region.originRow), \(region.originColumn))"
    }

    private static func transformDescription(
        _ source: RAWCameraToWorkingColorTransformSource
    ) -> String {
        switch source {
        case .sensorRGBIdentityFalseColor: return "Identity false colour"
        case .explicit: return "Explicit matrix"
        case .visibleLightMetadataRGBFromCamera: return "File's visible-light matrix"
        }
    }

    private static func mixDescription(_ source: IRChannelMixSource) -> String {
        switch source {
        case .identity: return "Identity (no remap)"
        case .redBlueSwap: return "Red/blue swap"
        case .explicit: return "Explicit matrix"
        }
    }

    /// How much the display-range clipping destroyed, as a count rather than
    /// an impression.
    private static func clippingDescription(_ processing: DisplayPreviewProcessing) -> String {
        guard processing.clippedSampleCount > 0 else { return "None clipped" }
        return "\(processing.clippedLowSampleCount) low, "
            + "\(processing.clippedHighSampleCount) high (clipped)"
    }

    private var layoutDescription: String {
        switch loaded.metadata.sensor.pattern {
        case .bayer:
            let sensor = loaded.metadata.sensor
            let letters = (0..<2).flatMap { row in
                (0..<2).compactMap { sensor.colorPlaneLetter(row: row, column: $0) }
            }
            return letters.count == 4 ? "Bayer \(String(letters))" : "Bayer"
        case .xTrans: return "X-Trans"
        case .foveon: return "Foveon"
        case .none: return "Full colour"
        case .unknown: return "Unknown"
        }
    }

    private static func multipliers(_ values: [Float]?) -> String? {
        guard let values else { return nil }
        return values.prefix(3).map { String(format: "%.3f", $0) }.joined(separator: "  ")
    }

    private static func shutterDescription(_ seconds: Float) -> String {
        seconds >= 1 ? String(format: "%.1f s", seconds) : "1/\(Int((1 / seconds).rounded()))"
    }

    private static func demosaicDescription(_ demosaic: RAWDecodeOptions.Demosaic) -> String {
        switch demosaic {
        case .bilinear: return "Bilinear"
        case .vng: return "VNG"
        case .ppg: return "PPG"
        case .ahd: return "AHD"
        }
    }

    /// Shows what actually ran, and flags it explicitly when that differs
    /// from what was requested (e.g. LibRaw silently falling back to AHD).
    private static func demosaicRowDescription(_ processing: RAWDecoderProcessing) -> String {
        guard let applied = processing.appliedDemosaic else { return "None (half size)" }
        let appliedText = demosaicDescription(applied)
        guard let requested = processing.requestedDemosaic, requested != applied else {
            return appliedText
        }
        return "\(appliedText) (requested \(demosaicDescription(requested)))"
    }

    @ViewBuilder
    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value ?? "—")
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
