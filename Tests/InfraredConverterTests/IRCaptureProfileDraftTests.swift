import Testing
import Foundation
@testable import InfraredConverter

/// The mutable, possibly invalid form state a capture-profile editor holds,
/// and the single gate — `makeProfile(id:)` — between it and the immutable
/// `IRCaptureProfile` the library stores.
///
/// The recurring theme across this suite: invalid input is refused, never
/// normalised into something plausible-looking. A blank field never quietly
/// becomes the value that means "nothing was said about this" — those are two
/// different facts, and conflating them would silently save a profile
/// describing a different capture configuration from the one a person typed.
@Suite("IRCaptureProfileDraft")
struct IRCaptureProfileDraftTests {

    /// A well-formed, unreserved identity for tests that do not care which one
    /// they get, only that `makeProfile(id:)` accepts it.
    private static func userID(_ suffix: String = "profile") -> IRCaptureProfileID {
        try! IRCaptureProfileID("user.\(suffix)")
    }

    // MARK: - A complete draft becomes the profile it describes

    @Test("A complete draft becomes exactly the profile it describes")
    func aCompleteDraftBecomesItsProfile() throws {
        var draft = IRCaptureProfileDraft(name: "My E-PL3 720")
        draft.useCamera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3")
        draft.conversionKind = .fullSpectrum
        draft.conversionVendor = "Kolari"
        draft.filter = .init(kind: .longPass, nominalCutoffNanometers: "720")

        let id = try IRCaptureProfileID("user.epl3-720")
        let profile = try draft.makeProfile(id: id)

        #expect(profile.id == id)
        #expect(profile.name == "My E-PL3 720")
        #expect(profile.cameraMatch == .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"))
        #expect(profile.sensorConversion == .fullSpectrum(vendor: "Kolari"))
        #expect(profile.filter == .longPass(nominalCutoffNanometers: 720))
        #expect(profile.processingBasis == .uncalibratedSensorRGB)
    }

    @Test("Surrounding whitespace is trimmed, and nothing else is changed")
    func whitespaceIsTrimmedAndNothingElse() throws {
        var draft = IRCaptureProfileDraft(name: "  My E-PL3  ")
        draft.cameraScope = .specificCamera
        draft.cameraMake = "  OLYMPUS IMAGING CORP.  "
        draft.cameraModel = "  E-PL3  "

        let profile = try draft.makeProfile(id: Self.userID())
        #expect(profile.name == "My E-PL3")
        #expect(profile.cameraMatch == .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"))
    }

    // MARK: - Invalid input is refused, never normalised

