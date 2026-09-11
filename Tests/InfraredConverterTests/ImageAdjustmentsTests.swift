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
        #expect(adjustments.isIdentity)
        #expect(adjustments.schemaVersion == ImageAdjustments.currentSchemaVersion)
        #expect(ImageAdjustments.currentSchemaVersion == 1)
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

    @Test("The encoded shape is the documented one")
    func theEncodedShapeIsStable() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(
            ImageAdjustments(orientation: .quarterTurnRight)
        )
        #expect(
            String(decoding: data, as: UTF8.self)
                == #"{"orientation":"rotate90Clockwise","schemaVersion":1}"#
        )
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
            {"schemaVersion":1,"orientation":"flipVertical","note":"scanned by hand"}
            """#.utf8
        )
        let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: json)
        #expect(decoded.orientation == .verticalFlip)
    }

    /// The other half of the same rule, and the reason the field above has to
    /// be a note: anything image-affecting arrives with a version bump, and a
    /// version bump is refused outright.
    @Test("An image-affecting field arrives with a version this build refuses")
    func anImageAffectingFieldArrivesAsANewerVersion() {
        let json = Data(
            #"""
            {"schemaVersion":2,"orientation":"flipVertical","exposureEV":0.75}
            """#.utf8
        )
        #expect(
            throws: ImageAdjustmentError.unsupportedSchemaVersion(found: 2, supported: 1)
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

        for orientation in UserOrientationAdjustment.allCases {
            let first = try encoder.encode(ImageAdjustments(orientation: orientation))
            let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: first)
            #expect(try encoder.encode(decoded) == first)
        }
    }

    /// A record read at a supported historical version is written back at the
    /// current one, and says so.
    @Test("A decoded record reports the current version, not the one on the wire")
    func aDecodedRecordReportsTheCurrentVersion() throws {
        let json = Data(#"{"schemaVersion":1,"orientation":"rotate180"}"#.utf8)
        let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: json)
        #expect(decoded.schemaVersion == ImageAdjustments.currentSchemaVersion)
        #expect(decoded == ImageAdjustments(orientation: .halfTurn))
    }

    // MARK: - Refusals

    @Test("A newer schema version is refused rather than partly applied")
    func aNewerSchemaVersionIsRefused() {
        let json = Data(#"{"schemaVersion":2,"orientation":"none"}"#.utf8)
        #expect(
            throws: ImageAdjustmentError.unsupportedSchemaVersion(found: 2, supported: 1)
        ) {
            try JSONDecoder().decode(ImageAdjustments.self, from: json)
        }
    }

    @Test("A schema version below one is refused", arguments: [0, -1, -7])
    func anImpossibleSchemaVersionIsRefused(version: Int) {
        let json = Data(#"{"schemaVersion":\#(version),"orientation":"none"}"#.utf8)
        #expect(
            throws: ImageAdjustmentError.unsupportedSchemaVersion(found: version, supported: 1)
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

    @Test("A missing orientation is refused, not defaulted to no correction")
    func aMissingOrientationIsRefused() {
        let json = Data(#"{"schemaVersion":1}"#.utf8)
        #expect(
            throws: ImageAdjustmentError.missingAdjustment(
                field: "orientation", schemaVersion: 1
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
        let json = Data(#"{"schemaVersion":1,"orientation":"rotateSideways"}"#.utf8)
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
    }
}
