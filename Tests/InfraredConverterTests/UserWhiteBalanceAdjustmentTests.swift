import Testing
import Foundation
@testable import InfraredConverter

/// The user's white-balance decision: what it means, how it becomes samples,
/// and what it refuses.
@Suite("UserWhiteBalanceAdjustment")
struct UserWhiteBalanceAdjustmentTests {

    // MARK: - The default is the historical behaviour, exactly

    /// The compatibility claim this whole milestone rests on. Before the white
    /// balance was adjustable, the pipeline measured a centred, even-sided
    /// square — `max(2, (shorter / 16) & ~1)` — and every version 1, 2 and 3
    /// sidecar was saved against that rendering.
    ///
    /// `.defaultNeutralPatch` has to resolve to the identical region, on every
    /// geometry, or those sidecars reopen looking different from the day they
    /// were written.
    @Test(
        "The default case resolves to exactly the historical centred patch",
        arguments: [
            (4056, 3040), (2028, 1520), (100, 100), (37, 41), (4, 4), (2, 3),
            (1, 1), (5000, 1), (3040, 4056),
        ]
    )
    func theDefaultIsTheHistoricalPatch(width: Int, height: Int) throws {
        // The historical rule, written out here rather than called, so this
        // test would fail if `defaultRegion` were ever quietly changed.
        let shorter = min(width, height)
        let side = max(2, (shorter / 16) & ~1)
        let historical = RAWActiveAreaRegion(
            originRow: max(0, (height - side) / 2),
            originColumn: max(0, (width - side) / 2),
            width: min(side, width),
            height: min(side, height)
        )

        #expect(
            UserWhiteBalanceAdjustment.defaultRegion(width: width, height: height)
                == historical
        )
        #expect(
            try UserWhiteBalanceAdjustment.defaultNeutralPatch.resolvedRegion(
                activeAreaWidth: width, activeAreaHeight: height
            ) == historical
        )
    }

    @Test("The E-PL3's active area still gets a 190-sample square in the middle")
    func theReferenceGeometryIsUnchanged() throws {
        let region = try UserWhiteBalanceAdjustment.defaultNeutralPatch.resolvedRegion(
            activeAreaWidth: 4056, activeAreaHeight: 3040
        )
        #expect(region.width == 190)
        #expect(region.height == 190)
        #expect(region.originRow == 1425)
        #expect(region.originColumn == 1933)
        #expect(region.sampleCount == 36_100)
    }

    /// `.defaultNeutralPatch` is a default, not an identity: it says the user
    /// did not choose, and nothing about what the gains come out as.
    @Test("The default is a decision about choosing, not about gains")
    func theDefaultIsNotAnIdentity() throws {
        #expect(UserWhiteBalanceAdjustment.defaultNeutralPatch.isDefault)
        #expect(UserWhiteBalanceAdjustment.initial == .defaultNeutralPatch)
        #expect(UserWhiteBalanceAdjustment.defaultNeutralPatch.selectedRegion == nil)

        let picked = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.1, originY: 0.1, width: 0.1, height: 0.1
            )
        )
        #expect(!picked.isDefault)
        #expect(picked.selectedRegion != nil)

        // Nothing on this type claims the gains are anything, and the
        // diagnostic wording says in as many words that this is not an
        // automatic white balance.
        #expect(
            UserWhiteBalanceAdjustment.defaultNeutralPatch.diagnosticDescription
                .contains("not an automatic white balance")
        )
    }

    // MARK: - Resolving a picked region

    @Test("A picked region resolves to the samples it names")
    func aPickedRegionResolves() throws {
        let adjustment = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.25, originY: 0.5, width: 0.125, height: 0.25
            )
        )
        let region = try adjustment.resolvedRegion(
            activeAreaWidth: 800, activeAreaHeight: 400
        )
        #expect(region.originColumn == 200)
        #expect(region.originRow == 200)
        #expect(region.width == 100)
        #expect(region.height == 100)
    }

    /// The corners, which are where an off-by-one would hide.
    @Test("The exact corners and the centre resolve where they should")
    func cornersAndCentreResolve() throws {
        let width = 1000, height = 600

        func resolve(
            _ x: Double, _ y: Double, _ w: Double, _ h: Double
        ) throws -> RAWActiveAreaRegion {
            try UserWhiteBalanceAdjustment.neutralPatch(
                try NormalizedActiveAreaRegion(
                    originX: x, originY: y, width: w, height: h
                )
            ).resolvedRegion(activeAreaWidth: width, activeAreaHeight: height)
        }

        let topLeft = try resolve(0, 0, 0.1, 0.1)
        #expect(topLeft.originColumn == 0)
        #expect(topLeft.originRow == 0)

        // The far corner: the origin is shifted back so the region ends
        // exactly at the edge rather than one sample past it.
        let bottomRight = try resolve(0.9, 0.9, 0.1, 0.1)
        #expect(bottomRight.originColumn + bottomRight.width == width)
        #expect(bottomRight.originRow + bottomRight.height == height)

        let centre = try resolve(0.45, 0.45, 0.1, 0.1)
        #expect(centre.originColumn == 450)
        #expect(centre.originRow == 270)
    }

    /// The CFA-alignment rule, which is what makes the estimator able to
    /// measure every plane: extents round **down** to even, with a floor of
    /// two.
    @Test(
        "Extents are even and at least two samples, whatever was asked for",
        arguments: [1001, 1000, 999, 37, 8]
    )
    func extentsAreEvenAndAtLeastTwo(dimension: Int) throws {
        // A spread of fractions, including ones that land on odd sample
        // counts and ones far below a single sample.
        for fraction in [0.0001, 0.003, 0.01, 0.1, 0.3331, 0.5, 0.999] {
            let adjustment = UserWhiteBalanceAdjustment.neutralPatch(
                try NormalizedActiveAreaRegion(
                    originX: 0, originY: 0, width: fraction, height: fraction
                )
            )
            let region = try adjustment.resolvedRegion(
                activeAreaWidth: dimension, activeAreaHeight: dimension
            )
            #expect(region.width % 2 == 0)
            #expect(region.height % 2 == 0)
            #expect(region.width >= UserWhiteBalanceAdjustment.minimumPatchExtent)
            #expect(region.height >= UserWhiteBalanceAdjustment.minimumPatchExtent)
            // And it always fits, so the estimator never sees an invalid one.
            try region.validate(inWidth: dimension, height: dimension)
        }
    }

    /// Odd source dimensions are where a rounding rule that looked symmetric
    /// stops being one.
    @Test(
        "A resolved region always validates against its own active area",
        arguments: [
            (4056, 3040), (1001, 777), (33, 2), (2, 2), (17, 4096),
        ]
    )
    func everyResolvedRegionValidates(width: Int, height: Int) throws {
        let fractions: [(Double, Double, Double, Double)] = [
            (0, 0, 1, 1), (0.5, 0.5, 0.5, 0.5), (0, 0.5, 0.02, 0.02),
            (0.98, 0.98, 0.02, 0.02), (0.33, 0.67, 0.11, 0.29),
        ]
        for (x, y, w, h) in fractions {
            let adjustment = UserWhiteBalanceAdjustment.neutralPatch(
                try NormalizedActiveAreaRegion(
                    originX: x, originY: y, width: w, height: h
                )
            )
            let region = try adjustment.resolvedRegion(
                activeAreaWidth: width, activeAreaHeight: height
            )
            try region.validate(inWidth: width, height: height)
        }
    }

    @Test("The conversion is deterministic")
    func theConversionIsDeterministic() throws {
        let adjustment = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.317, originY: 0.628, width: 0.041, height: 0.073
            )
        )
        let first = try adjustment.resolvedRegion(
            activeAreaWidth: 4056, activeAreaHeight: 3040
        )
        for _ in 0..<8 {
            #expect(
                try adjustment.resolvedRegion(
                    activeAreaWidth: 4056, activeAreaHeight: 3040
                ) == first
            )
        }
    }

    @Test("An unusable active area is refused")
    func anUnusableActiveAreaIsRefused() throws {
        for adjustment: UserWhiteBalanceAdjustment in [
            .defaultNeutralPatch, .neutralPatch(.full),
        ] {
            for (width, height) in [(0, 10), (10, 0), (-4, 4)] {
                #expect(throws: RAWProcessingError.self) {
                    try adjustment.resolvedRegion(
                        activeAreaWidth: width, activeAreaHeight: height
                    )
                }
            }
        }
    }

    /// A **picked** region on a frame too narrow to hold a whole CFA cell is
    /// refused rather than squeezed into one that does not exist.
    @Test("A picked region on a frame narrower than a CFA cell is refused")
    func aPickedRegionTooLargeForTheFrameIsRefused() {
        #expect(throws: RAWProcessingError.self) {
            try UserWhiteBalanceAdjustment.neutralPatch(.full)
                .resolvedRegion(activeAreaWidth: 1, activeAreaHeight: 40)
        }
    }

    /// The default case deliberately does **not** refuse there. It goes
    /// through the historical `defaultRegion`, which clamps its side to the
    /// image, and preserving that exactly is the reason the default is its own
    /// case. The estimator's refusal to invent a gain for an unmeasured plane
    /// is what catches such a frame.
    @Test("The default case keeps the historical clamp on a tiny frame")
    func theDefaultKeepsTheHistoricalClampOnATinyFrame() throws {
        let region = try UserWhiteBalanceAdjustment.defaultNeutralPatch.resolvedRegion(
            activeAreaWidth: 1, activeAreaHeight: 40
        )
        #expect(region.width == 1)
        #expect(region == UserWhiteBalanceAdjustment.defaultRegion(width: 1, height: 40))
        try region.validate(inWidth: 1, height: 40)
    }

    // MARK: - Picking

    /// The picker's size rule: a picked patch is the same square, in sensor
    /// samples, that the default patch is. So picking the exact centre
    /// measures the default patch's samples.
    @Test("Picking the centre selects the default patch's samples")
    func pickingTheCentreMatchesTheDefault() throws {
        for (width, height) in [(4056, 3040), (800, 600), (64, 64), (1000, 37)] {
            let picked = UserWhiteBalanceAdjustment.neutralPatch(
                try UserWhiteBalanceAdjustment.pickedRegion(
                    atX: 0.5, y: 0.5, activeAreaWidth: width, activeAreaHeight: height
                )
            )
            let pickedRegion = try picked.resolvedRegion(
                activeAreaWidth: width, activeAreaHeight: height
            )
            let defaultRegion = UserWhiteBalanceAdjustment.defaultRegion(
                width: width, height: height
            )
            #expect(pickedRegion.width == defaultRegion.width)
            #expect(pickedRegion.height == defaultRegion.height)
            // Centred to within a sample on each axis: the picked origin
            // floors where the default's halving may round the other way.
            #expect(abs(pickedRegion.originRow - defaultRegion.originRow) <= 1)
            #expect(abs(pickedRegion.originColumn - defaultRegion.originColumn) <= 1)
        }
    }

    @Test("A pick near an edge keeps its size")
    func pickingNearAnEdgeKeepsTheSize() throws {
        let width = 4056, height = 3040
        let side = UserWhiteBalanceAdjustment.defaultPatchSide(
            width: width, height: height
        )
        for (x, y) in [(0.0, 0.0), (1.0, 1.0), (0.0, 1.0), (1.0, 0.0)] {
            let region = try UserWhiteBalanceAdjustment.neutralPatch(
                try UserWhiteBalanceAdjustment.pickedRegion(
                    atX: x, y: y, activeAreaWidth: width, activeAreaHeight: height
                )
            ).resolvedRegion(activeAreaWidth: width, activeAreaHeight: height)
            #expect(region.width == side)
            #expect(region.height == side)
            try region.validate(inWidth: width, height: height)
        }
    }

    @Test("Different points pick different regions")
    func differentPointsPickDifferentRegions() throws {
        let a = try UserWhiteBalanceAdjustment.pickedRegion(
            atX: 0.2, y: 0.3, activeAreaWidth: 4056, activeAreaHeight: 3040
        )
        let b = try UserWhiteBalanceAdjustment.pickedRegion(
            atX: 0.8, y: 0.7, activeAreaWidth: 4056, activeAreaHeight: 3040
        )
        #expect(a != b)
        #expect(a.originX < b.originX)
        #expect(a.originY < b.originY)
    }

    @Test("A pick on an unusable active area is refused")
    func pickingOnAnUnusableAreaIsRefused() {
        #expect(throws: RAWProcessingError.self) {
            try UserWhiteBalanceAdjustment.pickedRegion(
                atX: 0.5, y: 0.5, activeAreaWidth: 0, activeAreaHeight: 100
            )
        }
        #expect(throws: ImageAdjustmentError.self) {
            try UserWhiteBalanceAdjustment.pickedRegion(
                atX: .nan, y: 0.5, activeAreaWidth: 100, activeAreaHeight: 100
            )
        }
    }

    // MARK: - The overlay's region

    /// The overlay is drawn from the region that will actually be measured,
    /// not from the request, so the resolver's rounding is visible where a
    /// reader is looking for it.
    @Test("The normalised region round-trips through the resolver")
    func theNormalisedRegionMatchesTheResolvedOne() throws {
        let width = 4056, height = 3040
        for adjustment: UserWhiteBalanceAdjustment in [
            .defaultNeutralPatch,
            .neutralPatch(
                try NormalizedActiveAreaRegion(
                    originX: 0.317, originY: 0.628, width: 0.041, height: 0.073
                )
            ),
        ] {
            let resolved = try adjustment.resolvedRegion(
                activeAreaWidth: width, activeAreaHeight: height
            )
            let normalized = try adjustment.normalizedRegion(
                activeAreaWidth: width, activeAreaHeight: height
            )
            #expect(normalized.originX == Double(resolved.originColumn) / Double(width))
            #expect(normalized.originY == Double(resolved.originRow) / Double(height))
            #expect(normalized.width == Double(resolved.width) / Double(width))
            #expect(normalized.height == Double(resolved.height) / Double(height))
        }
    }

    // MARK: - Persistence

    @Test("The encoded shape is the documented one")
    func theEncodedShapeIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        #expect(
            String(
                decoding: try encoder.encode(UserWhiteBalanceAdjustment.defaultNeutralPatch),
                as: UTF8.self
            ) == #"{"kind":"defaultNeutralPatch"}"#
        )

        let picked = UserWhiteBalanceAdjustment.neutralPatch(
            try NormalizedActiveAreaRegion(
                originX: 0.25, originY: 0.5, width: 0.125, height: 0.0625
            )
        )
        #expect(
            String(decoding: try encoder.encode(picked), as: UTF8.self)
                == #"{"kind":"neutralPatch","region":{"height":0.0625,"originX":0.25,"originY":0.5,"width":0.125}}"#
        )

        // The gains are deliberately not written: they are derived from the
        // photograph, every time, by an estimator that may improve.
        let text = String(decoding: try encoder.encode(picked), as: UTF8.self)
        #expect(!text.contains("gain"))
        #expect(!text.contains("plane"))
    }

    @Test("Both cases round-trip")
    func bothCasesRoundTrip() throws {
        let cases: [UserWhiteBalanceAdjustment] = [
            .defaultNeutralPatch,
            .neutralPatch(
                try NormalizedActiveAreaRegion(
                    originX: 0, originY: 0, width: 1, height: 1
                )
            ),
            .neutralPatch(
                try NormalizedActiveAreaRegion(
                    originX: 0.9, originY: 0.05, width: 0.1, height: 0.9
                )
            ),
        ]
        for adjustment in cases {
            let data = try JSONEncoder().encode(adjustment)
            #expect(
                try JSONDecoder().decode(UserWhiteBalanceAdjustment.self, from: data)
                    == adjustment
            )
        }
    }

    @Test("An unknown kind is refused, never read as the default")
    func anUnknownKindIsRefused() {
        let json = Data(#"{"kind":"greyWorld"}"#.utf8)
        #expect(throws: ImageAdjustmentError.unknownWhiteBalanceKind(token: "greyWorld")) {
            try JSONDecoder().decode(UserWhiteBalanceAdjustment.self, from: json)
        }
    }

    @Test("A missing kind is refused")
    func aMissingKindIsRefused() {
        let json = Data(#"{"region":{"originX":0,"originY":0,"width":1,"height":1}}"#.utf8)
        #expect(throws: ImageAdjustmentError.missingWhiteBalanceField(field: "kind")) {
            try JSONDecoder().decode(UserWhiteBalanceAdjustment.self, from: json)
        }
    }

    @Test("A picked patch with no region is refused")
    func aPickedPatchWithoutARegionIsRefused() {
        let json = Data(#"{"kind":"neutralPatch"}"#.utf8)
        #expect(throws: ImageAdjustmentError.missingWhiteBalanceField(field: "region")) {
            try JSONDecoder().decode(UserWhiteBalanceAdjustment.self, from: json)
        }
    }

    /// The same rule that refuses a built-in channel mix carrying a matrix:
    /// the record would say two different things about which samples were
    /// measured, and neither reading is anything but a guess.
    @Test("The default patch carrying a region is refused, not read around")
    func theDefaultCarryingARegionIsRefused() {
        let json = Data(
            #"""
            {"kind":"defaultNeutralPatch",
             "region":{"originX":0,"originY":0,"width":1,"height":1}}
            """#.utf8
        )
        #expect(
            throws: ImageAdjustmentError.unexpectedWhiteBalanceField(
                field: "region", kind: "defaultNeutralPatch"
            )
        ) {
            try JSONDecoder().decode(UserWhiteBalanceAdjustment.self, from: json)
        }
    }

    @Test("A malformed region inside a picked patch is refused")
    func aMalformedRegionIsRefused() {
        let json = Data(
            #"""
            {"kind":"neutralPatch",
             "region":{"originX":0.8,"originY":0,"width":0.5,"height":0.1}}
            """#.utf8
        )
        #expect(throws: ImageAdjustmentError.self) {
            try JSONDecoder().decode(UserWhiteBalanceAdjustment.self, from: json)
        }
    }

    @Test("The kind tokens are the wire format, with no second list")
    func theKindTokensAreTheWireFormat() throws {
        #expect(
            UserWhiteBalanceAdjustment.Kind.allCases.map(\.rawValue)
                == ["defaultNeutralPatch", "neutralPatch"]
        )
        let picked = UserWhiteBalanceAdjustment.neutralPatch(.full)
        #expect(picked.kind == .neutralPatch)
        #expect(UserWhiteBalanceAdjustment.defaultNeutralPatch.kind == .defaultNeutralPatch)
    }
}
