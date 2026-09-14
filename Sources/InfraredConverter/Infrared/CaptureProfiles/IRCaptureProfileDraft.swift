import Foundation

/// A capture profile being written, as opposed to one that exists.
///
/// ```text
/// IRCaptureProfileDraft    mutable, possibly invalid, what a form holds
/// IRCaptureProfile         immutable, valid, what the library stores
/// ```
///
/// The split exists so the domain type never has to become partially valid.
/// A form has a half-typed camera model in it, a wavelength field containing
/// `"72"` on the way to `"720"`, and a name that is empty until somebody types
/// one; an `IRCaptureProfile` has none of those states and must not learn them.
/// So the interface edits this, and `makeProfile(id:)` is the single gate
/// between the two. See
/// `docs/decisions/0021-user-capture-profile-library.md`.
///
/// ## Invalid input is refused, never normalised
///
/// A blank camera model does not quietly become `.any`; a cutoff of `0` does
/// not quietly become `unknown`. Either would save a profile describing a
/// different capture configuration from the one a person was describing, and
/// they would not be told. Everything is trimmed, because surrounding
/// whitespace is a typing artefact rather than a decision, and nothing else is
/// changed.
///
/// ## The processing basis is not a field
///
/// It is `uncalibratedSensorRGB`, always, and it is not offered. Every profile
/// this milestone can create is explicitly uncalibrated, because no measured
/// data exists for any camera, conversion or filter in this project — and a
/// form that let a person choose a camera transform would be a calibration
/// editor wearing a profile editor's clothes. There is deliberately no
/// "calibrated" checkbox either: validation is something the project performs
/// and reports, not something a user asserts.
public struct IRCaptureProfileDraft: Equatable, Sendable {

    /// Whether the profile names a camera.
    public enum CameraScope: String, CaseIterable, Sendable, Identifiable {
        /// `IRCameraMatch.any` — the profile makes no claim about the camera.
        case anyCamera
        /// `IRCameraMatch.camera(make:model:)`.
        case specificCamera

        public var id: String { rawValue }

        public var shortDescription: String {
            switch self {
            case .anyCamera: return "Any camera"
            case .specificCamera: return "A specific camera"
            }
        }
    }

    /// What was done to the body.
    public enum ConversionKind: String, CaseIterable, Sendable, Identifiable {
        case unknown, factorySensor, fullSpectrum, internalInfrared

        public var id: String { rawValue }

        public var shortDescription: String {
            switch self {
            case .unknown: return "Unknown"
            case .factorySensor: return "Factory sensor"
            case .fullSpectrum: return "Full spectrum"
            case .internalInfrared: return "Internal infrared"
            }
        }

        /// Whether this conversion records who performed it.
        public var hasVendor: Bool {
            switch self {
            case .unknown, .factorySensor: return false
            case .fullSpectrum, .internalInfrared: return true
            }
        }

        /// Whether this conversion has a filter fitted inside the body.
        public var hasInternalFilter: Bool { self == .internalInfrared }
    }

    /// A filter being described: the kind, and the fields that kind uses.
    ///
    /// Used twice — for the filter on the lens and for one fitted inside a
    /// converted body — because those are two facts and the model keeps them
    /// apart.
    public struct FilterDraft: Equatable, Sendable {

        public enum Kind: String, CaseIterable, Sendable, Identifiable {
            case unknown, longPass, named

            public var id: String { rawValue }

            public var shortDescription: String {
                switch self {
                case .unknown: return "Unknown"
                case .longPass: return "Long-pass (nominal nm)"
                case .named: return "Named product"
                }
            }
        }

        public var kind: Kind
        /// The nominal cutoff as typed. A string, because a form holds one.
        public var nominalCutoffNanometers: String
        /// The product name as typed.
        public var name: String

        public init(
            kind: Kind = .unknown,
            nominalCutoffNanometers: String = "",
            name: String = ""
        ) {
            self.kind = kind
            self.nominalCutoffNanometers = nominalCutoffNanometers
            self.name = name
        }

