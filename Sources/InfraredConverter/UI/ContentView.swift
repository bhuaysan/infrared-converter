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

            HStack(spacing: 12) {
                Button("Open RAW…", action: openRAW)
                Divider().frame(height: 18)
                ExportControl(documentState: documentState)
                Divider().frame(height: 18)
                ChannelMixControl(documentState: documentState)
                Divider().frame(height: 18)
                ExposureControl(documentState: documentState)
                Divider().frame(height: 18)
                OrientationControls(documentState: documentState)
                Spacer()
                AdjustmentSaveStatus(documentState: documentState)
            }
            .padding(12)
        }
        .frame(minWidth: 1080, minHeight: 520)
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
                // Both refusals, labelled. The image pipeline's is the one
                // that matters; the reference's is shown beside it because
                // two different reasons say which stage disagreed, and
                // collapsing them to one message destroys that.
                Text("Image pipeline: \(error.owned.message)")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
                Text("LibRaw reference: \(error.legacy.message)")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
            }
            .padding(40)

        case .adjustmentsUnreadable(let url, let error):
            // A different problem from a file that will not decode, and shown
            // as one: the photograph is presumed fine, the saved adjustments
            // are not, and the file the user can act on is named. Nothing was
            // repaired or deleted, and the text says so.
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(url.lastPathComponent)
                    .font(.headline)
                Text(error.errorDescription ?? "The saved adjustments could not be used.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let reason = error.failureReason {
                    Text(reason)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.tertiary)
                }
                Text(error.sidecar.lastPathComponent)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.tertiary)
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

            case .unavailable(let failure):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("The preview could not be rendered")
                        .font(.headline)
                    Text(failure.message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    // The stage's own elaboration, where it has one. Free of
                    // LibRaw's internal integer codes by construction.
                    if let reason = failure.failureReason {
                        Text(reason)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.tertiary)
                    }
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

                legacyReferenceSection
            }
            .padding(16)
        }
    }

    /// The LibRaw processed-RGB decode, when there is one.
    ///
    /// Its absence is reported here and changes nothing else on the screen:
    /// this is a diagnostic reference, and a missing reference is not a
    /// missing photograph. It is equally never the other way round — nothing
    /// in this section can stand in for the owned preview above it.
    @ViewBuilder
    private var legacyReferenceSection: some View {
        section("LibRaw reference (diagnostic)") {
            Text("""
                A separate, LibRaw-processed decode. It is not what the workspace \
                shows, and it is not a colour reference.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch loaded.legacy {
            case .decoded(let decoded, let preview):
                let processing = decoded.processing
                if let preview {
                    Image(decorative: preview, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 120)
                }
                row("Size", "\(decoded.image.width) × \(decoded.image.height)")
                row("Decoder", processing.decoderIdentifier)
                row("Pixel format", "\(decoded.image.channelCount) × "
                    + "\(decoded.image.bitsPerChannel) bit, interleaved RGB")
                row("Encoding", decoded.image.encoding == .linear ? "Linear" : "Gamma encoded")
                row("Colour", decoded.image.colorSpace == .cameraNative
                    ? "Camera native (no matrix)" : "sRGB")
                row("White balance", processing.whiteBalanceIsUnity ? "Unity (none applied)" : "Applied")
                row("Demosaic", Self.demosaicRowDescription(processing))
            case .unavailable(let failure):
                row("Status", "Unavailable")
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                row("Preview resolution", Self.resolutionDescription(preview.resolution))
                row("Recorded orientation", Self.recordedOrientationDescription(preview))
                row("Your correction", Self.userOrientationDescription(preview))
                row("Orientation applied", Self.orientationDescription(preview))
                row("White balance", "Neutral patch, \(Self.regionDescription(preview.neutralPatch))")
                row("Camera → working", Self.transformDescription(
                    processing.cameraToWorkingTransformSource
                ))
                row("Channel mix", Self.mixDescription(preview))
                // The exposure the display stage applied, from its own
                // provenance — not the slider's value. While a render is
                // pending the slider is already ahead of this row, and that is
                // correct: the controls show the requested state, the
                // inspector describes the image on screen.
                row("Exposure", String(
                    format: "%+.2f EV", preview.renderedExposureEV == 0 ? 0 : preview.renderedExposureEV
                ))
                row("Out-of-range", Self.clippingDescription(processing))
                row("Encoding", "sRGB, 8 bit, no alpha")
                Text("""
                    Displayable, not colour-validated: no transform in this pipeline is a \
                    validated infrared calibration.
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .unavailable(let failure):
                row("Status", "Failed")
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What the orientation stage did, in the vocabulary of the metadata it
    /// read.
    ///
    /// The pixel buffer itself is oriented; nothing in this view rotates
    /// anything. A file recording `.upright` is shown as it was stored, and
    /// this row says so rather than leaving the reader to wonder whether a
    /// stage was skipped.
    /// What resolution the displayed pixels are, and what they were reduced
    /// from.
    ///
    /// Shown because a reader who is looking at a 2048-pixel rendition of a
    /// 4056-pixel photograph should be told so, rather than left to compare
    /// the Size row against the decoder's own dimensions further down the
    /// panel.
    private static func resolutionDescription(_ resolution: PreviewResolution) -> String {
        let full = "\(resolution.sourceWidth) × \(resolution.sourceHeight) active area"
        guard resolution.isReduced else {
            return "Full resolution (\(full))"
        }
        let factor = resolution.pixelReductionFactor.map {
            String(format: "%.1f× fewer pixels", $0)
        } ?? "reduced"
        return "Reduced from \(full), \(factor)"
    }

    private static func orientationDescription(_ preview: WorkspacePreview) -> String {
        let orientation = preview.effectiveOrientation
        let source = "\(preview.sourcePixelWidth) × \(preview.sourcePixelHeight) preview source"
        guard !orientation.isIdentity else {
            return "Upright (\(source))"
        }
        return orientation.diagnosticDescription.prefix(1).uppercased()
            + orientation.diagnosticDescription.dropFirst()
            + " (from \(source))"
    }

    /// What the file asked for, kept visibly separate from what the user did.
    ///
    /// The panel shows both terms and the result, so a reader can see why the
    /// image has its geometry without having to guess which of the two
    /// produced it.
    private static func recordedOrientationDescription(
        _ preview: WorkspacePreview
    ) -> String {
        let recorded = preview.sourceOrientation
        return "EXIF \(recorded.exifOrientation) — \(recorded.diagnosticDescription)"
    }

    private static func userOrientationDescription(_ preview: WorkspacePreview) -> String {
        let adjustment = preview.userOrientationAdjustment
        return adjustment.isIdentity
            ? "None"
            : adjustment.diagnosticDescription.prefix(1).uppercased()
                + adjustment.diagnosticDescription.dropFirst()
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

    /// What the creative stage applied, and that a person chose it.
    ///
    /// Read from the preview's own provenance, so the panel cannot describe a
    /// mix the renderer did not apply. The wording says "creative" because
    /// this row sits two lines below a colour transform and is emphatically
    /// not one.
    private static func mixDescription(_ preview: WorkspacePreview) -> String {
        let applied: String
        switch preview.channelMix.source {
        case .identity: applied = "Identity (no remap)"
        case .redBlueSwap: applied = "Red/blue swap"
        case .explicit: applied = "Explicit matrix"
        }
        return "\(applied) — creative, your choice"
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


/// The orientation controls.
///
/// They operate on `DocumentState`'s adjustment record and nothing else. No
/// view here touches a pixel buffer, a `CGImage`, a `CGAffineTransform` or a
/// `rotationEffect`: pressing a button changes one canonical adjustment value,
/// and the pipeline re-derives the effective orientation and permutes the
/// retained scene-linear image once.
///
/// Deliberately absent, because they are a different problem that needs
/// resampling: arbitrary-angle rotation, a free-form degree field,
/// straightening and crop.
private struct OrientationControls: View {
    let documentState: DocumentState

    var body: some View {
        HStack(spacing: 8) {
            Group {
            Button(action: documentState.rotateOrientationLeft) {
                Label("Rotate Left", systemImage: "rotate.left")
            }
            .help("Rotate the photograph 90° counter-clockwise")
            .accessibilityLabel("Rotate left 90 degrees")

            Button(action: documentState.rotateOrientationRight) {
                Label("Rotate Right", systemImage: "rotate.right")
            }
            .help("Rotate the photograph 90° clockwise")
            .accessibilityLabel("Rotate right 90 degrees")

            Button(action: documentState.flipOrientationHorizontally) {
                Label("Flip Horizontally", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .help("Exchange left and right")
            .accessibilityLabel("Flip horizontally")

            Button(action: documentState.flipOrientationVertically) {
                Label("Flip Vertically", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down")
            }
            .help("Exchange top and bottom")
            .accessibilityLabel("Flip vertically")
            }
            .labelStyle(.iconOnly)

            // Named for what it resets. There is a second adjustment now, and
            // a button labelled "Reset" beside a channel-mix control would
            // read as resetting both — which it deliberately does not do.
            Button("Reset Orientation", action: documentState.resetOrientation)
                .help("Return to the orientation the file records — not necessarily upright")
                .accessibilityLabel("Reset orientation to the file's own")
                .disabled(documentState.orientationAdjustment.isIdentity)
        }
        .buttonStyle(.bordered)
        .disabled(!documentState.canAdjust)
    }
}


/// The creative infrared channel-mix control.
///
/// Two choices, because there are two the project can honestly offer: traverse
/// the creative stage and remap nothing, or perform the canonical infrared
/// operation and exchange red with blue. Neither is a calibration and the
/// control does not suggest otherwise.
///
/// It changes one field of `DocumentState`'s canonical adjustment record and
/// nothing else. No view here multiplies a matrix, touches a pixel buffer or
/// knows that `IRChannelMix` exists: the workspace re-renders the retained
/// pre-mix preview with whatever state it now holds.
///
/// ## Why a menu rather than a segmented picker
///
/// Because the adjustment has a third state the workspace can load and this
/// milestone deliberately cannot author: an explicit 3x3 matrix, which a
/// sidecar may carry. A menu shows the current state in its label whatever it
/// is, where a segmented control with no matching segment would simply render
/// nothing selected and say the file has no mix.
///
/// Deliberately absent: a matrix editor, per-channel percentage sliders,
/// presets, filter profiles, and anything that would pick a mix for the user.
/// A freshly opened file with no saved decision is `.identity`, and it stays
/// that way until a person chooses otherwise — nothing here inspects the
/// photograph to guess whether it is infrared.
private struct ChannelMixControl: View {
    let documentState: DocumentState

    var body: some View {
        Menu {
            ForEach(UserChannelMixAdjustment.selectableCases, id: \.kind) { mix in
                Button {
                    documentState.setChannelMix(mix)
                } label: {
                    // The current state is marked as well as shown in the
                    // label, so the menu says which of the two is in force
                    // rather than only what can be picked.
                    if mix == documentState.channelMixAdjustment {
                        Label(mix.shortDescription, systemImage: "checkmark")
                    } else {
                        Text(mix.shortDescription)
                    }
                }
            }
        } label: {
            Label(
                documentState.channelMixAdjustment.shortDescription,
                systemImage: "circle.lefthalf.filled"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Creative infrared channel mix — not a colour calibration")
        .accessibilityLabel(
            "Channel mix: \(documentState.channelMixAdjustment.diagnosticDescription)"
        )
        .disabled(!documentState.canAdjust)
    }
}


/// The exposure control: a slider, the numeric value, and a reset.
///
/// It changes one field of `DocumentState`'s canonical adjustment record and
/// nothing else. No view here multiplies a pixel, touches a `CGImage` or knows
/// what `2^EV` is: each slider write becomes a `UserExposureAdjustment`, the
/// workspace asks its coalescing renderer for the complete state, and the
/// display stage applies it to the retained scene-linear preview.
///
/// ## What the control shows
///
/// The **requested** exposure, read from `DocumentState` — never the exposure
/// of the last preview that happened to be delivered. A drag that outruns the
/// renderer therefore does not snap the thumb back to an older value while a
/// render is pending; the inspector, which reads the preview's provenance, is
/// the place that describes the image actually on screen.
///
/// ## Values the slider cannot reach
///
/// A saved exposure beyond `ExposureControlScale.range` pins the thumb to the
/// end stop and shows its real value in orange, and it is not changed until
/// the user moves the slider. See `ExposureControlScale`.
///
/// Deliberately absent: tone curves, contrast, highlights, a histogram and
/// automatic exposure.
private struct ExposureControl: View {
    let documentState: DocumentState

    var body: some View {
        let exposure = documentState.exposureAdjustment
        let beyond = ExposureControlScale.isBeyondSlider(exposure)

        HStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { ExposureControlScale.sliderPosition(for: documentState.exposureAdjustment) },
                    set: { value in
                        if let requested = ExposureControlScale.adjustment(
                            forSliderValue: value, current: documentState.exposureAdjustment
                        ) {
                            documentState.setExposure(requested)
                        }
                    }
                ),
                in: ExposureControlScale.range
            ) {
                Text("Exposure")
            } minimumValueLabel: {
                Text("−4").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("+4").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 240)
            .help("Exposure compensation in stops, applied to linear light before display clipping")

            Text(exposure.signedDescription)
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
                .foregroundStyle(beyond ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .help(beyond
                    ? "The saved exposure is beyond the slider's ±4 EV; it is kept as saved"
                    : "The requested exposure")

            Button(action: documentState.resetExposure) {
                Label("Reset Exposure", systemImage: "arrow.counterclockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Return the exposure to 0 EV — the channel mix and orientation are unchanged")
            .accessibilityLabel("Reset exposure to zero")
            .disabled(exposure.isIdentity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Exposure \(exposure.signedDescription)")
        .disabled(!documentState.canAdjust)
    }
}


/// Says when a decision has not reached its sidecar.
///
/// Silent while everything is saved, because a durable edit is the ordinary
/// case and a permanent badge for it would be noise. Silent while a save is
/// merely **pending**, too, and that is a deliberate choice rather than an
/// omission: a save follows a render that normally takes well under a second,
/// so an indicator for it would flash on every rotation and say nothing a user
/// can act on. The pending state exists in the model, where correctness needs
/// it, not on screen, where it would only flicker.
///
/// What does appear is the state a user needs to know about: the image is
/// correct and the saved copy is not, so closing the file now would lose the
/// edit — for this photograph, or for one already left behind.
/// The export control: one button, a save panel, and what happened.
///
/// The view decides nothing about the export. It collects a destination and
/// calls `DocumentState.exportTIFF(to:)`; the snapshot, the rendering and the
/// file are the application layer's and the pipeline's. There is no quality
/// setting, no bit-depth chooser and no colour-space picker, because there is
/// exactly one export format in this version and offering options for
/// decisions that have already been made would be a lie about the pipeline.
///
/// Cancelling the panel does nothing at all: no task, no file, no error, and
/// no status to dismiss.
private struct ExportControl: View {
    let documentState: DocumentState

    var body: some View {
        HStack(spacing: 8) {
            Button("Export TIFF…", action: export)
                .buttonStyle(.bordered)
                .help("Render this photograph from the RAW file at full resolution "
                    + "and write a 16-bit sRGB TIFF")
                .accessibilityLabel("Export 16-bit TIFF")
                .disabled(!documentState.canExport)
            status
        }
    }

    @ViewBuilder
    private var status: some View {
        switch documentState.exportStatus {
        case .idle:
            EmptyView()
        case .exporting(let request, _):
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Exporting \(request.rawURL.lastPathComponent)…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .succeeded(let result):
            Button(action: documentState.acknowledgeExport) {
                Label(
                    "\(result.destination.lastPathComponent) — \(result.pixelWidth) × "
                        + "\(result.pixelHeight), 16 bit",
                    systemImage: "checkmark.circle"
                )
                .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Exported. Click to dismiss.")
        case .failed(let failure):
            Button(action: documentState.acknowledgeExport) {
                Label(failure.message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help(failure.failureReason ?? failure.message)
        }
    }

    private func export() {
        guard let suggestion = documentState.suggestedExportFilename else { return }
        let panel = NSSavePanel()
        panel.title = "Export 16-bit TIFF"
        panel.allowedContentTypes = [TIFFExporter.contentType]
        panel.nameFieldStringValue = suggestion
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        // The panel is also where overwriting is agreed to: it asks, and the
        // writer never overwrites anything the user did not choose here.
        guard panel.runModal() == .OK, let url = panel.url else { return }
        documentState.exportTIFF(to: url)
    }
}

private struct AdjustmentSaveStatus: View {
    let documentState: DocumentState

    var body: some View {
        if let failure = documentState.adjustmentSaveFailure {
            warning(
                "Adjustments not saved",
                detail: failure.failureReason ?? failure.localizedDescription
            )
        } else if let earlier = documentState.unsavedAdjustments.last {
            // A decision from a file the workspace has already left. Without
            // this it would exist only in the log, which is the definition of
            // losing it silently.
            warning(
                "\(earlier.url.lastPathComponent) not saved",
                detail: "The adjustment was not written: \(earlier.reasonDescription)."
            )
        }
    }

    private func warning(_ title: String, detail: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.orange)
        .font(.caption)
        .help(detail)
        .accessibilityLabel("\(title). \(detail)")
    }
}
