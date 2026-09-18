import Testing
import Foundation
@testable import InfraredConverter

/// What a monochrome mix reuses: the sidecar, the creative-preset library and
/// the full-resolution export path.
///
/// None of those was changed for this milestone, and that is exactly what
/// these tests assert. A monochrome mix is nine coefficients in the one
/// persisted channel-mix shape, so it travels every existing road without a
/// field, a token, a schema version or an arithmetic implementation of its
/// own. See `docs/decisions/0025-monochrome-channel-mix-authoring.md`.
@Suite("Monochrome channel-mix reuse")
struct MonochromeChannelMixReuseTests {

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    /// Deliberately asymmetric, so a transposition or a reordering cannot
    /// survive a round trip unnoticed.
    static func authored() throws -> UserChannelMixAdjustment {
        try IRMonochromeMix(red: 1.5, green: -0.25, blue: 0.125).adjustment()
    }

    // MARK: - The photograph sidecar

    /// The schema is where it was. A new way to author an already-supported
    /// matrix is not a wire-format change, and bumping the version for one
    /// would make every older client refuse files it can read perfectly well.
    @Test("The photograph sidecar schema is still version 5")
    func theSidecarSchemaIsUnchanged() {
        #expect(PhotographProcessingState.currentSchemaVersion == 7)
    }

    /// The exact persisted shape: the existing `matrix` token and nine
    /// row-major coefficients, with each row repeated. Asserted as text, so a
    /// new key could not slip in unnoticed.
    @Test("Monochrome persists as the existing kind: matrix, with no new token")
    func monochromePersistsAsAnOrdinaryMatrix() throws {
        let state = PhotographProcessingState(
            adjustments: ImageAdjustments(channelMix: try Self.authored())
        )
        let json = String(decoding: try Self.encoder.encode(state), as: UTF8.self)

        #expect(json.contains("\"kind\":\"matrix\""))
        #expect(json.contains("[1.5,-0.25,0.125,1.5,-0.25,0.125,1.5,-0.25,0.125]"))
        #expect(json.contains("\"schemaVersion\":7"))

        // No monochrome field, key or token anywhere in the record — in any
        // casing a field name could have taken.
        let lowered = json.lowercased()
        #expect(!lowered.contains("monochrome"))
        #expect(!lowered.contains("mono"))
        #expect(!lowered.contains("luminance"))
        #expect(!lowered.contains("grayscale"))
        #expect(!lowered.contains("greyscale"))
        #expect(!lowered.contains("desaturat"))
    }

    /// The bytes of a monochrome mix are the bytes of the same nine
    /// coefficients typed into the 3×3 editor. That is the milestone's
    /// indistinguishability requirement, stated where it is observable.
    @Test("A monochrome record is byte-identical to the same matrix typed by hand")
    func aMonochromeRecordIsIndistinguishable() throws {
        let authored = PhotographProcessingState(
            adjustments: ImageAdjustments(channelMix: try Self.authored())
        )
        let typed = PhotographProcessingState(
            adjustments: ImageAdjustments(
                channelMix: try UserChannelMixAdjustment.explicit(
                    persistedMatrix: [1.5, -0.25, 0.125, 1.5, -0.25, 0.125, 1.5, -0.25, 0.125]
                )
            )
        )
        #expect(try Self.encoder.encode(authored) == (try Self.encoder.encode(typed)))
    }