        /// The draft for an existing descriptor, for editing.
        public init(_ descriptor: IRFilterDescriptor) {
            switch descriptor {
            case .unknown:
                self.init(kind: .unknown)
            case .longPass(let nanometers):
                self.init(
                    kind: .longPass,
                    nominalCutoffNanometers: Self.format(nanometers)
                )
            case .named(let name):
                self.init(kind: .named, name: name)
            }
        }

        /// The descriptor this draft describes.
        ///
        /// - Parameter field: which filter this is, so a refusal can say so.
        /// - Throws: `IRCaptureProfileDraftError`.
        public func resolved(
            field: IRCaptureProfileDraftError.Field
        ) throws(IRCaptureProfileDraftError) -> IRFilterDescriptor {
            switch kind {
            case .unknown:
                return .unknown

            case .longPass:
                let token = nominalCutoffNanometers.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !token.isEmpty else {
                    throw .missingNominalCutoff(field: field)
                }
                // Locale-independent on purpose. A profile file written on one
                // machine is read on another, and a decimal comma that parsed
                // here and not there would make a profile load in one place
                // and refuse in the other.
                guard let nanometers = Double(token) else {
                    throw .invalidNominalCutoff(
                        field: field,
                        token: token,
                        reason: "A nominal cutoff must be a number of nanometres."
                    )
                }
                do {
                    return try IRFilterDescriptor.longPass(nominalNanometers: nanometers)
                } catch let error as IRCaptureProfileDescriptorError {
                    // The descriptor type owns what a usable cutoff is, and its
                    // own wording is carried through rather than restated here.
                    switch error {
                    case .invalidNominalCutoff(_, let reason):
                        throw .invalidNominalCutoff(
                            field: field, token: token, reason: reason
                        )
                    }
                } catch {
                    throw .invalidNominalCutoff(
                        field: field, token: token, reason: error.localizedDescription
                    )
                }

            case .named:
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw .emptyFilterName(field: field) }
                return .named(trimmed)
            }
        }

