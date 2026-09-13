import Testing
import Foundation
@testable import InfraredConverter

/// The reusable capture-profile domain: identity, the descriptors that are
/// metadata, the one field that is not, and what a profile is entitled to claim.
@Suite("IRCaptureProfile")
struct IRCaptureProfileTests {

    // MARK: - Identity

    @Test(
        "A well-formed identifier round-trips through its own string",
        arguments: [
            "builtin.uncalibrated",
            "user.olympus-epl3-720nm",
            "user.3f8c1a02-0b7e-4f8a-9a3e-2f1c6d5b4a90",
            "user.a.deeply.namespaced.one",
            "vendor.someone-else",
        ]
    )
    func aWellFormedIdentifierRoundTrips(token: String) throws {
        let id = try IRCaptureProfileID(token)
        #expect(id.rawValue == token)
        #expect(id.description == token)

        // Persisted as the bare string, because that is what it is.
        let data = try JSONEncoder().encode(id)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(token)\"")
        #expect(try JSONDecoder().decode(IRCaptureProfileID.self, from: data) == id)
    }

    @Test(
        "A malformed identifier is refused at the boundary",
        arguments: [
            "",                       // nothing
            "uncalibrated",           // not namespace-qualified
            "builtin.",               // empty trailing segment
            ".uncalibrated",          // empty namespace
            "builtin..uncalibrated",  // empty middle segment
            "Builtin.Uncalibrated",   // uppercase: two spellings of one identity
            "builtin.unca librated",  // space
            "builtin.unca/librated",  // path separator
            "builtin.unca_librated",  // underscore is not in the alphabet
        ]
    )
    func aMalformedIdentifierIsRefused(token: String) {
        #expect(throws: IRCaptureProfileError.self) {
            _ = try IRCaptureProfileID(token)
        }
    }

    @Test("Length is bounded on the whole identifier and on each segment")
    func lengthIsBounded() throws {
        let longSegment = String(repeating: "a", count: IRCaptureProfileID.maximumSegmentLength)
        #expect(throws: Never.self) { _ = try IRCaptureProfileID("user.\(longSegment)") }
        #expect(throws: IRCaptureProfileError.self) {
            _ = try IRCaptureProfileID("user.\(longSegment)a")
        }

        let manySegments = (0..<40).map { _ in "abcd" }.joined(separator: ".")
        #expect(manySegments.count > IRCaptureProfileID.maximumLength)
        #expect(throws: IRCaptureProfileError.self) {
            _ = try IRCaptureProfileID(manySegments)
        }
    }

    @Test("The namespace is the first segment, and it is descriptive only")
    func theNamespaceIsTheFirstSegment() throws {
        #expect(IRCaptureProfileID.builtinUncalibrated.namespace == "builtin")
        #expect(try IRCaptureProfileID("user.a-b").namespace == "user")
        // Not restricted to a known set: a future build's namespace must not
        // be unreadable by this one for syntactic reasons.
        #expect(try IRCaptureProfileID("vendor.x").namespace == "vendor")
    }

    /// The one literal in the application, built through the checked
    /// initialiser so a malformed constant could not sneak past validation.
    @Test("The built-in identifier is what the sidecar writes")
    func theBuiltInIdentifierIsStable() {
        #expect(IRCaptureProfileID.builtinUncalibrated.rawValue == "builtin.uncalibrated")
    }

    // MARK: - The filter descriptor

    @Test("A filter descriptor round-trips through its cases")
    func filterDescriptorsRoundTrip() throws {
        #expect(IRFilterDescriptor.unknown.nominalCutoffNanometers == nil)
        #expect(!IRFilterDescriptor.unknown.isKnown)

        let longPass = try IRFilterDescriptor.longPass(nominalNanometers: 720)
        #expect(longPass.nominalCutoffNanometers == 720)
        #expect(longPass.isKnown)
        #expect(longPass == .longPass(nominalCutoffNanometers: 720))

        let named = IRFilterDescriptor.named("Hoya R72")
        #expect(named.isKnown)
        #expect(named.nominalCutoffNanometers == nil)
        #expect(named.shortDescription == "Hoya R72")
    }

    @Test(
        "A nominal cutoff that cannot describe a real filter is refused",
        arguments: [0.0, -720, .nan, .infinity, -.infinity, 199, 2001, 1e12]
    )
    func anImpossibleNominalCutoffIsRefused(nanometers: Double) {
        #expect(throws: IRCaptureProfileDescriptorError.self) {
            _ = try IRFilterDescriptor.longPass(nominalNanometers: nanometers)
        }
    }

    @Test(
        "The nominal range is generous enough for the filters people buy",
        arguments: [550.0, 590, 665, 720, 760, 830, 850, 950, 1000]
    )
    func realFiltersAreAccepted(nanometers: Double) throws {
        let filter = try IRFilterDescriptor.longPass(nominalNanometers: nanometers)
        #expect(filter.nominalCutoffNanometers == nanometers)
    }

    /// The wording is the point. A wavelength is a family label, and the
    /// descriptions have to be unmistakable about that wherever they appear.
    @Test("A wavelength never describes itself as measured")
    func aWavelengthIsNeverDescribedAsMeasured() throws {
        let filter = try IRFilterDescriptor.longPass(nominalNanometers: 720)
        #expect(filter.shortDescription.contains("nominal"))
        #expect(filter.diagnosticDescription.contains("not a measured spectral response"))
        #expect(IRFilterDescriptor.named("Hoya R72").diagnosticDescription.contains("no spectral data"))
    }

    // MARK: - The sensor conversion

    /// The distinction `CLAUDE.md` insists on: a full-spectrum body and a
    /// 720 nm filter are two facts, not one.
    @Test("A conversion and a filter are separate facts")
    func aConversionAndAFilterAreSeparate() throws {
        let full = IRSensorConversion.fullSpectrum(vendor: "Kolari")
        #expect(full.internalFilter == nil)
        #expect(full.conversionVendor == "Kolari")
        #expect(full.isKnown)

        let internalIR = IRSensorConversion.internalInfrared(
            filter: try IRFilterDescriptor.longPass(nominalNanometers: 720)
        )
        #expect(internalIR.internalFilter?.nominalCutoffNanometers == 720)
        #expect(internalIR.conversionVendor == nil)

        // And they are not equal to each other, nor to "unknown".
        #expect(full != internalIR)
        #expect(IRSensorConversion.unknown != IRSensorConversion.factorySensor)
        #expect(!IRSensorConversion.unknown.isKnown)
    }

    @Test("Unknown does not claim the camera is unmodified")
    func unknownIsNotAClaim() {
        #expect(
            IRSensorConversion.unknown.diagnosticDescription
                .contains("not a claim that the camera is stock")
        )
        #expect(IRSensorConversion.factorySensor.isKnown)
    }

    // MARK: - Camera matching

    private static func metadata(make: String?, model: String?) -> RAWMetadata {
        var metadata = RAWTestData.metadata()
        metadata.identity = RAWMetadata.Identity(make: make, model: model)
        return metadata
    }

    private static func cameraProfile(
        make: String = "OLYMPUS IMAGING CORP.", model: String = "E-PL3"
    ) -> IRCaptureProfile {
        IRCaptureProfile(
            id: try! IRCaptureProfileID("user.epl3-720nm"),
            name: "E-PL3 720 nm",
            cameraMatch: .camera(make: make, model: model),
            processingBasis: .uncalibratedSensorRGB
        )
    }

    @Test("An exact match, modulo case and surrounding whitespace, matches")
    func anExactMatchMatches() {
        let profile = Self.cameraProfile()
        #expect(
            profile.applicability(
                to: Self.metadata(make: "OLYMPUS IMAGING CORP.", model: "E-PL3")
            ) == .matches
        )
        #expect(
            profile.applicability(
                to: Self.metadata(make: "  olympus imaging corp. ", model: "e-pl3\n")
            ) == .matches
        )
    }

    /// No fuzzy matching, deliberately. `E-PL3` and `EPL3` are different
    /// spellings, and deciding they are the same is the beginning of guessing.
    @Test(
        "A different camera is a typed mismatch, and near-misses are mismatches",
        arguments: [
            ("SONY", "ILCE-7"),
            ("OLYMPUS IMAGING CORP.", "E-PL5"),
            ("OLYMPUS IMAGING CORP.", "EPL3"),
            ("OLYMPUS", "E-PL3"),
        ]
    )
    func aDifferentCameraIsAMismatch(make: String, model: String) {
        let profile = Self.cameraProfile()
        let applicability = profile.applicability(to: Self.metadata(make: make, model: model))
        #expect(!applicability.isApplicable)
        #expect(
            applicability
                == .cameraMismatch(
                    profile: profile.id,
                    expectedMake: "OLYMPUS IMAGING CORP.",
                    expectedModel: "E-PL3",
                    foundMake: make,
                    foundModel: model
                )
        )
        let error = try? #require(applicability.error)
        #expect(error?.failureReason?.contains(model) == true)
    }

    /// Distinct from a mismatch on purpose: a mismatch is a known
    /// disagreement, this is an absence of evidence.
    @Test(
        "A file that names no camera is unknown, not mismatched",
        arguments: [(nil, nil), ("OLYMPUS IMAGING CORP.", nil), (nil, "E-PL3"), ("", "")]
            as [(String?, String?)]
    )
    func aFileWithNoCameraIsUnknown(make: String?, model: String?) {
        let profile = Self.cameraProfile()
        let applicability = profile.applicability(to: Self.metadata(make: make, model: model))
        #expect(!applicability.isApplicable)
        #expect(
            applicability
                == .cameraUnknown(
                    profile: profile.id,
                    expectedMake: "OLYMPUS IMAGING CORP.",
                    expectedModel: "E-PL3"
                )
        )
    }

    /// The built-in profile does no camera-specific processing at all, so it
    /// applies to everything — including a file that names no camera.
    @Test("The built-in uncalibrated profile applies to any photograph")
    func theBuiltInProfileAppliesToAnything() {
        let profile = IRCaptureProfile.builtinUncalibrated
        #expect(profile.cameraMatch == .any)
        #expect(!profile.cameraMatch.isCameraSpecific)
        for metadata in [
            Self.metadata(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
            Self.metadata(make: "SONY", model: "ILCE-7"),
            Self.metadata(make: nil, model: nil),
        ] {
            #expect(profile.applicability(to: metadata) == .matches)
            #expect(profile.applicability(to: metadata).error == nil)
        }
    }

    // MARK: - The processing basis

    /// The whole claim that lets a metadata-only profile change cost a render
    /// rather than a re-preparation: the basis is the only thing that reaches
    /// a pixel.
    @Test("The processing basis is the only route from a profile to a pixel")
    func theBasisIsTheOnlyRouteToAPixel() throws {
        let a = IRCaptureProfile(
            id: try IRCaptureProfileID("user.a"),
            name: "A",
            cameraMatch: .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
            sensorConversion: .fullSpectrum(vendor: "Kolari"),
            filter: try IRFilterDescriptor.longPass(nominalNanometers: 720),
            processingBasis: .uncalibratedSensorRGB
        )
        let b = IRCaptureProfile(
            id: try IRCaptureProfileID("user.b"),
            name: "B",
            cameraMatch: .any,
            sensorConversion: .unknown,
            filter: .unknown,
            processingBasis: .uncalibratedSensorRGB
        )
        #expect(a != b)
        #expect(a.processingBasis == b.processingBasis)
        #expect(a.cameraToWorkingTransform == b.cameraToWorkingTransform)
    }

    /// Exactly today's behaviour, which is what makes the migration
    /// pixel-neutral.
    @Test("The uncalibrated basis is the identity false-colour axis assignment")
    func theUncalibratedBasisIsTodaysTransform() {
        let basis = IRCaptureProcessingBasis.uncalibratedSensorRGB
        #expect(basis.cameraToWorkingTransform == .sensorRGBIdentityFalseColor)
        #expect(basis.cameraToWorkingTransform.matrix == .identity)
        #expect(basis.cameraToWorkingTransform.workingColorSpace == .extendedLinearSRGB)
        #expect(basis.cameraToWorkingTransform.source == .sensorRGBIdentityFalseColor)
    }

    // MARK: - Calibration honesty

    /// Derived from the transform's own provenance, never asserted — and a
    /// named camera, a named vendor and a nominal wavelength change none of it.
    @Test("No profile this build ships is a validated infrared calibration")
    func nothingClaimsCalibration() throws {
        #expect(!IRCaptureProfile.builtinUncalibrated.isValidatedInfraredCalibration)
        #expect(!IRCaptureProcessingBasis.uncalibratedSensorRGB.isValidatedInfraredCalibration)

        let dressedUp = IRCaptureProfile(
            id: try IRCaptureProfileID("user.dressed-up"),
            name: "Calibrated 720 nm",
            cameraMatch: .camera(make: "OLYMPUS IMAGING CORP.", model: "E-PL3"),
            sensorConversion: .internalInfrared(
                filter: try IRFilterDescriptor.longPass(nominalNanometers: 720),
                vendor: "A Vendor"
            ),
            filter: try IRFilterDescriptor.longPass(nominalNanometers: 720),
            processingBasis: .uncalibratedSensorRGB
        )
        // A name, a camera, a vendor and a wavelength. None of them is
        // evidence, and the property says so.
        #expect(!dressedUp.isValidatedInfraredCalibration)

        for profile in [IRCaptureProfile.builtinUncalibrated, dressedUp] {
            #expect(
                profile.processingBasis.diagnosticDescription.contains("uncalibrated")
            )
        }
    }

    @Test("The built-in profile is the one every historical record migrates to")
    func theBuiltInProfileIsTheMigrationTarget() {
        let profile = IRCaptureProfile.builtinUncalibrated
        #expect(profile.id == .builtinUncalibrated)
        #expect(profile.cameraMatch == .any)
        #expect(profile.sensorConversion == .unknown)
        #expect(profile.filter == .unknown)
        #expect(profile.processingBasis == .uncalibratedSensorRGB)
        #expect(!profile.isValidatedInfraredCalibration)
        // And the name does not flatter it.
        #expect(profile.name.lowercased().contains("uncalibrated"))
    }
}

