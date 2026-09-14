import Testing
import Foundation
@testable import InfraredConverter

/// The record of the user's editing decisions about one photograph.
///
/// Its persistence moved out. The sidecar's schema version, its migrations and
/// its `Codable` conformance now belong to `PhotographProcessingState`, whose
/// suite covers them; what is left here is what this type is for — four
/// decisions, their defaults, and what "default" does and does not claim.
@Suite("ImageAdjustments")
struct ImageAdjustmentsTests {

    @Test("A fresh record has no user decisions")
    func aFreshRecordIsEmpty() {
        let adjustments = ImageAdjustments.none
        #expect(adjustments.orientation == .identity)
        // Identity, not the red/blue swap. Nothing here knows whether a file
        // is an infrared capture, so nothing chooses a rendering for it.
        #expect(adjustments.channelMix == .identity)
        // The default centred patch, and emphatically not "no white balance":
        // it estimates real multipliers from real samples.
        #expect(adjustments.whiteBalance == .defaultNeutralPatch)
        #expect(adjustments.isDefault)
        #expect(adjustments.exposure == .neutral)
        #expect(adjustments.exposure.ev == 0)
    }

    /// The point of moving the schema out: a test about an exposure builds an
    /// exposure, not a versioned document record with a capture profile in it.
    ///
    /// Written as a compiling example rather than as prose, because the claim
    /// is about the shape of the API and nothing else can check it.
    @Test("Building a record needs nothing from the persistence layer")
    func buildingARecordNeedsNoPersistenceMetadata() throws {
        let exposure = ImageAdjustments(exposure: try UserExposureAdjustment(ev: 0.7))
        #expect(exposure.exposure.ev == 0.7)
        #expect(exposure.orientation == .identity)

        let rotated = ImageAdjustments(orientation: .quarterTurnRight)
        #expect(rotated.orientation == .quarterTurnRight)
        #expect(rotated.exposure == .neutral)
    }

    // MARK: - isDefault is about the whole record

    /// `isDefault` answers "has the user departed from the defaults?", and
    /// every one of the four fields can answer yes on its own.
    @Test("Any one adjustment away from its default stops the record being default")
    func isDefaultCoversEveryField() throws {
        #expect(ImageAdjustments().isDefault)
        #expect(!ImageAdjustments(orientation: .quarterTurnRight).isDefault)
        #expect(!ImageAdjustments(channelMix: .redBlueSwap).isDefault)
        #expect(!ImageAdjustments(exposure: try UserExposureAdjustment(ev: 0.1)).isDefault)
        #expect(!ImageAdjustments(exposure: try UserExposureAdjustment(ev: -0.05)).isDefault)
        #expect(
            !ImageAdjustments(
                whiteBalance: .neutralPatch(
                    try NormalizedActiveAreaRegion(
                        originX: 0.1, originY: 0.2, width: 0.05, height: 0.05
                    )
                )
            ).isDefault
        )
        #expect(
            !ImageAdjustments(orientation: .halfTurn, channelMix: .redBlueSwap).isDefault
        )
    }

    /// It knows nothing about capture profiles, and must not learn: a profile
    /// is not an adjustment, and the document-level default is a separate
    /// question asked by `PhotographProcessingState.isDefault`.
    @Test("The record's default is about adjustments alone")
    func isDefaultKnowsNothingAboutProfiles() {
        #expect(ImageAdjustments.none.isDefault)
        #expect(PhotographProcessingState.none.isDefault)
        #expect(PhotographProcessingState.none.adjustments.isDefault)
    }

    /// The property it deliberately does **not** claim. `isIdentity` used to
    /// mean "no net effect on the image", and the white balance retired that
    /// reading: the default patch estimates real multipliers from real
    /// samples, so a default record changes the photograph.
    ///
    /// What survives is the weaker, true statement — the other three fields
    /// leave the image alone — and it is asked of them individually, which is
    /// where it is still answerable.
    @Test("The record answers about decisions; only its fields answer about pixels")
    func isDefaultIsNotAClaimAboutPixels() throws {
        let record = ImageAdjustments()
        #expect(record.isDefault)
        #expect(record.orientation.isIdentity)
        #expect(record.channelMix.isIdentity)
        #expect(record.exposure.isIdentity)
        // And the fourth is not asked, because it cannot be answered without
        // the photograph: `.defaultNeutralPatch` is a default, not an
        // identity.
        #expect(record.whiteBalance.isDefault)
    }

    /// A default is a decision, not an absence: an explicit identity matrix at
    /// 0 EV leaves the image alone and is still a different record from the
    /// defaults, because it carries different provenance and persists
    /// differently.
    @Test("An explicit identity matrix is not the default record")
    func explicitIdentityIsNotDefault() throws {
        let explicitIdentity = ImageAdjustments(
            channelMix: try UserChannelMixAdjustment.explicit(
                persistedMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
            ),
            exposure: .neutral
        )
        #expect(explicitIdentity.channelMix.isIdentity)
        #expect(!explicitIdentity.isDefault)
        #expect(explicitIdentity.channelMix.mix.source == .explicit)
        #expect(explicitIdentity != ImageAdjustments.none)
    }

    /// It is emphatically not "the user never edited". A saved default is a
    /// decision, which is why the sidecar stores it.
    @Test("A record reset to the defaults is still a record")
    func resettingIsADecision() throws {
        var adjustments = ImageAdjustments(
            orientation: .quarterTurnRight,
            channelMix: .redBlueSwap,
            exposure: try UserExposureAdjustment(ev: 1.5),
            whiteBalance: .neutralPatch(
                try NormalizedActiveAreaRegion(
                    originX: 0.1, originY: 0.2, width: 0.05, height: 0.05
                )
            )
        )
        adjustments.orientation = .reset
        adjustments.channelMix = .identity
        adjustments.exposure = .neutral
        adjustments.whiteBalance = .defaultNeutralPatch
        #expect(adjustments.isDefault)
        #expect(adjustments == ImageAdjustments.none)
    }
}