        private static func format(_ nanometers: Double) -> String {
            nanometers == nanometers.rounded()
                ? String(Int(nanometers))
                : String(nanometers)
        }
    }

    /// What a person calls this profile. Never its identity.
    public var name: String

    public var cameraScope: CameraScope
    public var cameraMake: String
    public var cameraModel: String

    public var conversionKind: ConversionKind
    /// Who performed the conversion, where that is known. Optional, always:
    /// an unrecorded converter is an honest state and not a missing field.
    public var conversionVendor: String
    /// The filter fitted inside a converted body, for `internalInfrared`.
    public var internalFilter: FilterDraft

    /// The filter on the lens.
    public var filter: FilterDraft

    /// The processing every profile this milestone creates is given.
    ///
    /// A constant rather than a field, and a static one rather than a stored
    /// one, so that no form can bind to it by accident.
    public static let processingBasis: IRCaptureProcessingBasis = .uncalibratedSensorRGB

    /// Whether a profile made from this draft would be a validated infrared
    /// calibration.
    ///
    /// Always `false`, and derived rather than asserted: it asks the basis,
    /// which asks the transform's own provenance. It exists so the editor can
    /// display the calibration status the same way the inspector does, from the
    /// same source, instead of hard-coding the word "No" in a view.
    public static var isValidatedInfraredCalibration: Bool {
        processingBasis.isValidatedInfraredCalibration
    }

    public init(
        name: String = "",
        cameraScope: CameraScope = .anyCamera,
        cameraMake: String = "",
        cameraModel: String = "",
        conversionKind: ConversionKind = .unknown,
        conversionVendor: String = "",
        internalFilter: FilterDraft = FilterDraft(),
        filter: FilterDraft = FilterDraft()
    ) {
        self.name = name
        self.cameraScope = cameraScope
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.conversionKind = conversionKind
        self.conversionVendor = conversionVendor
        self.internalFilter = internalFilter
        self.filter = filter
    }

    /// The draft for an existing profile, for editing it.
    ///
    /// Editing produces a **new immutable value with the same identity**, which
    /// is why the identifier is not carried here: it belongs to the profile
    /// being replaced, and a draft that could change it would be a way to move
    /// a definition to another profile's address.
    public init(_ profile: IRCaptureProfile) {
        self.init(name: profile.name)

        switch profile.cameraMatch {
        case .any:
            cameraScope = .anyCamera
        case .camera(let make, let model):
            cameraScope = .specificCamera
            cameraMake = make
            cameraModel = model
        }

        switch profile.sensorConversion {
        case .unknown:
            conversionKind = .unknown
        case .factorySensor:
            conversionKind = .factorySensor
        case .fullSpectrum(let vendor):
            conversionKind = .fullSpectrum
            conversionVendor = vendor ?? ""
        case .internalInfrared(let internalFilter, let vendor):
            conversionKind = .internalInfrared
            conversionVendor = vendor ?? ""
            self.internalFilter = FilterDraft(internalFilter)
        }

        filter = FilterDraft(profile.filter)
    }

    /// Prefills the camera from a photograph that is open.
    ///
    /// **Convenience, and only that.** It copies two strings a person can see
    /// and change, and it happens because they pressed something. Nothing in
    /// this project reads a file's make and model and creates or selects a
    /// profile on its own: a camera name says nothing about which filter was on
    /// the lens or what was done to the sensor, and a profile invented from it
    /// would be a guess presented as a record. See
    /// `docs/decisions/0020-ir-capture-profile-foundation.md`, Decision 4.
    public mutating func useCamera(make: String, model: String) {
        cameraScope = .specificCamera
        cameraMake = make
        cameraModel = model
    }

    /// The immutable profile this draft describes, under a given identity.
    ///
    /// The single gate between mutable form state and the domain type. The
    /// identity is a parameter rather than a field because a draft never
    /// chooses one: creation is given a freshly generated identifier, and
    /// editing is given the identifier of the profile being replaced.
    ///
    /// - Throws: `IRCaptureProfileDraftError`.
    public func makeProfile(
        id: IRCaptureProfileID
    ) throws(IRCaptureProfileDraftError) -> IRCaptureProfile {
        guard !id.isReserved else {
            throw .reservedIdentifier(
                id: id, namespace: IRCaptureProfileID.builtinNamespace
            )
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw .emptyName }

        let cameraMatch: IRCameraMatch
        switch cameraScope {
        case .anyCamera:
            cameraMatch = .any
        case .specificCamera:
            let make = cameraMake.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = cameraModel.trimmingCharacters(in: .whitespacesAndNewlines)
            // Both or neither. A profile naming a make and no model would match
            // nothing and mislead everything: `IRCameraMatch` compares both,
            // exactly, and half a camera is not a camera.
            guard !make.isEmpty else { throw .emptyCameraMake }
            guard !model.isEmpty else { throw .emptyCameraModel }
            cameraMatch = .camera(make: make, model: model)
        }

        let vendor = conversionVendor.trimmingCharacters(in: .whitespacesAndNewlines)
        let sensorConversion: IRSensorConversion
        switch conversionKind {
        case .unknown:
            sensorConversion = .unknown
        case .factorySensor:
            sensorConversion = .factorySensor
        case .fullSpectrum:
            sensorConversion = .fullSpectrum(vendor: vendor.isEmpty ? nil : vendor)
        case .internalInfrared:
            sensorConversion = .internalInfrared(
                filter: try internalFilter.resolved(field: .internalFilter),
                vendor: vendor.isEmpty ? nil : vendor
            )
        }

        return IRCaptureProfile(
            id: id,
            name: trimmedName,
            cameraMatch: cameraMatch,
            sensorConversion: sensorConversion,
            filter: try filter.resolved(field: .externalFilter),
            processingBasis: Self.processingBasis
        )
    }

    /// Why this draft cannot be saved yet, or `nil` when it can.
    ///
    /// The same gate as `makeProfile(id:)`, asked without committing to an
    /// identity, so a form can disable its Save button and explain itself
    /// without generating identifiers it may never use.
    ///
    /// A fixed stand-in identity is used rather than a fresh one: this is read
    /// on every keystroke, and minting a UUID per character would make an
    /// identity generator out of a validity check.
    public var refusal: IRCaptureProfileDraftError? {
        do {
            _ = try makeProfile(id: Self.validationID)
            return nil
        } catch {
            return error
        }
    }

    /// A well-formed, unreserved identity used only to ask whether a draft is
    /// valid. It is never saved and never reaches a profile.
    private static let validationID = try! IRCaptureProfileID("user.draft-validation")
}