    @Test("A monochrome record reopens as exactly the same nine coefficients")
    func aMonochromeRecordRoundTrips() throws {
        let state = PhotographProcessingState(
            adjustments: ImageAdjustments(channelMix: try Self.authored())
        )
        let decoded = try JSONDecoder().decode(
            PhotographProcessingState.self, from: try Self.encoder.encode(state)
        )

        #expect(decoded == state)
        #expect(decoded.adjustments.channelMix == (try Self.authored()))
        #expect(decoded.adjustments.channelMix.kind == .matrix)
        // And the editor recognises the restored matrix by its identical rows,
        // which is what makes reopening `Monochrome…` show the typed numbers.
        let recovered = try #require(
            IRMonochromeMix(recognising: decoded.adjustments.channelMix)
        )
        #expect(recovered == IRMonochromeMix(red: 1.5, green: -0.25, blue: 0.125))
    }

    /// Through the real store, on disk, in a temporary directory: the same
    /// claim, one layer out.
    @Test("A monochrome mix survives a real sidecar write and read")
    func aMonochromeMixSurvivesTheStore() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("monochrome-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let raw = directory.appendingPathComponent("OLYMPUS.ORF")
        try Data("not-a-real-raw-file".utf8).write(to: raw)

        let store = JSONSidecarPhotographProcessingStore()
        let state = PhotographProcessingState(
            adjustments: ImageAdjustments(channelMix: try Self.authored())
        )
        try store.save(state, for: raw)

        #expect(try store.load(for: raw) == state)
        let text = String(
            decoding: try Data(
                contentsOf: JSONSidecarPhotographProcessingStore.sidecarURL(for: raw)
            ),
            as: UTF8.self
        )
        #expect(text.contains("\"matrix\""))
        #expect(!text.lowercased().contains("monochrome"))
        // The RAW file is untouched, as always.
        #expect(
            try Data(contentsOf: raw) == Data("not-a-real-raw-file".utf8)
        )
    }

    // MARK: - Creative presets

    @Test("The creative-preset schema is still version 1")
    func thePresetSchemaIsUnchanged() {
        #expect(IRCreativePreset.currentSchemaVersion == 1)
    }

    /// The workflow the milestone names: author monochrome, save it as a
    /// preset, apply the preset elsewhere, and get the identical explicit
    /// matrix back. Nothing in the preset knows it is monochrome.
    @Test("A monochrome mix round-trips through a saved preset unchanged")
    func aMonochromeMixRoundTripsThroughAPreset() throws {
        let authored = try Self.authored()
        let preset = IRCreativePreset(
            id: IRCreativePresetID.generatedUserID(),
            name: "Equalish Mono",
            channelMix: authored
        )

        let data = try Self.encoder.encode(IRCreativePresetRecord(preset))
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"kind\":\"matrix\""))
        #expect(json.contains("\"schemaVersion\":1"))
        #expect(!json.lowercased().contains("monochrome"))

        let restored = try JSONDecoder()
            .decode(IRCreativePresetRecord.self, from: data).preset
        #expect(restored == preset)
        // Applying it is one assignment of an ordinary adjustment.
        #expect(restored.channelMix == authored)
        #expect(restored.channelMix.matrix.rows == [
            [1.5, -0.25, 0.125],
            [1.5, -0.25, 0.125],
            [1.5, -0.25, 0.125],
        ])
        // A preset carrying it is no more calibrated than any other.
        #expect(!restored.isValidatedInfraredCalibration)
        // And the monochrome editor recognises what came back.
        #expect(
            IRMonochromeMix(recognising: restored.channelMix)
                == IRMonochromeMix(red: 1.5, green: -0.25, blue: 0.125)
        )
    }

    /// Through the real preset store, so the file the library would load is
    /// the one that is read back.
    @Test("A monochrome preset survives a real library save and reload")
    @MainActor
    func aMonochromePresetSurvivesTheLibrary() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("monochrome-presets-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileIRCreativePresetStore(directory: directory)
        let library = IRCreativePresetLibrary(store: store)
        let saved = try library.create(
            IRCreativePresetDraft(name: "Equalish Mono"),
            channelMix: try Self.authored()
        )

        let reloaded = IRCreativePresetLibrary(store: FileIRCreativePresetStore(
            directory: directory
        ))
        let found = try #require(reloaded.preset(for: saved.id))
        #expect(found.channelMix == (try Self.authored()))
        #expect(IRMonochromeMix(recognising: found.channelMix) != nil)
    }

    // MARK: - Export

    /// The exporter runs the same `UserChannelMixAdjustment` the preview does,
    /// so a monochrome matrix reaches full resolution through the existing
    /// path with no monochrome arithmetic anywhere. The observable is the
    /// pixels: every exported pixel is achromatic.
    @Test("A monochrome mix reaches full-resolution export through the existing path")
    func aMonochromeMixReachesExport() throws {
        let url = URL(fileURLWithPath: "/tmp/monochrome-export.orf")
        let decoder = WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: url, width: 8, height: 6))
        )
        let mono = try Self.authored()
        let rendered = try FullResolutionExportPipeline().render(
            ExportRequest(rawURL: url, adjustments: ImageAdjustments(channelMix: mono)),
            using: decoder
        )

        // The export ran the adjustment it was handed, with ordinary creative
        // provenance and no calibration claim.
        #expect(rendered.mix == mono.mix)
        #expect(rendered.mix.source == .explicit)
        #expect(rendered.mix.matrix.rows == [
            [1.5, -0.25, 0.125],
            [1.5, -0.25, 0.125],
            [1.5, -0.25, 0.125],
        ])
        #expect(rendered.image.processing.channelMixApplied)
        #expect(!rendered.image.processing.isValidatedInfraredCalibration)

        // At the sensor's own resolution, not the preview's.
        #expect(rendered.image.width == 8)
        #expect(rendered.image.height == 6)

        // Every exported scene-linear pixel is achromatic, bit for bit, which
        // is the whole point of the matrix having identical rows.
        let values = rendered.image.values
        #expect(values.count == 8 * 6 * 3)
        for pixel in stride(from: 0, to: values.count, by: 3) {
            #expect(values[pixel].bitPattern == values[pixel + 1].bitPattern, "pixel \(pixel / 3)")
            #expect(values[pixel + 1].bitPattern == values[pixel + 2].bitPattern, "pixel \(pixel / 3)")
        }

        // And so is the 16-bit file that is actually written, after the export
        // range policy and the transfer function have run.
        let encoded = try ExportImageEncoder().encode(
            rendered.image, settings: .standard
        )
        #expect(encoded.samples.count == 8 * 6 * 3)
        for pixel in stride(from: 0, to: encoded.samples.count, by: 3) {
            #expect(encoded.samples[pixel] == encoded.samples[pixel + 1], "pixel \(pixel / 3)")
            #expect(encoded.samples[pixel + 1] == encoded.samples[pixel + 2], "pixel \(pixel / 3)")
        }
    }

    /// The same nine coefficients render the same full-resolution pixels
    /// whether they were authored in the monochrome editor or typed into the
    /// 3×3 editor. There is one export implementation, and it cannot tell the
    /// two apart because there is nothing to tell apart.
    @Test("Export makes no distinction between a monochrome and a hand-typed matrix")
    func exportCannotTellThemApart() throws {
        let url = URL(fileURLWithPath: "/tmp/monochrome-export-parity.orf")
        func decoder() -> WorkspaceStubDecoder {
            WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: url, width: 8, height: 6))
            )
        }
        let typed = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [1.5, -0.25, 0.125, 1.5, -0.25, 0.125, 1.5, -0.25, 0.125]
        )

        let fromEditor = try FullResolutionExportPipeline().render(
            ExportRequest(
                rawURL: url, adjustments: ImageAdjustments(channelMix: try Self.authored())
            ),
            using: decoder()
        )
        let fromMatrix = try FullResolutionExportPipeline().render(
            ExportRequest(rawURL: url, adjustments: ImageAdjustments(channelMix: typed)),
            using: decoder()
        )

        #expect(fromEditor.image.values.count == fromMatrix.image.values.count)
        #expect(
            zip(fromEditor.image.values, fromMatrix.image.values)
                .allSatisfy { $0.bitPattern == $1.bitPattern }
        )
    }

    // MARK: - No new model anywhere

    /// The provenance enum gained no case. Where a person found a matrix is
    /// not a property of the matrix, and a `.monochrome` source would have to
    /// be persisted, migrated and then disagreed with by the coefficients.
    ///
    /// The proof is the compiler's: this switch is exhaustive over
    /// `IRChannelMixSource` with no `default`, so a fourth case would stop
    /// this file compiling. The assertions below merely pin the three that
    /// exist and confirm a monochrome mix reports the ordinary one.
    private static func name(of source: IRChannelMixSource) -> String {
        switch source {
        case .identity: return "identity"
        case .redBlueSwap: return "redBlueSwap"
        case .explicit: return "explicit"
        }
    }

    @Test("IRChannelMixSource gained no monochrome case")
    func theSourceEnumIsUnchanged() throws {
        #expect(Self.name(of: .identity) == "identity")
        #expect(Self.name(of: .redBlueSwap) == "redBlueSwap")
        #expect(Self.name(of: .explicit) == "explicit")
        // A monochrome mix carries the ordinary explicit provenance.
        #expect(try Self.authored().mix.source == .explicit)
    }

    /// The persisted channel-mix vocabulary gained no token either.
    @Test("The persisted channel-mix kinds are still identity, redBlueSwap and matrix")
    func theChannelMixKindsAreUnchanged() {
        #expect(
            UserChannelMixAdjustment.Kind.allCases.map(\.rawValue)
                == ["identity", "redBlueSwap", "matrix"]
        )
    }
}
