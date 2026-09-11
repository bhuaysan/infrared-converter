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
    /// not refused — within a version it can read.
    @Test("An unknown extra field at a readable version is ignored")
    func unknownFieldsAtAReadableVersionAreIgnored() throws {
        let json = Data(
            #"{"schemaVersion":1,"orientation":"flipVertical","exposureEV":0.75}"#.utf8
        )
        let decoded = try JSONDecoder().decode(ImageAdjustments.self, from: json)
        #expect(decoded.orientation == .verticalFlip)
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