/// Where profile definitions live, and what it refuses.
@Suite("IRCaptureProfileRegistry")
struct IRCaptureProfileRegistryTests {

    @Test("The built-in registry always has the uncalibrated profile")
    func theBuiltInProfileAlwaysExists() throws {
        let registry = IRCaptureProfileRegistry.builtin
        #expect(registry.contains(.builtinUncalibrated))
        #expect(try registry.profile(for: .builtinUncalibrated) == .builtinUncalibrated)
        #expect(registry.uncalibratedProfile == .builtinUncalibrated)
        // Exactly one, in this milestone, and the count is pinned so that
        // adding a production profile is a deliberate act.
        #expect(registry.count == 1)
        #expect(registry.allProfiles == [.builtinUncalibrated])
    }

    @Test("An unknown identifier is an explicit failure, never a substitute")
    func anUnknownIdentifierFails() throws {
        let id = try IRCaptureProfileID("user.does-not-exist")
        #expect(!IRCaptureProfileRegistry.builtin.contains(id))
        #expect(throws: IRCaptureProfileError.unknownProfile(id: id)) {
            _ = try IRCaptureProfileRegistry.builtin.profile(for: id)
        }
    }

    @Test("Listing is deterministic and sorted by identity, not by name")
    func listingIsDeterministic() throws {
        let profiles = try [
            ("user.zebra", "Aardvark"),
            ("user.aardvark", "Zebra"),
            ("builtin.uncalibrated", "Uncalibrated / Generic"),
        ].map { id, name in
            IRCaptureProfile(
                id: try IRCaptureProfileID(id),
                name: name,
                processingBasis: .uncalibratedSensorRGB
            )
        }
        let registry = try IRCaptureProfileRegistry(profiles: profiles)
        let listed = registry.allProfiles.map(\.id.rawValue)
        #expect(listed == ["builtin.uncalibrated", "user.aardvark", "user.zebra"])
        // Twice running, so no dictionary ordering leaks into a picker.
        #expect(registry.allProfiles.map(\.id.rawValue) == listed)
    }

    /// Refused at construction rather than resolved by "last one wins": which
    /// of the two a photograph meant would then depend on an ordering nobody
    /// chose.
    @Test("Two profiles claiming one identity are refused")
    func duplicateIdentitiesAreRefused() throws {
        let id = try IRCaptureProfileID("user.duplicate")
        #expect(throws: IRCaptureProfileError.duplicateProfileID(id: id)) {
            _ = try IRCaptureProfileRegistry(
                profiles: [
                    IRCaptureProfile(id: id, name: "First", processingBasis: .uncalibratedSensorRGB),
                    IRCaptureProfile(id: id, name: "Second", processingBasis: .uncalibratedSensorRGB),
                ]
            )
        }
    }

    /// Even a registry a test builds without it can still render: the
    /// uncalibrated profile is returned as a value rather than looked up.
    @Test("The uncalibrated profile is available from any registry")
    func theUncalibratedProfileIsAlwaysAvailable() throws {
        let registry = try IRCaptureProfileRegistry(profiles: [])
        #expect(registry.count == 0)
        #expect(registry.uncalibratedProfile == .builtinUncalibrated)
        #expect(!registry.contains(.builtinUncalibrated))
    }

    @Test("The refusals carry readable reasons")
    func theRefusalsAreInformative() throws {
        let unknown = IRCaptureProfileError.unknownProfile(
            id: try IRCaptureProfileID("user.gone")
        )
        #expect(unknown.errorDescription?.isEmpty == false)
        #expect(unknown.failureReason?.contains("user.gone") == true)
        // It says, in words, that nothing was substituted.
        #expect(unknown.failureReason?.contains("substituted") == true)

        let invalid = IRCaptureProfileError.invalidProfileID(token: "Nope", reason: "uppercase")
        #expect(invalid.failureReason?.contains("Nope") == true)

        let mismatch = IRCaptureProfileError.cameraMismatch(
            id: try IRCaptureProfileID("user.epl3"),
            expectedMake: "OLYMPUS IMAGING CORP.",
            expectedModel: "E-PL3",
            foundMake: "SONY",
            foundModel: "ILCE-7"
        )
        #expect(mismatch.errorDescription?.isEmpty == false)
        #expect(mismatch.failureReason?.contains("SONY") == true)

        let basis = IRCaptureProfileError.processingBasisMismatch(
            prepared: .builtinUncalibrated, requested: try IRCaptureProfileID("user.other")
        )
        #expect(basis.errorDescription?.isEmpty == false)
        #expect(basis.failureReason?.contains("user.other") == true)
    }
}
