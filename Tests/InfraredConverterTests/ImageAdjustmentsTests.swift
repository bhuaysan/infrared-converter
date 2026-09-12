import Testing
import Foundation
@testable import InfraredConverter

/// The serialisable record of the user's editing decisions, and the policy it
/// applies to persisted state it cannot read.
@Suite("ImageAdjustments")
struct ImageAdjustmentsTests {

    @Test("A fresh record has no user decisions and the current schema version")
    func aFreshRecordIsEmpty() {
        let adjustments = ImageAdjustments.none
        #expect(adjustments.orientation == .identity)
        // Identity, not the red/blue swap. Nothing here knows whether a file
        // is an infrared capture, so nothing chooses a rendering for it.
        #expect(adjustments.channelMix == .identity)
        #expect(adjustments.isIdentity)
        #expect(adjustments.schemaVersion == ImageAdjustments.currentSchemaVersion)
        #expect(ImageAdjustments.currentSchemaVersion == 2)
    }

    // MARK: - isIdentity is about the whole record

    /// `isIdentity` answers "no net effect on the image", and there are two
    /// adjustments that can have one.
    @Test("Either adjustment on its own stops the record being the identity")
    func isIdentityCoversBothAdjustments() throws {
        #expect(ImageAdjustments().isIdentity)
        #expect(!ImageAdjustments(orientation: .quarterTurnRight).isIdentity)
        #expect(!ImageAdjustments(channelMix: .redBlueSwap).isIdentity)
        #expect(
            !ImageAdjustments(orientation: .halfTurn, channelMix: .redBlueSwap).isIdentity
        )