/// Why a capture-profile draft could not become a profile.
///
/// Value-level refusals from the editor, kept apart from
/// `IRCaptureProfilePersistenceError` — which is about files — and from
/// `IRCaptureProfileError` — which is about resolving and applying a profile
/// that already exists.
public enum IRCaptureProfileDraftError: Error, Equatable {

    /// Which part of the draft a refusal is about.
    public enum Field: String, Sendable {
        /// The filter on the lens.
        case externalFilter
        /// The filter fitted inside a converted body.
        case internalFilter

        public var shortDescription: String {
            switch self {
            case .externalFilter: return "external filter"
            case .internalFilter: return "internal filter"
            }
        }
    }

    /// The display name is empty, or is only whitespace.
    case emptyName

    /// The profile names a specific camera and no make was given.
    case emptyCameraMake

    /// The profile names a specific camera and no model was given.
    case emptyCameraModel

    /// A named filter was chosen and no name was given.
    case emptyFilterName(field: Field)

    /// A long-pass filter was chosen and no cutoff was given.
    case missingNominalCutoff(field: Field)

    /// A cutoff was given that could not describe a real filter.
    case invalidNominalCutoff(field: Field, token: String, reason: String)

    /// The identity offered is in a namespace user profiles may not claim.
    case reservedIdentifier(id: IRCaptureProfileID, namespace: String)
}

extension IRCaptureProfileDraftError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Give the capture profile a name."
        case .emptyCameraMake:
            return "Enter the camera make, or choose \"Any camera\"."
        case .emptyCameraModel:
            return "Enter the camera model, or choose \"Any camera\"."
        case .emptyFilterName(let field):
            return "Enter a name for the \(field.shortDescription)."
        case .missingNominalCutoff(let field):
            return "Enter a nominal cutoff for the \(field.shortDescription)."
        case .invalidNominalCutoff(let field, _, _):
            return "That is not a usable cutoff for the \(field.shortDescription)."
        case .reservedIdentifier:
            return "That capture profile identifier is reserved."
        }
    }

    public var failureReason: String? {
        switch self {
        case .emptyName:
            return """
                The name is what you will recognise this configuration by. It is not the \
                profile's identity, so you can change it later without affecting a single \
                photograph.
                """
        case .emptyCameraMake, .emptyCameraModel:
            return """
                A profile that names a camera is checked against the camera that took each \
                photograph, and both the make and the model take part in that check.
                """
        case .emptyFilterName(let field):
            return "The \(field.shortDescription) is set to a named product and has no name."
        case .missingNominalCutoff(let field):
            return """
                The \(field.shortDescription) is set to a nominal long-pass cutoff and has no \
                value. The number is what the filter is sold as, not a measurement of it.
                """
        case .invalidNominalCutoff(_, let token, let reason):
            return "\"\(token)\": \(reason)"
        case .reservedIdentifier(let id, let namespace):
            return """
                "\(id)" is in the "\(namespace)." namespace, which belongs to the profiles \
                this application ships.
                """
        }
    }
}
