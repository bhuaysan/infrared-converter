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
                RAWPreviewView(preview: loaded.preview)
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
                    Text(diagnostic.description)
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

/// Shows the decoder's display-only preview.
private struct RAWPreviewView: View {
    let preview: CGImage?

    var body: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(12)
            } else {
                Text("No preview available")
                    .foregroundStyle(.secondary)
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
                    row("Preview", "\(loaded.decoded.image.width) × \(loaded.decoded.image.height)")
                }

                section("Sensor") {
                    row("Layout", layoutDescription)
                    row("Colour planes", loaded.metadata.sensor.colorDescription)
                    row("Raw bit depth", loaded.metadata.sensor.bitsPerRawSample.map { "\($0) bit" })
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

                section("Decoder") {
                    let processing = loaded.decoded.processing
                    row("Decoder", processing.decoderIdentifier)
                    row("Pixel format", "\(loaded.decoded.image.channelCount) × "
                        + "\(loaded.decoded.image.bitsPerChannel) bit, interleaved RGB")
                    row("Encoding", loaded.decoded.image.encoding == .linear ? "Linear" : "Gamma encoded")
                    row("Colour", loaded.decoded.image.colorSpace == .cameraNative
                        ? "Camera native (no matrix)" : "sRGB")
                    row("White balance", processing.whiteBalanceIsUnity ? "Unity (none applied)" : "Applied")
                    row("Demosaic", processing.demosaic.map(Self.demosaicDescription) ?? "None (half size)")
                }
            }
            .padding(16)
        }
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
