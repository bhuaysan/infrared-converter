import Foundation

/// Which camera a capture profile was made for.
///
/// ```text
/// any                          the profile makes no claim about the camera
/// camera(make:model:)          it describes one make and model, exactly
/// ```
///
/// ## Matching is exact, and it is never automatic
///
/// Exact normalised string comparison, and nothing else: no fuzzy matching, no
/// model-family heuristics, no "E-PL3 is close enough to E-PL5". The
/// normalisation is the minimum that keeps one camera from failing to match
/// itself — surrounding whitespace and letter case — and is applied to both
/// sides.
///
/// And matching **validates** a selection a person already made; it never makes
/// one. Nothing in this milestone reads a file's make and model and picks a
/// profile from them. See `docs/decisions/0020-ir-capture-profile-foundation.md`.
public enum IRCameraMatch: Equatable, Sendable {

    /// The profile claims nothing about which camera took the photograph, and
    /// therefore applies to any of them.
    ///
    /// What the built-in uncalibrated profile carries. It is not a claim that
    /// the profile is right for every camera — it is a statement that the
    /// profile does no camera-specific processing at all, which is exactly
    /// true of a basis that assigns sensor axes to working axes.
    case any

    /// The profile describes one camera make and model.
    case camera(make: String, model: String)

    /// The make this profile names, if it names one.
    public var make: String? {
        guard case .camera(let make, _) = self else { return nil }
        return make
    }

    /// The model this profile names, if it names one.
    public var model: String? {
        guard case .camera(_, let model) = self else { return nil }
        return model
    }

    /// Whether this profile is tied to a particular camera.
    public var isCameraSpecific: Bool { self != .any }

    /// A label for the inspector.
    public var shortDescription: String {
        switch self {
        case .any: return "Any camera"
        case .camera(let make, let model): return "\(make) \(model)"
        }
    }

    /// Whether a profile carrying this match may be applied to a photograph
    /// with this metadata, and if not, exactly why.
    ///
    /// The identifier is a parameter rather than a stored field because the
    /// answer is about a pairing — this profile, this file — and the typed
    /// result has to be able to name the profile that refused.
    public func applicability(
        to metadata: RAWMetadata, profile id: IRCaptureProfileID
    ) -> IRCaptureProfileApplicability {
        guard case .camera(let expectedMake, let expectedModel) = self else {
            return .matches
        }

        let identity = metadata.identity
        // The decoder's own normalised spellings where it has them, the raw
        // ones otherwise. Both are then normalised here as well, so the
        // comparison does not depend on which of the two the file happened to
        // supply.
        let make = Self.normalize(identity.normalizedMake ?? identity.make)
        let model = Self.normalize(identity.normalizedModel ?? identity.model)

        guard let make, let model else {
            return .cameraUnknown(
                profile: id, expectedMake: expectedMake, expectedModel: expectedModel
            )
        }
        guard make == Self.normalize(expectedMake), model == Self.normalize(expectedModel) else {
            return .cameraMismatch(
                profile: id,
                expectedMake: expectedMake,
                expectedModel: expectedModel,
                foundMake: identity.make,
                foundModel: identity.model
            )
        }
        return .matches
    }

    /// Trimmed and case-folded, and nothing more. Punctuation and internal
    /// spacing are left alone: `E-PL3` and `EPL3` are different spellings of a
    /// model name, and deciding they are the same would be the beginning of
    /// fuzzy matching.
    private static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }
}

/// Whether a capture profile may be used for a particular photograph.
///
/// Three answers rather than a `Bool`, because "no" has two meanings that call
/// for different words in front of a user, and because a caller that has to
/// explain the refusal cannot reconstruct the reason from `false`.
public enum IRCaptureProfileApplicability: Equatable, Sendable {

    /// The profile describes this photograph's camera, or claims no camera.
    case matches

    /// The profile names a camera and the file names a different one.
    case cameraMismatch(
        profile: IRCaptureProfileID,
        expectedMake: String,
        expectedModel: String,
        foundMake: String?,
        foundModel: String?
    )

    /// The profile names a camera and the file names none.
    case cameraUnknown(
        profile: IRCaptureProfileID, expectedMake: String, expectedModel: String
    )

    /// Whether the profile may be applied.
    public var isApplicable: Bool { self == .matches }

    /// The refusal, as the error a caller should surface — `nil` when there is
    /// none.
    ///
    /// The projection exists so that no call site invents its own wording for a
    /// refusal the type already knows how to describe.
    public var error: IRCaptureProfileError? {
        switch self {
        case .matches:
            return nil
        case .cameraMismatch(let id, let expectedMake, let expectedModel, let make, let model):
            return .cameraMismatch(
                id: id,
                expectedMake: expectedMake,
                expectedModel: expectedModel,
                foundMake: make,
                foundModel: model
            )
        case .cameraUnknown(let id, let expectedMake, let expectedModel):
            return .cameraUnknown(
                id: id, expectedMake: expectedMake, expectedModel: expectedModel
            )
        }
    }
}
