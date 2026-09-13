import Testing
import Foundation
@testable import InfraredConverter

/// Exporting as the workspace does it: which state an export takes, what it
/// leaves alone, and what happens when a user does something else while one
/// runs.
///
/// Serialised for the reason the other workspace suites are: some of these
/// hold a real render or a real export at a gate.
@Suite("Workspace export", .serialized)
@MainActor
struct WorkspaceExportTests {

    nonisolated static let url = URL(fileURLWithPath: "/tmp/workspace-export.orf")
    nonisolated static let otherURL = URL(fileURLWithPath: "/tmp/workspace-export-other.orf")
    nonisolated static let destination = URL(fileURLWithPath: "/tmp/workspace-export.tif")
    nonisolated static let otherDestination =
        URL(fileURLWithPath: "/tmp/workspace-export-other.tif")

    nonisolated static func ev(_ value: Double) throws -> UserExposureAdjustment {
        try UserExposureAdjustment(ev: value)
    }

    static func state(
        store: StubImageAdjustmentStore = StubImageAdjustmentStore(),
        render: @escaping DocumentState.PreviewRender = DocumentState.pipelineRender,
        export: RecordingExport = RecordingExport(),
        decoder: (any RAWDecoder)? = nil
    ) -> DocumentState {
        DocumentState(
            decoder: decoder ?? WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: url))
            ),
            store: store,
            render: render,
            exportRun: export.run
        )
    }

    static func multiFileState(
        store: StubImageAdjustmentStore = StubImageAdjustmentStore(),
        render: @escaping DocumentState.PreviewRender = DocumentState.pipelineRender,
        export: RecordingExport = RecordingExport()
    ) -> DocumentState {
        DocumentState(
            decoder: MultiFileStubDecoder(
                mosaics: [
                    url: WorkspaceStubs.mosaic(url: url),
                    otherURL: WorkspaceStubs.mosaic(url: otherURL, width: 10, height: 8)
                ]
            ),
            store: store,
            render: render,
            exportRun: export.run
        )
    }

    static func waitUntilSettled(_ state: DocumentState) async throws {
        for _ in 0..<600 {
            if case .decoding = state.status {
                try await Task.sleep(nanoseconds: 5_000_000)
            } else {
                return
            }
        }
        Issue.record("The open never settled")
    }

    static func waitUntil(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Never became true: \(description)")
    }

    // MARK: - What can be exported

    @Test("Nothing can be exported before a file is open")
    func nothingCanBeExportedBeforeAFileIsOpen() {
        let state = Self.state()
        #expect(state.exportRequest == nil)
        #expect(!state.canExport)
        #expect(state.suggestedExportFilename == nil)
        #expect(!state.isExporting)
    }

    @Test("An open photograph can be exported, under a name derived from the RAW")
    func anOpenPhotographCanBeExported() async throws {
        let state = Self.state()
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        #expect(state.canExport)
        #expect(state.exportRequest?.rawURL == Self.url)
        #expect(state.exportRequest?.adjustments == ImageAdjustments.none)
        #expect(state.suggestedExportFilename == "workspace-export.tif")
    }

    @Test("A document the owned pipeline could not render is not exportable")
    func anUnrenderableDocumentIsNotExportable() async throws {
        // The owned render refuses; the LibRaw reference still decodes, so the
        // file opens — and must not become exportable because of it.
        let state = Self.state(
            render: { _, _, _ in throw RecordingRender.Refused() }
        )
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        #expect(!state.canAdjust)
        #expect(state.exportRequest == nil)
        #expect(!state.canExport)
    }

    // MARK: - Which state is exported

    @Test("An export takes the current canonical state, not the last durable one")
    func anExportTakesTheCurrentCanonicalState() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        // The +1 EV render is held, so the document's durable state stays at
        // 0 EV while its requested state is +1 EV.
        let gate = GatedRender(log: log, holds: { $0.exposure.ev == 1 })
        let export = RecordingExport()
        let state = Self.state(store: store, render: gate.render, export: export)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)
        #expect(state.adjustmentPersistence.isDurable)

        state.setExposure(try Self.ev(1))
        try await gate.waitForGatedRenderToStart()

        // Exactly the situation this has to get right: the preview on screen
        // is 0 EV, the sidecar holds 0 EV, and the user has asked for +1 EV.
        #expect(!state.adjustmentPersistence.isDurable)
        #expect(store.saved(for: Self.url)?.exposure.ev ?? 0 == 0)
        #expect(state.exposureAdjustment.ev == 1)

        state.exportTIFF(to: Self.destination)
        try await Self.waitUntil("the export starts") { export.startedCount == 1 }
        #expect(export.started[0].request.adjustments.exposure.ev == 1)
        #expect(export.started[0].destination == Self.destination)

        gate.releaseOneRender()
        try await Self.waitUntil("the held render lands") {
            state.adjustmentPersistence.isDurable
        }
    }

    @Test("A failed save does not change which state is exported")
    func aFailedSaveDoesNotChangeWhatIsExported() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        store.refuseSaves(
            with: .cannotWrite(
                sidecar: JSONSidecarImageAdjustmentStore.sidecarURL(for: Self.url),
                underlying: CocoaError(.fileWriteNoPermission)
            )
        )
        let export = RecordingExport()
        let state = Self.state(store: store, export: export)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setExposure(try Self.ev(1))
        try await Self.waitUntil("the save fails") {
            if case .saveFailed = state.adjustmentPersistence { return true }
            return false
        }

        // Persistence failed. The editing state did not.
        state.exportTIFF(to: Self.destination)
        try await Self.waitUntil("the export finishes") { !state.isExporting }
        #expect(export.started.count == 1)
        #expect(export.started[0].request.adjustments.exposure.ev == 1)
        if case .succeeded(let result) = state.exportStatus {
            #expect(result.adjustments.exposure.ev == 1)
        } else {
            Issue.record("Expected a successful export, got \(state.exportStatus)")
        }
        // And the export did not quietly fix the persistence failure.
        if case .saveFailed = state.adjustmentPersistence {} else {
            Issue.record("The save failure should still stand, got \(state.adjustmentPersistence)")
        }
    }

    @Test("Exporting writes no sidecar")
    func exportingWritesNoSidecar() async throws {
        let log = WorkspaceEventLog()
        let store = StubImageAdjustmentStore(log: log)
        let state = Self.state(store: store)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)
        let writesBeforeExport = store.writes.count

        state.exportTIFF(to: Self.destination)
        try await Self.waitUntil("the export finishes") { !state.isExporting }

        #expect(store.writes.count == writesBeforeExport)
        // Nor did it make the document look edited.
        #expect(state.adjustmentPersistence.isDurable)
    }

    @Test("The complete adjustment state travels together, never field by field")
    func theCompleteStateTravelsTogether() async throws {
        let export = RecordingExport()
        let state = Self.state(export: export)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.setChannelMix(.redBlueSwap)
        state.rotateOrientationRight()
        state.setExposure(try Self.ev(-1.5))
        try await Self.waitUntil("the newest state lands") {
            state.adjustmentPersistence.isDurable
        }

        state.exportTIFF(to: Self.destination)
        try await Self.waitUntil("the export starts") { export.startedCount == 1 }
        let request = try #require(export.started.first?.request)
        #expect(request.adjustments.channelMix == .redBlueSwap)
        #expect(request.adjustments.orientation == .quarterTurnRight)
        #expect(request.adjustments.exposure.ev == -1.5)
        #expect(request.rawURL == Self.url)
    }

    // MARK: - One at a time

    @Test("A second export while one is running is refused, not queued")
    func aSecondExportIsRefused() async throws {
        let export = RecordingExport(holds: { _ in true })
        let state = Self.state(export: export)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.exportTIFF(to: Self.destination)
        try await export.waitForGatedExportToStart()
        #expect(state.isExporting)
        #expect(!state.canExport)

        state.exportTIFF(to: Self.otherDestination)
        state.exportTIFF(to: Self.otherDestination)
        #expect(export.startedCount == 1)

        export.releaseOneExport()
        try await Self.waitUntil("the export finishes") { !state.isExporting }
        #expect(state.canExport)
        #expect(export.startedCount == 1)
    }

    @Test("A finished export can be acknowledged, and a running one cannot")
    func afinishedExportCanBeAcknowledged() async throws {
        let export = RecordingExport(holds: { _ in true })
        let state = Self.state(export: export)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.exportTIFF(to: Self.destination)
        try await export.waitForGatedExportToStart()
        state.acknowledgeExport()
        #expect(state.isExporting)

        export.releaseOneExport()
        try await Self.waitUntil("the export finishes") { !state.isExporting }
        state.acknowledgeExport()
        if case .idle = state.exportStatus {} else {
            Issue.record("Expected idle, got \(state.exportStatus)")
        }
    }

    // MARK: - Leaving the photograph

    @Test("Opening another file leaves a running export bound to the first")
    func openingAnotherFileLeavesTheExportAlone() async throws {
        let export = RecordingExport(holds: { $0.rawURL == Self.url })
        let state = Self.multiFileState(export: export)

        state.open(Self.url)
        try await Self.waitUntilSettled(state)
        state.setChannelMix(.redBlueSwap)
        try await Self.waitUntil("the mix lands") { state.adjustmentPersistence.isDurable }

        state.exportTIFF(to: Self.destination)
        try await export.waitForGatedExportToStart()

        // The user moves on while the export is still running.
        state.open(Self.otherURL)
        try await Self.waitUntilSettled(state)
        #expect(state.selectedFileURL == Self.otherURL)
        #expect(state.channelMixAdjustment == .identity)
        #expect(state.isExporting)

        export.releaseOneExport()
        try await Self.waitUntil("the export finishes") { !state.isExporting }

        // It exported the first photograph, with the first photograph's
        // adjustments, to the destination the user chose for it.
        guard case .succeeded(let result) = state.exportStatus else {
            Issue.record("Expected a successful export, got \(state.exportStatus)")
            return
        }
        #expect(result.sourceURL == Self.url)
        #expect(result.destination == Self.destination)
        #expect(result.adjustments.channelMix == .redBlueSwap)
        #expect(export.started.count == 1)
        #expect(export.started[0].request.rawURL == Self.url)

        // And the second photograph is unaffected: its own state is neutral
        // and its own export would be its own.
        #expect(state.exportRequest?.rawURL == Self.otherURL)
        #expect(state.exportRequest?.adjustments == ImageAdjustments.none)
    }

    @Test("Changing an adjustment while an export runs does not change that export")
    func changingAnAdjustmentDoesNotChangeARunningExport() async throws {
        let export = RecordingExport(holds: { _ in true })
        let state = Self.state(export: export)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.exportTIFF(to: Self.destination)
        try await export.waitForGatedExportToStart()

        state.setExposure(try Self.ev(2))
        state.setChannelMix(.redBlueSwap)

        export.releaseOneExport()
        try await Self.waitUntil("the export finishes") { !state.isExporting }

        guard case .succeeded(let result) = state.exportStatus else {
            Issue.record("Expected a successful export, got \(state.exportStatus)")
            return
        }
        #expect(result.adjustments == .none)
        // The next export would take the new state.
        try await Self.waitUntil("the new state lands") {
            state.adjustmentPersistence.isDurable
        }
        #expect(state.exportRequest?.adjustments.exposure.ev == 2)
        #expect(state.exportRequest?.adjustments.channelMix == .redBlueSwap)
    }

    // MARK: - Failure

    @Test("A failed export is reported with its typed error and changes nothing else")
    func aFailedExportIsReported() async throws {
        let failure = FullResolutionExportError.writingFailed(
            underlying: .encodingFailed(url: Self.destination, reason: "synthetic")
        )
        let export = RecordingExport(failing: { _ in failure })
        let state = Self.state(export: export)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.exportTIFF(to: Self.destination)
        try await Self.waitUntil("the export finishes") { !state.isExporting }

        guard case .failed(let reported) = state.exportStatus else {
            Issue.record("Expected a failed export, got \(state.exportStatus)")
            return
        }
        #expect(reported.destination == Self.destination)
        #expect(reported.request.rawURL == Self.url)
        #expect(!reported.message.isEmpty)
        guard case .writingFailed = try #require(reported.exportError) else {
            Issue.record("The typed error should have survived")
            return
        }
        // The document is untouched: still open, still adjustable, still
        // durable. A file that could not be written is not an editing failure.
        #expect(state.canAdjust)
        #expect(state.adjustmentPersistence.isDurable)
        #expect(state.canExport)
    }

    @Test("A cancelled export is not reported as a failure")
    func aCancelledExportIsNotAFailure() async throws {
        let export = RecordingExport(failing: { _ in CancellationError() })
        let state = Self.state(export: export)
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        state.exportTIFF(to: Self.destination)
        try await Self.waitUntil("the export finishes") { !state.isExporting }

        if case .idle = state.exportStatus {} else {
            Issue.record("Expected idle after cancellation, got \(state.exportStatus)")
        }
        #expect(state.canExport)
    }

    // MARK: - The real thing, end to end

    @Test("The workspace's own export path writes a real file")
    func theRealExportPathWritesAFile() async throws {
        // No export stub: `DocumentState` runs the full-resolution pipeline
        // and the TIFF writer, exactly as the application does.
        let state = DocumentState(
            decoder: WorkspaceStubDecoder(
                result: .success(RAWTestData.decodedRAW(url: Self.url)),
                mosaic: .success(WorkspaceStubs.mosaic(url: Self.url, width: 12, height: 8))
            ),
            store: StubImageAdjustmentStore(),
            previewPolicy: PreviewResolutionPolicy(maximumLongestEdge: 4)
        )
        state.open(Self.url)
        try await Self.waitUntilSettled(state)

        // The workspace is looking at a 4-pixel-wide preview…
        let preview = try #require({ () -> WorkspacePreview? in
            guard case .decoded(let loaded) = state.status,
                  case .rendered(let rendered) = loaded.owned else { return nil }
            return rendered
        }())
        #expect(preview.pixelWidth == 4)
        #expect(preview.resolution.isReduced)

        state.rotateOrientationRight()
        try await Self.waitUntil("the rotation lands") {
            state.adjustmentPersistence.isDurable
        }

        // …and the export is 12 × 8, turned, from the RAW file.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("infrared-workspace-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("real.tif")
        state.exportTIFF(to: destination)
        try await Self.waitUntil("the export finishes") { !state.isExporting }

        guard case .succeeded(let result) = state.exportStatus else {
            Issue.record("Expected a successful export, got \(state.exportStatus)")
            return
        }
        #expect(result.destination == destination)
        #expect(result.pixelWidth == 8)
        #expect(result.pixelHeight == 12)
        #expect(result.adjustments.orientation == .quarterTurnRight)

        let read = try TIFFPixelReader(contentsOf: destination)
        #expect(read.width == 8)
        #expect(read.height == 12)
        #expect(read.bitsPerComponent == 16)
        #expect(read.declaredOrientation == 1)
        // The acceptance test of this milestone, in miniature: a 4-pixel
        // preview and a 12-pixel export of the same RAW file and the same
        // adjustments, the export derived from the file rather than from the
        // preview.
        #expect(preview.pixelWidth * 3 == read.height)
    }
}