        // A net effect, not a provenance: an explicit matrix that happens to
        // be the identity has no effect on the image and is still a different
        // decision from `.identity`.
        let explicitIdentity = ImageAdjustments(
            channelMix: try UserChannelMixAdjustment.explicit(
                persistedMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
            )
        )
        #expect(explicitIdentity.isIdentity)
        #expect(explicitIdentity != ImageAdjustments())
    }

    /// It is emphatically not "the user never edited". A saved identity is a
    /// decision, which is why the sidecar stores it.
    @Test("A record reset to the identity is still a record")
    func identityIsADecision() {
        var adjustments = ImageAdjustments(
            orientation: .quarterTurnRight, channelMix: .redBlueSwap
        )
        adjustments.orientation = .reset
        adjustments.channelMix = .identity
        #expect(adjustments.isIdentity)
        #expect(adjustments == ImageAdjustments.none)
    }

    @Test("All eight orientation states round-trip inside the record")
    func everyOrientationRoundTrips() throws {
        for orientation in UserOrientationAdjustment.allCases {
            let adjustments = ImageAdjustments(orientation: orientation)
            let data = try JSONEncoder().encode(adjustments)
            let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: data)

            #expect(decoded == adjustments)
            #expect(decoded.orientation == orientation)
            #expect(decoded.orientation.transform == orientation.transform)
            #expect(decoded.schemaVersion == ImageAdjustments.currentSchemaVersion)
        }
    }

    @Test("Every channel-mix state round-trips inside the record")
    func everyChannelMixRoundTrips() throws {
        let asymmetric = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [0.1, 0.2, 0.3, -0.4, 1.5, 0.6, 0.7, 0.8, -0.9]
        )
        for mix in [UserChannelMixAdjustment.identity, .redBlueSwap, asymmetric] {
            let adjustments = ImageAdjustments(orientation: .halfTurn, channelMix: mix)
            let data = try JSONEncoder().encode(adjustments)
            let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: data)

            #expect(decoded == adjustments)
            #expect(decoded.channelMix == mix)
            #expect(decoded.orientation == .halfTurn)
            #expect(decoded.channelMix.matrix == mix.matrix)
            #expect(decoded.schemaVersion == ImageAdjustments.currentSchemaVersion)
        }
    }

    @Test("The encoded shape is the documented one")
    func theEncodedShapeIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let identity = try encoder.encode(
            ImageAdjustments(orientation: .quarterTurnRight)
        )
        #expect(
            String(decoding: identity, as: UTF8.self)
                == #"{"channelMix":{"kind":"identity"},"orientation":"rotate90Clockwise","schemaVersion":2}"#
        )

        let swap = try encoder.encode(
            ImageAdjustments(orientation: .identity, channelMix: .redBlueSwap)
        )
        #expect(
            String(decoding: swap, as: UTF8.self)
                == #"{"channelMix":{"kind":"redBlueSwap"},"orientation":"none","schemaVersion":2}"#
        )

        let explicit = try encoder.encode(
            ImageAdjustments(
                channelMix: try UserChannelMixAdjustment.explicit(
                    persistedMatrix: [0, 0, 1, 0, 1, 0, 1, 0, 0]
                )
            )
        )
        #expect(
            String(decoding: explicit, as: UTF8.self)
                == #"{"channelMix":{"kind":"matrix","matrix":[0,0,1,0,1,0,1,0,0]},"orientation":"none","schemaVersion":2}"#
        )

        // A built-in's nine numbers are derived from its token and are
        // deliberately not written: two authorities for one matrix is how a
        // record comes to say "redBlueSwap" and carry something else.
        #expect(!String(decoding: swap, as: UTF8.self).contains("matrix"))
    }

    /// Extensibility is the reason this is a record rather than a property,
    /// so a record carrying a field this version does not know about is read,
    /// not refused — **when ignoring it cannot change the photograph**.
    ///
    /// The field here is a note. It is deliberately not an adjustment: an
    /// earlier version of this test used `exposureEV`, which stated the
    /// opposite contract. An older client that ignored a newer exposure would
    /// open the file, render a different photograph, report no problem, and
    /// then write the record back without the field.
    @Test("An unknown non-semantic field at a readable version is ignored")
    func unknownNonSemanticFieldsAreIgnored() throws {
        let json = Data(
            #"""
            {"schemaVersion":2,"orientation":"flipVertical",
             "channelMix":{"kind":"identity"},"note":"scanned by hand"}
            """#.utf8
        )
        let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: json)
        #expect(decoded.orientation == .verticalFlip)
        #expect(decoded.channelMix == .identity)
    }

    /// The other half of the same rule, and the reason the field above has to
    /// be a note: anything image-affecting arrives with a version bump, and a
    /// version bump is refused outright.
    @Test("An image-affecting field arrives with a version this build refuses")
    func anImageAffectingFieldArrivesAsANewerVersion() {
        let json = Data(
            #"""
            {"schemaVersion":3,"orientation":"flipVertical",
             "channelMix":{"kind":"identity"},"exposureEV":0.75}
            """#.utf8
        )
        #expect(
            throws: ImageAdjustmentError.unsupportedSchemaVersion(found: 3, supported: 2)
        ) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }
    }

    // MARK: - The version 1 migration

    /// The rule applied for the first time rather than merely written down:
    /// `channelMix` changes the image, so it arrived with a version of its
    /// own, and version 1 still reads because what its absent mix meant is
    /// known exactly.
    @Test(
        "A version 1 record reads as itself with the identity mix",
        arguments: UserOrientationAdjustment.allCases
    )
    func aVersionOneRecordMigrates(orientation: UserOrientationAdjustment) throws {
        let json = Data(
            #"{"schemaVersion":1,"orientation":"\#(orientation.persistedToken)"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: json)

        #expect(decoded.orientation == orientation)
        // A migration, not a default for a missing field: version 1 rendered
        // no creative remapping at all, so identity is the state the record
        // was actually saved in.
        #expect(decoded.channelMix == .identity)
        #expect(decoded == ImageAdjustments(orientation: orientation, channelMix: .identity))
    }

    @Test("A migrated version 1 record is written back as version 2")
    func aMigratedRecordIsWrittenAsVersionTwo() throws {
        let json = Data(#"{"schemaVersion":1,"orientation":"rotate180"}"#.utf8)
        let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: json)
        #expect(decoded.schemaVersion == 2)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(
            String(decoding: try encoder.encode(decoded), as: UTF8.self)
                == #"{"channelMix":{"kind":"identity"},"orientation":"rotate180","schemaVersion":2}"#
        )

        // And re-reading what was written is the same record: the migration
        // runs once and then the record is an ordinary version 2 one.
        let reread = try JSONDecoder().decode(
            ImageAdjustments.self, from: try encoder.encode(decoded)
        )
        #expect(reread == decoded)
    }

    /// The forward-compatibility rule in the direction that destroys data. A
    /// record declaring version 1 and carrying a version 2 field is not a
    /// version 1 record, and reading around the field would render a
    /// different photograph and then write the field away.
    @Test("A version 1 record carrying a channel mix is refused, not read around")
    func aVersionOneRecordWithAMixIsRefused() {
        let json = Data(
            #"""
            {"schemaVersion":1,"orientation":"none","channelMix":{"kind":"redBlueSwap"}}
            """#.utf8
        )
        #expect(
            throws: ImageAdjustmentError.unexpectedAdjustment(
                field: "channelMix", schemaVersion: 1
            )
        ) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }
    }

    // MARK: - The schema version is wire-format metadata

    @Test(
        "Every publicly constructed record carries the current schema version",
        arguments: UserOrientationAdjustment.allCases
    )
    func everyConstructedRecordIsCurrent(orientation: UserOrientationAdjustment) {
        #expect(
            ImageAdjustments(orientation: orientation).schemaVersion
                == ImageAdjustments.currentSchemaVersion
        )
    }

    /// The invariant the old initialiser broke: what a record says its version
    /// is, and what encoding writes, can no longer disagree.
    @Test("A record's version and its encoded version always agree")
    func theVersionAndTheEncodedVersionAgree() throws {
        for orientation in UserOrientationAdjustment.allCases {
            let adjustments = ImageAdjustments(orientation: orientation)
            let data = try JSONEncoder().encode(adjustments)
            let object = try #require(
                try JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            #expect(object["schemaVersion"] as? Int == adjustments.schemaVersion)
        }
    }

    /// Round-tripping is now a property of the type rather than of careful
    /// callers: there is no publicly reachable value that fails it.
    @Test("Re-encoding a decoded record reproduces the bytes exactly")
    func encodingIsStableAcrossARoundTrip() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let mixes: [UserChannelMixAdjustment] = [
            .identity,
            .redBlueSwap,
            try UserChannelMixAdjustment.explicit(
                persistedMatrix: [0.25, -1, 2, 0, 0.5, 0, 3, 0, -0.75]
            ),
        ]
        for orientation in UserOrientationAdjustment.allCases {
            for mix in mixes {
                let record = ImageAdjustments(orientation: orientation, channelMix: mix)
                let first = try encoder.encode(record)
                let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: first)
                #expect(decoded == record)
                #expect(try encoder.encode(decoded) == first)
                // Deterministic: the same state encodes to the same bytes
                // every time, not merely to an equivalent object.
                #expect(try encoder.encode(record) == first)
            }
        }
    }

    /// A record read at a supported historical version is written back at the
    /// current one, and says so.
    @Test("A decoded record reports the current version, not the one on the wire")
    func aDecodedRecordReportsTheCurrentVersion() throws {
        let json = Data(
            #"""
            {"schemaVersion":2,"orientation":"rotate180",
             "channelMix":{"kind":"redBlueSwap"}}
            """#.utf8
        )
        let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: json)
        #expect(decoded.schemaVersion == ImageAdjustments.currentSchemaVersion)
        #expect(
            decoded == ImageAdjustments(orientation: .halfTurn, channelMix: .redBlueSwap)
        )
    }

    // MARK: - Refusals

    @Test("A newer schema version is refused rather than partly applied", arguments: [3, 4, 99])
    func aNewerSchemaVersionIsRefused(version: Int) {
        let json = Data(
            #"""
            {"schemaVersion":\#(version),"orientation":"none",
             "channelMix":{"kind":"identity"}}
            """#.utf8
        )
        #expect(
            throws: ImageAdjustmentError.unsupportedSchemaVersion(
                found: version, supported: 2
            )
        ) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }
    }

    @Test("A schema version below one is refused", arguments: [0, -1, -7])
    func anImpossibleSchemaVersionIsRefused(version: Int) {
        let json = Data(#"{"schemaVersion":\#(version),"orientation":"none"}"#.utf8)
        #expect(
            throws: ImageAdjustmentError.unsupportedSchemaVersion(found: version, supported: 2)
        ) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }
    }

    @Test("A missing schema version is refused")
    func aMissingSchemaVersionIsRefused() {
        let json = Data(#"{"orientation":"none"}"#.utf8)
        #expect(
            throws: ImageAdjustmentError.missingAdjustment(
                field: "schemaVersion", schemaVersion: 0
            )
        ) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }
    }

    @Test(
        "A missing orientation is refused, not defaulted to no correction",
        arguments: [1, 2]
    )
    func aMissingOrientationIsRefused(version: Int) {
        let json = Data(#"{"schemaVersion":\#(version)}"#.utf8)
        #expect(
            throws: ImageAdjustmentError.missingAdjustment(
                field: "orientation", schemaVersion: version
            )
        ) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }
    }

    /// The mix is required at version 2, exactly as the orientation is.
    /// Version 2 is the version that has the field, so a version 2 record
    /// without it is incomplete rather than migratable.
    @Test("A version 2 record missing its channel mix is refused")
    func aMissingChannelMixIsRefused() {
        let json = Data(#"{"schemaVersion":2,"orientation":"none"}"#.utf8)
        #expect(
            throws: ImageAdjustmentError.missingAdjustment(
                field: "channelMix", schemaVersion: 2
            )
        ) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }
    }

    @Test("An unreadable channel-mix kind is refused, never read as identity")
    func anUnknownMixKindIsRefused() {
        let json = Data(
            #"""
            {"schemaVersion":2,"orientation":"none","channelMix":{"kind":"aerochrome"}}
            """#.utf8
        )
        #expect(
            throws: ImageAdjustmentError.unknownChannelMixKind(token: "aerochrome")
        ) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }
        #expect((try? JSONDecoder().decode(ImageAdjustments.self, from: json)) == nil)
    }

    @Test("A channel mix with no kind is refused")
    func aMixWithNoKindIsRefused() {
        let json = Data(
            #"{"schemaVersion":2,"orientation":"none","channelMix":{}}"#.utf8
        )
        #expect(throws: ImageAdjustmentError.missingChannelMixField(field: "kind")) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }
    }

    @Test("An explicit mix with no matrix is refused")
    func anExplicitMixWithNoMatrixIsRefused() {
        let json = Data(
            #"""
            {"schemaVersion":2,"orientation":"none","channelMix":{"kind":"matrix"}}
            """#.utf8
        )
        #expect(throws: ImageAdjustmentError.missingChannelMixField(field: "matrix")) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }
    }

    @Test(
        "A matrix that is not nine coefficients is refused",
        arguments: [[Double](), [1], Array(repeating: 1.0, count: 8),
                    Array(repeating: 1.0, count: 10)]
    )
    func aMalformedMatrixIsRefused(coefficients: [Double]) {
        let list = coefficients.map { String($0) }.joined(separator: ",")
        let json = Data(
            #"""
            {"schemaVersion":2,"orientation":"none",
             "channelMix":{"kind":"matrix","matrix":[\#(list)]}}
            """#.utf8
        )
        #expect(
            throws: ImageAdjustmentError.malformedChannelMixMatrix(
                coefficientCount: coefficients.count, expected: 9
            )
        ) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }
    }

    /// The policy that matters most: a corrupt record never decodes into
    /// "the user asked for nothing". That would discard their edit and
    /// present the result as a deliberate choice.
    @Test("An unreadable orientation token is refused, never read as identity")
    func anUnreadableTokenNeverBecomesIdentity() {
        let json = Data(#"{"schemaVersion":2,"orientation":"rotateSideways"}"#.utf8)
        #expect(
            throws: ImageAdjustmentError.unknownOrientationAdjustment(token: "rotateSideways")
        ) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }

        // And nothing silently produced a usable value on the way past.
        let decoded = try? JSONDecoder().decode(ImageAdjustments.self, from: json)
        #expect(decoded == nil)
    }

    @Test("The refusals carry readable reasons")
    func theRefusalsAreInformative() {
        let version = ImageAdjustmentError.unsupportedSchemaVersion(found: 9, supported: 1)
        #expect(version.errorDescription?.isEmpty == false)
        #expect(version.failureReason?.contains("9") == true)

        let missing = ImageAdjustmentError.missingAdjustment(
            field: "orientation", schemaVersion: 1
        )
        #expect(missing.errorDescription?.isEmpty == false)
        #expect(missing.failureReason?.contains("orientation") == true)

        let unexpected = ImageAdjustmentError.unexpectedAdjustment(
            field: "channelMix", schemaVersion: 1
        )
        #expect(unexpected.errorDescription?.isEmpty == false)
        #expect(unexpected.failureReason?.contains("channelMix") == true)

        let kind = ImageAdjustmentError.unknownChannelMixKind(token: "aerochrome")
        #expect(kind.errorDescription?.isEmpty == false)
        #expect(kind.failureReason?.contains("aerochrome") == true)

        let shape = ImageAdjustmentError.malformedChannelMixMatrix(
            coefficientCount: 4, expected: 9
        )
        #expect(shape.errorDescription?.isEmpty == false)
        #expect(shape.failureReason?.contains("4") == true)

        let nonFinite = ImageAdjustmentError.nonFiniteChannelMixCoefficient(
            index: 3, value: .nan
        )
        #expect(nonFinite.errorDescription?.isEmpty == false)
        #expect(nonFinite.failureReason?.contains("3") == true)

        let field = ImageAdjustmentError.missingChannelMixField(field: "matrix")
        #expect(field.errorDescription?.isEmpty == false)
        #expect(field.failureReason?.contains("matrix") == true)
    }
}
