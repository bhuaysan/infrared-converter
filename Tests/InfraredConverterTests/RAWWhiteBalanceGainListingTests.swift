import Testing
import Foundation
@testable import InfraredConverter

/// What the workspace shows for the infrared white-balance gains: which colour
/// plane each multiplier belongs to, and what the sensor says that plane is.
///
/// The arithmetic is not tested here — it is `RAWWhiteBalanceEstimator`'s and
/// is covered by `RAWWhiteBalanceEstimatorTests`. What is tested is that the
/// numbers can be *read*: that every plane the layout produces is listed, that
/// the identity of each comes from the file's own `colorDescription` rather
/// than from an RGGB assumption, and that two independently balanced greens
/// stay two rows.
@Suite("White-balance gain listing")
struct RAWWhiteBalanceGainListingTests {

    private static let gains = RAWWhiteBalanceGains(
        plane0: 1, plane1: 2.143, plane2: 4.827, plane3: 2.097
    )

    // MARK: - Plane identity comes from the layout

    /// The reference camera's layout: four reachable planes, described `RGBG`,
    /// which is exactly the case a three-entry model would get wrong.
    @Test("An RGBG layout lists four planes, and both greens separately")
    func anRGBGLayoutListsBothGreens() throws {
        let listing = try RAWWhiteBalanceGainListing(
            gains: Self.gains, sensorColorLayout: BayerTestLayouts.rggb
        )

        #expect(listing.colorPlanes == [0, 1, 2, 3])
        #expect(listing.entries.map(\.colorDescriptionLetter) == ["R", "G", "B", "G"])
        #expect(listing.entries.map(\.channel) == [.red, .green, .blue, .green])
        #expect(listing.entries.map(\.gain) == [1, 2.143, 4.827, 2.097])

        // The two greens are two entries, addressed by their own planes, and
        // they carry the two different multipliers the estimator produced.
        let greens = listing.entries(for: .green)
        #expect(greens.map(\.colorPlane) == [1, 3])
        #expect(greens[0].gain != greens[1].gain)

        #expect(listing.entries.map(\.label) == ["P0 R", "P1 G", "P2 B", "P3 G"])
        #expect(listing.diagnosticDescription
            == "P0 R ×1.000  P1 G ×2.143  P2 B ×4.827  P3 G ×2.097")
    }

    /// The same gains against three other CFA phases. A listing that assumed
    /// RGGB would label all four of these identically; each is labelled by
    /// where its own planes sit.
    @Test("A non-RGGB phase is labelled by its own layout, not by RGGB")
    func nonRGGBPhasesAreLabelledByTheirLayout() throws {
        // Plane indices are the same four numbers whatever the phase — the
        // phase changes which sensor *position* holds which plane, not what
        // plane 2 is called. What must not happen is a listing that renames
        // the planes when the phase changes.
        for layout in [
            BayerTestLayouts.rggb,
            BayerTestLayouts.bggr,
            BayerTestLayouts.grbg,
            BayerTestLayouts.gbrg,
        ] {
            let listing = try RAWWhiteBalanceGainListing(
                gains: Self.gains, sensorColorLayout: layout
            )
            #expect(listing.entries.map(\.label) == ["P0 R", "P1 G", "P2 B", "P3 G"])
        }

        // And a layout whose description is a different permutation is read
        // from that description: plane 0 is blue here, and nothing overrides
        // it with "R".
        let described = BayerTestLayouts.layout(
            cell: [[0, 1], [3, 2]], colorDescription: "BGRG"
        )
        let listing = try RAWWhiteBalanceGainListing(
            gains: Self.gains, sensorColorLayout: described
        )
        #expect(listing.entries.map(\.colorDescriptionLetter) == ["B", "G", "R", "G"])
        #expect(listing.entries.map(\.channel) == [.blue, .green, .red, .green])
        #expect(listing.entries[0].label == "P0 B")
    }

    @Test("A three-plane layout lists three planes, not a fourth with gain 1")
    func aThreePlaneLayoutListsThree() throws {
        let listing = try RAWWhiteBalanceGainListing(
            gains: Self.gains, sensorColorLayout: BayerTestLayouts.rggbThreePlane
        )

        #expect(listing.colorPlanes == [0, 1, 2])
        #expect(listing.entries.map(\.label) == ["P0 R", "P1 G", "P2 B"])
        // Plane 3's slot exists in the gain model and is unused by this
        // layout. Showing it as "×1.000" would read as a measured plane that
        // needed no correction.
        #expect(listing.entries(for: .green).count == 1)
    }

    /// A letter that names no RGB channel keeps its letter and gets no
    /// channel, rather than being mapped onto the nearest one.
    @Test("A non-RGB filter letter is named, not reinterpreted")
    func aNonRGBLetterIsNotReinterpreted() throws {
        let emerald = BayerTestLayouts.layout(
            cell: [[0, 1], [3, 2]], colorDescription: "RGBE", colorCount: 4
        )
        let listing = try RAWWhiteBalanceGainListing(
            gains: Self.gains, sensorColorLayout: emerald
        )

        #expect(listing.entries.map(\.colorDescriptionLetter) == ["R", "G", "B", "E"])
        #expect(listing.entries.map(\.channel) == [.red, .green, .blue, nil])
        #expect(listing.entries[3].label == "P3 E")
    }

    /// A description too short to name a plane leaves the plane unnamed rather
    /// than reaching past the end of it.
    @Test("A plane the description does not name is listed without a letter")
    func anUnnamedPlaneKeepsItsIndex() throws {
        let short = BayerTestLayouts.layout(
            cell: [[0, 1], [3, 2]], colorDescription: "RGB"
        )
        let listing = try RAWWhiteBalanceGainListing(
            gains: Self.gains, sensorColorLayout: short
        )

        #expect(listing.entries.count == 4)
        #expect(listing.entries[3].colorDescriptionLetter == nil)
        #expect(listing.entries[3].channel == nil)
        #expect(listing.entries[3].label == "P3")
        #expect(listing.entries[3].gain == 2.097)
    }

    // MARK: - Layouts that have no colour planes

    /// The refusal is the estimator's own, and it is the same refusal that
    /// would have prevented these gains from existing. A listing does not
    /// invent an empty description for a sensor with no mosaic.
    @Test("A layout with no CFA planes is refused, with the estimator's reason")
    func aLayoutWithoutPlanesIsRefused() {
        for pattern in [
            RAWMetadata.SensorColorLayout.Pattern.foveon, .none, .unknown
        ] {
            let layout = RAWMetadata.SensorColorLayout(
                pattern: pattern,
                filters: 0,
                colorDescription: "RGB",
                colorCount: 3,
                sourceRawBitDepth: 12
            )
            #expect(throws: RAWProcessingError.self) {
                try RAWWhiteBalanceGainListing(
                    gains: Self.gains, sensorColorLayout: layout
                )
            }
        }
    }

    /// The set of planes described is the estimator's, by construction rather
    /// than by coincidence: both come from `colorPlanes(in:)`.
    @Test("The planes listed are the planes the estimator measures")
    func theListedPlanesAreTheMeasuredPlanes() throws {
        for layout in [
            BayerTestLayouts.rggb,
            BayerTestLayouts.bggr,
            BayerTestLayouts.grbg,
            BayerTestLayouts.gbrg,
            BayerTestLayouts.rggbThreePlane,
        ] {
            let listing = try RAWWhiteBalanceGainListing(
                gains: Self.gains, sensorColorLayout: layout
            )
            let measured = try RAWWhiteBalanceEstimator.colorPlanes(in: layout)
            #expect(listing.colorPlanes == measured)
        }
    }

    // MARK: - The preview carries the layout its gains are indexed by

    /// The provenance change this presentation needed: a rendered preview says
    /// which layout its gains belong to, read from the preparation's own
    /// metadata. Without it a view would have to find a layout somewhere else
    /// — a document, or a second decode — and label one file's gains with
    /// another file's planes.
    @Test("A rendered preview carries the layout, and its gains can be labelled")
    func aRenderedPreviewCarriesItsLayout() throws {
        let url = URL(fileURLWithPath: "/tmp/synthetic-gain-listing.orf")
        let decoder = WorkspaceStubDecoder(
            result: .success(RAWTestData.decodedRAW(url: url)),
            mosaic: .success(WorkspaceStubs.mosaic(url: url, width: 8, height: 6))
        )

        let preview = try WorkspacePreviewPipeline().render(
            decoding: url, using: decoder, adjustments: .none
        )

        #expect(preview.sensorColorLayout == RAWTestData.bayerLayout())

        let listing = try preview.whiteBalanceGainListing()
        #expect(listing.colorPlanes == [0, 1, 2, 3])
        #expect(listing.entries.map(\.label) == ["P0 R", "P1 G", "P2 B", "P3 G"])
        // The listed multipliers are the estimate's own, not a copy.
        #expect(
            listing.entries.map(\.gain)
                == [0, 1, 2, 3].map { preview.whiteBalanceGains.gain(forColorPlane: $0) }
        )
    }
}
