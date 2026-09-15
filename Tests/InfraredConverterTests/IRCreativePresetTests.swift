import Testing
import Foundation
@testable import InfraredConverter

/// The creative-preset domain: identity, the draft that gates it, and the
/// filter hint that must never take part in a single arithmetic decision.
///
/// Wire format is `IRCreativePresetRecordTests`, the file store is
/// `FileIRCreativePresetStoreTests`, and the library is
/// `IRCreativePresetLibraryTests`. This suite is about the value types alone.
@Suite("IRCreativePreset")
struct IRCreativePresetTests {

    /// A preset a test can build, with sensible defaults and a fresh identity
    /// per call so tests do not collide with one another.
    static func makePreset(
        id: IRCreativePresetID = .generatedUserID(),
        name: String = "Test Preset",
        channelMix: UserChannelMixAdjustment = .identity,
        filter: IRFilterDescriptor = .unknown
    ) -> IRCreativePreset {
        IRCreativePreset(id: id, name: name, channelMix: channelMix, filter: filter)
    }

    // MARK: - Identity: malformed tokens

    @Test(
        "A malformed identifier token is refused at the boundary",
        arguments: [
            "",                      // empty
            "no-namespace",          // not namespace-qualified
            "user.",                 // empty trailing segment
            ".user",                 // empty namespace
            "user..double",          // empty middle segment
            "User.Preset",           // uppercase: two spellings of one identity
            "user.has space",        // space
            "user.has/slash",        // path separator
            "user.has_underscore",   // underscore is not in the alphabet
            String(repeating: "a", count: 130),                 // too long, no namespace at all
            "user." + String(repeating: "a", count: 65),        // one segment too long
        ]
    )
    func aMalformedIdentifierTokenIsRefused(token: String) {
        #expect(throws: IRCreativePresetError.self) {
            _ = try IRCreativePresetID(token)
        }
    }

    // MARK: - Identity: generated identities

    /// `generatedUserID()` must never mint something its own validator would
    /// refuse, and it must never wander into the reserved namespace. Proved
    /// over many draws rather than once, because a UUID collision or a
    /// spelling mistake in the format string is not something a single call
    /// would catch.
    @Test("generatedUserID() produces valid, unreserved, distinct identities")
    func generatedUserIDsAreValidAndDistinct() {
        let ids = (0..<200).map { _ in IRCreativePresetID.generatedUserID() }
        #expect(Set(ids).count == ids.count)
        for id in ids {
            #expect(id.namespace == IRCreativePresetID.userNamespace)
            #expect(!id.isReserved)
            let uuidPart = id.rawValue.dropFirst(IRCreativePresetID.userNamespace.count + 1)
            #expect(UUID(uuidString: String(uuidPart)) != nil, "\(id.rawValue)")
        }
    }

    // MARK: - Identity: the reserved namespace, in both directions

    @Test("builtin. is reserved, and no generated identity ever claims it")
    func builtinNamespaceIsReserved() throws {
        #expect(try IRCreativePresetID("builtin.anything").isReserved)
        #expect(try !IRCreativePresetID("user.anything").isReserved)
        #expect(try !IRCreativePresetID("vendor.anything").isReserved)
        for _ in 0..<50 {
            #expect(!IRCreativePresetID.generatedUserID().isReserved)
        }
    }

    @Test("A draft refuses to become a preset in the builtin namespace")
    func aDraftRefusesAReservedIdentifier() throws {
        let draft = IRCreativePresetDraft(name: "Impostor")
        let id = try IRCreativePresetID("builtin.something")
        #expect(
            throws: IRCreativePresetDraftError.reservedIdentifier(
                id: id, namespace: IRCreativePresetID.builtinNamespace
            )
        ) {
            _ = try draft.makePreset(id: id, channelMix: .identity)
        }
    }

    // MARK: - A name is not an identity

    /// The reason identity is generated rather than derived: two presets a
    /// person calls the same thing are two presets, never one.
    @Test("Two presets created with the same display name get distinct identities")
    func sameNameDistinctIdentities() throws {
        let draft = IRCreativePresetDraft(name: "720 sky")
        let first = try draft.makePreset(id: .generatedUserID(), channelMix: .redBlueSwap)
        let second = try draft.makePreset(id: .generatedUserID(), channelMix: .redBlueSwap)

        #expect(first.name == second.name)
        #expect(first.id != second.id)
    }

    // MARK: - The draft: refusals

    @Test("An empty or whitespace-only name is refused")
    func emptyNameIsRefused() throws {
        for name in ["", "   ", "\n\t"] {
            let draft = IRCreativePresetDraft(name: name)
            #expect(throws: IRCreativePresetDraftError.emptyName) {
                _ = try draft.makePreset(id: .generatedUserID(), channelMix: .identity)
            }
        }
    }

    @Test("refusal is nil exactly when makePreset(id:channelMix:) would succeed")
    func refusalAgreesWithMakePreset() {
        let valid = IRCreativePresetDraft(name: "Valid")
        #expect(valid.refusal == nil)

        let invalid = IRCreativePresetDraft(name: "")
        #expect(invalid.refusal == .emptyName)
    }

    // MARK: - The draft: editing an existing preset

    @Test("The draft for an existing preset carries its name and filter, not its identity or mix")
    func draftForExistingPresetCarriesNameAndFilter() throws {
        let filter = try IRFilterDescriptor.longPass(nominalNanometers: 720)
        let preset = Self.makePreset(name: "Original", channelMix: .redBlueSwap, filter: filter)
        let draft = IRCreativePresetDraft(preset)

        #expect(draft.name == "Original")
        #expect(try draft.filter.resolved() == filter)
    }

    @Test("Renaming through a draft preserves identity, mix and filter — only the name changes")
    func renamingThroughADraftPreservesEverythingElse() throws {
        let filter = try IRFilterDescriptor.longPass(nominalNanometers: 590)
        let original = Self.makePreset(name: "Before", channelMix: .redBlueSwap, filter: filter)

        var draft = IRCreativePresetDraft(original)
        draft.name = "After"
        let renamed = try draft.makePreset(id: original.id, channelMix: original.channelMix)

        #expect(renamed.id == original.id)
        #expect(renamed.name == "After")
        #expect(renamed.channelMix == original.channelMix)
        #expect(renamed.filter == original.filter)
    }

    // MARK: - The filter hint takes part in no arithmetic

    /// The load-bearing claim of the whole hint: two presets that differ only
    /// in what filter they are suggested for must resolve to exactly the same
    /// processing decision. Nothing may read the hint to change a matrix.
    @Test("Two presets with the same mix but different filter hints produce the same mix")
    func filterHintDoesNotAffectTheMix() throws {
        let mix = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [0, 0, 1, 0, 1, 0, 1, 0, 0]
        )
        let withoutHint = Self.makePreset(channelMix: mix, filter: .unknown)
        let withHint = Self.makePreset(
            channelMix: mix, filter: try IRFilterDescriptor.longPass(nominalNanometers: 720)
        )

        #expect(withoutHint.channelMix == withHint.channelMix)
        #expect(withoutHint.channelMix.matrix == withHint.channelMix.matrix)
        #expect(withoutHint.channelMix.mix == withHint.channelMix.mix)
    }

    @Test("Changing only a preset's filter hint changes nothing about its matrix")
    func changingTheFilterHintChangesNothingElse() throws {
        let mix = UserChannelMixAdjustment.redBlueSwap
        let preset = Self.makePreset(name: "Sky", channelMix: mix, filter: .unknown)
        let reHinted = IRCreativePreset(
            id: preset.id, name: preset.name, channelMix: preset.channelMix,
            filter: try IRFilterDescriptor.longPass(nominalNanometers: 830)
        )

        #expect(reHinted.channelMix == preset.channelMix)
        #expect(reHinted.channelMix.matrix == preset.channelMix.matrix)
        #expect(reHinted.id == preset.id)
        #expect(reHinted.name == preset.name)
    }

    // MARK: - Calibration honesty

    /// A wavelength is a family label, never a measurement, and a preset must
    /// say so exactly as a capture profile does — a name and a number are not
    /// evidence.
    @Test("No creative preset is ever a validated infrared calibration")
    func nothingClaimsCalibration() throws {
        let plain = Self.makePreset()
        let withWavelength = Self.makePreset(
            name: "Calibrated 720 nm", channelMix: .redBlueSwap,
            filter: try IRFilterDescriptor.longPass(nominalNanometers: 720)
        )
        for preset in [plain, withWavelength] {
            #expect(!preset.isValidatedInfraredCalibration)
        }
    }

    // MARK: - What the hint says about itself

    @Test("A preset with no filter hint reports so honestly")
    func noFilterHintIsHonest() {
        let preset = Self.makePreset(filter: .unknown)
        #expect(!preset.hasFilterHint)
        #expect(preset.filterLabel == nil)
        #expect(preset.diagnosticDescription.contains("no filter recorded"))
    }

    @Test("A nominal wavelength hint labels itself as nominal, never as measured")
    func aWavelengthHintLabelsItselfAsNominal() throws {
        let preset = Self.makePreset(filter: try IRFilterDescriptor.longPass(nominalNanometers: 720))
        #expect(preset.hasFilterHint)
        #expect(preset.filterLabel?.contains("nominal") == true)
        #expect(preset.diagnosticDescription.contains("context label, not a calibration"))
    }

    @Test("A named filter hint labels itself by name")
    func aNamedFilterHintLabelsItselfByName() {
        let preset = Self.makePreset(filter: .named("Hoya R72"))
        #expect(preset.hasFilterHint)
        #expect(preset.filterLabel == "Hoya R72")
    }

    // MARK: - Provenance is not collapsed

    /// A person's authored matrix stays `.explicit` even when its nine numbers
    /// happen to equal a built-in's — the whole point of a `Kind` distinct from
    /// the numbers, restated where a preset actually carries one.
    @Test("An authored matrix equal to the identity's numbers stays .explicit")
    func anAuthoredIdentityMatrixStaysExplicit() throws {
        let explicitIdentity = try UserChannelMixAdjustment.explicit(
            persistedMatrix: [1, 0, 0, 0, 1, 0, 0, 0, 1]
        )
        let preset = Self.makePreset(channelMix: explicitIdentity)

        #expect(preset.channelMix.kind == .matrix)
        #expect(preset.channelMix != .identity)
        #expect(preset.channelMix.matrix == RAWColorMatrix3x3.identity)
    }
}