    @Test(
        "An empty or whitespace-only name is refused",
        arguments: ["", "   ", "\n\t"]
    )
    func emptyNameIsRefused(name: String) throws {
        let draft = IRCaptureProfileDraft(name: name)
        #expect(throws: IRCaptureProfileDraftError.emptyName) {
            _ = try draft.makeProfile(id: Self.userID())
        }
    }

    /// A blank camera model does not quietly become `.any`: `.specificCamera`
    /// with an empty make or model is refused outright, because silently
    /// widening it would save a profile that claims something different from
    /// what the form said — "any camera" — from what a person was describing.
    @Test("A specific camera with an empty make is refused, not widened to \"any camera\"")
    func emptyCameraMakeIsRefused() throws {
        var draft = IRCaptureProfileDraft(name: "X")
        draft.cameraScope = .specificCamera
        draft.cameraMake = "   "
        draft.cameraModel = "E-PL3"
        #expect(throws: IRCaptureProfileDraftError.emptyCameraMake) {
            _ = try draft.makeProfile(id: Self.userID())
        }
    }

    @Test("A specific camera with a make but an empty model is refused, not widened to \"any camera\"")
    func emptyCameraModelIsRefused() throws {
        var draft = IRCaptureProfileDraft(name: "X")
        draft.cameraScope = .specificCamera
        draft.cameraMake = "OLYMPUS IMAGING CORP."
        draft.cameraModel = "   "
        #expect(throws: IRCaptureProfileDraftError.emptyCameraModel) {
            _ = try draft.makeProfile(id: Self.userID())
        }
    }

    @Test("A named external filter with an empty name is refused")
    func emptyExternalFilterNameIsRefused() throws {
        var draft = IRCaptureProfileDraft(name: "X")
        draft.filter = .init(kind: .named, name: "  ")
        #expect(throws: IRCaptureProfileDraftError.emptyFilterName(field: .externalFilter)) {
            _ = try draft.makeProfile(id: Self.userID())
        }
    }

    @Test("A long-pass external filter with no cutoff text is refused")
    func missingExternalCutoffIsRefused() throws {
        var draft = IRCaptureProfileDraft(name: "X")
        draft.filter = .init(kind: .longPass, nominalCutoffNanometers: "")
        #expect(throws: IRCaptureProfileDraftError.missingNominalCutoff(field: .externalFilter)) {
            _ = try draft.makeProfile(id: Self.userID())
        }
    }

    /// Three different ways a cutoff can fail to describe a real filter —
    /// text that is not a number at all, and numbers that are out of
    /// `IRFilterDescriptor.supportedNominalCutoffNanometers` — and all three
    /// are refused as the same typed error rather than clamped into range.
    ///
    /// The `"0"` and `"999999"` cases are the important ones: a cutoff of `0`
    /// does not quietly become `.unknown`. `.unknown` means "nobody recorded a
    /// filter"; a typed `0` means someone typed a number that cannot describe
    /// one. Collapsing the second into the first would save a profile that
    /// silently claims less was said about the capture than actually was.
    @Test(
        "An invalid nominal cutoff is refused, never rounded, clamped or defaulted",
        arguments: ["abc", "0", "999999"]
    )
    func invalidNominalCutoffIsRefused(token: String) throws {
        var draft = IRCaptureProfileDraft(name: "X")
        draft.filter = .init(kind: .longPass, nominalCutoffNanometers: token)

        do {
            _ = try draft.makeProfile(id: Self.userID())
            Issue.record("Expected .invalidNominalCutoff for \"\(token)\"")
        } catch {
            guard case .invalidNominalCutoff(let field, let errorToken, _) = error else {
                Issue.record("Expected .invalidNominalCutoff, got \(error)")
                return
            }
            #expect(field == .externalFilter)
            #expect(errorToken == token)
        }
    }

    // MARK: - The internal filter is a separate fact, validated separately

    @Test("The internal filter is validated separately from the external one, and the error says which")
    func internalFilterErrorNamesItself() throws {
        var draft = IRCaptureProfileDraft(name: "X")
        draft.conversionKind = .internalInfrared
        draft.internalFilter = .init(kind: .named, name: "  ")
        // A valid external filter, so a failure here can only be about the
        // internal one.
        draft.filter = .init(kind: .named, name: "Screw-on ND")

        #expect(throws: IRCaptureProfileDraftError.emptyFilterName(field: .internalFilter)) {
            _ = try draft.makeProfile(id: Self.userID())
        }
    }

    /// The internal filter only exists for `.internalInfrared`: for every
    /// other conversion kind it is not read at all, so a half-filled one left
    /// over from switching conversion kinds in the editor cannot block a save
    /// it has nothing to do with.
    @Test("A half-filled internal filter is ignored when the conversion is not internalInfrared")
    func internalFilterIgnoredWhenNotInternalInfrared() throws {
        var draft = IRCaptureProfileDraft(name: "X")
        draft.conversionKind = .fullSpectrum
        // Invalid on its own terms (a named filter with an empty name), and
        // irrelevant: fullSpectrum has no internal filter to validate.
        draft.internalFilter = .init(kind: .named, name: "")

        let profile = try draft.makeProfile(id: Self.userID())
        #expect(profile.sensorConversion == .fullSpectrum(vendor: nil))
    }

    @Test("The internal filter and the external filter round-trip as two independent facts")
    func internalAndExternalFilterAreIndependent() throws {
        var draft = IRCaptureProfileDraft(name: "Internally converted")
        draft.conversionKind = .internalInfrared
        draft.conversionVendor = "Some Converter"
        draft.internalFilter = .init(kind: .longPass, nominalCutoffNanometers: "720")
        draft.filter = .init(kind: .named, name: "Screw-on ND")

        let profile = try draft.makeProfile(id: Self.userID())
        #expect(
            profile.sensorConversion
                == .internalInfrared(
                    filter: .longPass(nominalCutoffNanometers: 720),
                    vendor: "Some Converter"
                )
        )
        #expect(profile.filter == .named("Screw-on ND"))
    }

    // MARK: - The conversion vendor is optional, honestly

    @Test(
        "An empty or whitespace-only vendor is recorded as unrecorded, not as a missing field",
        arguments: ["", "   ", "\n"]
    )
    func emptyVendorBecomesNil(vendorText: String) throws {
        var draft = IRCaptureProfileDraft(name: "X")
        draft.conversionKind = .fullSpectrum
        draft.conversionVendor = vendorText
        let profile = try draft.makeProfile(id: Self.userID())
        #expect(profile.sensorConversion == .fullSpectrum(vendor: nil))
    }

    @Test("A non-empty vendor is trimmed and kept")
    func nonEmptyVendorIsTrimmedAndKept() throws {
        var draft = IRCaptureProfileDraft(name: "X")
        draft.conversionKind = .fullSpectrum
        draft.conversionVendor = "  Kolari  "
        let profile = try draft.makeProfile(id: Self.userID())
        #expect(profile.sensorConversion == .fullSpectrum(vendor: "Kolari"))
    }

    // MARK: - The draft built from a profile is the inverse of makeProfile

    /// `IRCaptureProfileDraft(_:)` is the inverse of `makeProfile(id:)`:
    /// building a draft from a profile and immediately resolving it under the
    /// same identity must reproduce the original profile exactly. Covers the
    /// three shapes of profile the editor round-trips: an unclaimed
    /// everything, a specific camera with a named external filter, and an
    /// internally converted body with a nested long-pass filter and a vendor.
    /// The 720 nm cutoff is a whole number, so the string round-trip through
    /// the form's text field is exact.
    @Test("A draft built from a profile reproduces that profile, for each profile shape")
    func draftRoundTripsFromProfile() throws {
        let profiles = try [
            IRCaptureProfile(
                id: IRCaptureProfileID("user.any-unknown-unknown"),
                name: "Unclaimed everything",
                cameraMatch: .any,
                sensorConversion: .unknown,
                filter: .unknown,
                processingBasis: .uncalibratedSensorRGB
            ),
            IRCaptureProfile(
                id: IRCaptureProfileID("user.specific-named-filter"),
                name: "Specific camera, named external filter",
                cameraMatch: .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
                sensorConversion: .fullSpectrum(vendor: "Kolari"),
                filter: .named("Hoya R72"),
                processingBasis: .uncalibratedSensorRGB
            ),
            IRCaptureProfile(
                id: IRCaptureProfileID("user.internal-720"),
                name: "Internally converted, 720 nm",
                cameraMatch: .camera(make: "SONY", model: "ILCE-7"),
                sensorConversion: .internalInfrared(
                    filter: try IRFilterDescriptor.longPass(nominalNanometers: 720),
                    vendor: "LifePixel"
                ),
                filter: .unknown,
                processingBasis: .uncalibratedSensorRGB
            ),
        ]

        for profile in profiles {
            let draft = IRCaptureProfileDraft(profile)
            let rebuilt = try draft.makeProfile(id: profile.id)
            #expect(rebuilt == profile)
        }
    }

    // MARK: - The processing basis is not a field, and calibration is never claimed

    @Test("The processing basis is not a draft field, and it is always uncalibrated")
    func processingBasisIsFixedAndUncalibrated() {
        #expect(IRCaptureProfileDraft.processingBasis == .uncalibratedSensorRGB)
        #expect(!IRCaptureProfileDraft.isValidatedInfraredCalibration)
    }

    /// The most important assertion in this file. Naming a specific camera
    /// and a 720 nm filter reads like a calibrated capture, and it is not one:
    /// nothing this milestone can produce is a validated infrared calibration,
    /// because no measured data exists for any camera, conversion or filter in
    /// this project. A form that let naming things add up to "calibrated"
    /// would be exactly the plausible-looking claim `CLAUDE.md` forbids.
    @Test("A produced profile naming a camera and a 720 nm filter is still not calibrated")
    func namingACameraAndAFilterDoesNotCalibrate() throws {
        var draft = IRCaptureProfileDraft(name: "Looks calibrated, isn't")
        draft.useCamera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3")
        draft.filter = .init(kind: .longPass, nominalCutoffNanometers: "720")

        let profile = try draft.makeProfile(id: Self.userID())
        #expect(!profile.isValidatedInfraredCalibration)
    }

    // MARK: - Reserved identities

    @Test("makeProfile refuses the reserved builtin identity")
    func reservedBuiltinUncalibratedIsRefused() throws {
        let draft = IRCaptureProfileDraft(name: "X")
        #expect(
            throws: IRCaptureProfileDraftError.reservedIdentifier(
                id: .builtinUncalibrated, namespace: IRCaptureProfileID.builtinNamespace
            )
        ) {
            _ = try draft.makeProfile(id: .builtinUncalibrated)
        }
    }

    @Test("makeProfile refuses any identity in the builtin namespace, not just the one that exists")
    func reservedBuiltinNamespaceIsRefused() throws {
        let draft = IRCaptureProfileDraft(name: "X")
        let id = try IRCaptureProfileID("builtin.something-else")
        #expect(
            throws: IRCaptureProfileDraftError.reservedIdentifier(
                id: id, namespace: IRCaptureProfileID.builtinNamespace
            )
        ) {
            _ = try draft.makeProfile(id: id)
        }
    }

    // MARK: - refusal agrees with makeProfile(id:)

    @Test("refusal is nil exactly when makeProfile(id:) would succeed")
    func refusalIsNilWhenMakeProfileSucceeds() throws {
        let draft = IRCaptureProfileDraft(name: "Valid")
        #expect(draft.refusal == nil)
        // And it actually does succeed, under an identity of the caller's own
        // choosing rather than the fixed one `refusal` uses internally.
        _ = try draft.makeProfile(id: Self.userID())
    }

    @Test("refusal reports the same error makeProfile(id:) throws")
    func refusalReportsTheSameError() throws {
        let draft = IRCaptureProfileDraft(name: "")
        let refusal = try #require(draft.refusal)
        #expect(refusal == .emptyName)
        #expect(throws: IRCaptureProfileDraftError.emptyName) {
            _ = try draft.makeProfile(id: Self.userID())
        }
    }

    /// `refusal` is read on every keystroke by a live form. It must not mint a
    /// fresh identity per read — that would make a validity check into an
    /// identifier generator — so reading it repeatedly, on both a valid and an
    /// invalid draft, must be idempotent.
    @Test("Reading refusal repeatedly is stable")
    func refusalIsStableAcrossRepeatedReads() {
        let validDraft = IRCaptureProfileDraft(name: "Stable")
        #expect(validDraft.refusal == nil)
        #expect(validDraft.refusal == nil)
        #expect(validDraft.refusal == nil)

        let invalidDraft = IRCaptureProfileDraft(name: "")
        let first = invalidDraft.refusal
        let second = invalidDraft.refusal
        let third = invalidDraft.refusal
        #expect(first == .emptyName)
        #expect(first == second)
        #expect(second == third)
    }

    // MARK: - Generated identities

    @Test("generatedUserID produces valid, unreserved, distinct identities")
    func generatedUserIDsAreValidAndDistinct() {
        let ids = (0..<200).map { _ in IRCaptureProfileID.generatedUserID() }
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id.namespace == IRCaptureProfileID.userNamespace)
            #expect(!id.isReserved)
        }
    }

    // MARK: - useCamera

    @Test("useCamera sets the scope to specificCamera and fills both fields")
    func useCameraSetsScopeAndFields() {
        var draft = IRCaptureProfileDraft(name: "X")
        #expect(draft.cameraScope == .anyCamera)

        draft.useCamera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3")

        #expect(draft.cameraScope == .specificCamera)
        #expect(draft.cameraMake == "OLYMPUS IMAGING CORP.")
        #expect(draft.cameraModel == "E-PL3")
    }
}
