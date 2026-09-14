import Foundation

/// How widely a calibration's camera identity is claimed to hold.
public enum IRCalibrationBodyScope: String, Equatable, Sendable, Codable {

    /// Measured on one body, and claimed only for that body.
    ///
    /// The honest default when a serial number is known. Two bodies of one
    /// model do not share infrared behaviour after conversion: the replacement
    /// filter glass, its thickness, and how carefully it was cut differ per
    /// unit, and that is exactly the part of the optical path a calibration is
    /// characterising.
    case specificBody

    /// Claimed for the model rather than the individual body.
    ///
    /// A stronger claim, and one that needs evidence from more than one body
    /// before it is worth making. Nothing here verifies it; recording it is how
    /// a reader knows which claim was intended.
    case modelLevel
}

/// The camera a calibration was measured on.
///
/// Make and model alone are not enough for a converted body, so a serial
/// number is carried where one is available — but it is **optional**, because
/// no decoder in this project is guaranteed to expose one and requiring it
/// would make a real measurement unrecordable for a file that simply does not
/// have the field.
public struct IRCalibrationBodyIdentity: Equatable, Sendable {

    public let make: String
    public let model: String

    /// The body's serial number, where the file recorded one.
    public let serialNumber: String?

    public let scope: IRCalibrationBodyScope

    public init(
        make: String,
        model: String,
        serialNumber: String? = nil,
        scope: IRCalibrationBodyScope
    ) throws(IRCalibrationError) {
        let make = make.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let serial = serialNumber?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !make.isEmpty else {
            throw .missingRequiredField(
                field: "captureContext.camera.make",
                reason: "A calibration that does not say which camera it is for cannot be applied to one."
            )
        }
        guard !model.isEmpty else {
            throw .missingRequiredField(
                field: "captureContext.camera.model",
                reason: "A calibration that does not say which camera it is for cannot be applied to one."
            )
        }
        // Refused whatever the scope, rather than quietly dropped for one of
        // them: somebody who passed a serial number meant to record one, and
        // normalising an empty string to "no serial" would silently weaken the
        // claim the evidence makes about which body this is.
        if let serial, serial.isEmpty {
            throw .missingRequiredField(
                field: "captureContext.camera.serialNumber",
                reason: "An empty serial number is not a serial number; leave it absent instead."
            )
        }

        self.make = make
        self.model = model
        self.serialNumber = serial
        self.scope = scope
    }

    /// The camera match a profile would need in order to be a candidate for
    /// this calibration.
    public var cameraMatch: IRCameraMatch { .camera(make: make, model: model) }

    public var shortDescription: String {
        let base = "\(make) \(model)"
        guard let serialNumber else { return base }
        return "\(base) (serial \(serialNumber))"
    }

    public var diagnosticDescription: String {
        switch scope {
        case .specificBody:
            return """
                \(shortDescription), claimed for this body only\
                \(serialNumber == nil ? " (no serial number recorded)" : "")
                """
        case .modelLevel:
            return "\(shortDescription), claimed for the model"
        }
    }
}

/// The filter that was on the lens, described richly enough to identify the
/// physical object.
///
/// ``IRFilterDescriptor`` — what a capture profile carries — is deliberately
/// one of *either* a nominal cutoff *or* a product name, which is the right
/// shape for a thing a person picks from a menu. Calibration evidence needs
/// more: "720 nm" is a family label shared by filters that are not
/// interchangeable, and a calibration tied to one physical piece of glass
/// should say whose it was and, where it matters, which batch.
///
/// This is a richer **snapshot** rather than a redesign of
/// `IRFilterDescriptor`, so nothing a person already saved changes shape.
public struct IRCalibrationFilterSnapshot: Equatable, Sendable {

    public let manufacturer: String?
    public let product: String?

    /// The nominal cutoff the manufacturer prints on the box.
    ///
    /// A *family label*, never a measured spectral response. A marketed 720 nm
    /// long-pass filter has a transition band tens of nanometres wide and
    /// per-batch variation, and nothing in this project matches, selects or
    /// interpolates by wavelength.
    public let nominalCutoffNanometers: Double?

    /// Serial, batch, or anything else that distinguishes this piece of glass
    /// from another of the same product.
    public let notes: String?

    public init(
        manufacturer: String? = nil,
        product: String? = nil,
        nominalCutoffNanometers: Double? = nil,
        notes: String? = nil
    ) throws(IRCalibrationError) {
        func clean(_ value: String?) -> String? {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed?.isEmpty ?? true) ? nil : trimmed
        }

        if let nominalCutoffNanometers {
            guard nominalCutoffNanometers.isFinite else {
                throw .nonFiniteValue(
                    field: "captureContext.filter.nominalCutoffNanometers",
                    value: nominalCutoffNanometers
                )
            }
            guard IRFilterDescriptor.supportedNominalCutoffNanometers
                .contains(nominalCutoffNanometers)
            else {
                throw .valueOutOfRange(
                    field: "captureContext.filter.nominalCutoffNanometers",
                    value: nominalCutoffNanometers,
                    reason: """
                        A nominal cutoff is expected between \
                        \(IRFilterDescriptor.supportedNominalCutoffNanometers.lowerBound) and \
                        \(IRFilterDescriptor.supportedNominalCutoffNanometers.upperBound) \
                        nanometres, which is the same range a capture profile accepts.
                        """
                )
            }
        }

        self.manufacturer = clean(manufacturer)
        self.product = clean(product)
        self.nominalCutoffNanometers = nominalCutoffNanometers
        self.notes = clean(notes)
    }

    /// A snapshot built from what a capture profile happened to carry.
    ///
    /// The lossy direction, and the one a measurement path can offer without
    /// asking a person to retype anything. A profile's `.named("Hoya R72")`
    /// becomes a product with no manufacturer and no cutoff; `.longPass(720)`
    /// becomes a cutoff with no product. Neither is as good as a person filling
    /// the fields in, which is why the completeness rules say so.
    public init(_ descriptor: IRFilterDescriptor) throws(IRCalibrationError) {
        switch descriptor {
        case .unknown:
            try self.init()
        case .longPass(let nanometers):
            try self.init(nominalCutoffNanometers: nanometers)
        case .named(let name):
            try self.init(product: name)
        }
    }

    /// Whether the filter is described at all.
    public var isDescribed: Bool {
        manufacturer != nil || product != nil || nominalCutoffNanometers != nil
    }

    public var shortDescription: String {
        var parts: [String] = []
        if let manufacturer { parts.append(manufacturer) }
        if let product { parts.append(product) }
        if let nominalCutoffNanometers {
            parts.append("\(Self.format(nominalCutoffNanometers)) nm nominal")
        }
        return parts.isEmpty ? "Unknown filter" : parts.joined(separator: " ")
    }

    public var diagnosticDescription: String {
        isDescribed
            ? "\(shortDescription)\(notes.map { " [\($0)]" } ?? "") (nominal identity, not a measured spectral response)"
            : "filter not described"
    }

    private static func format(_ nanometers: Double) -> String {
        nanometers == nanometers.rounded()
            ? String(Int(nanometers))
            : String(format: "%.1f", nanometers)
    }
}

/// The physical configuration a calibration was measured against, snapshotted
/// at the moment of measurement.
///
/// ## Why a snapshot and not a profile reference
///
/// This is the most important decision in the evidence model. A capture profile
/// is a **mutable, shared** definition: a person may edit it, and doing so
/// changes what every photograph referencing it resolves to. If a calibration
/// recorded only "measured for profile P", then:
///
/// ```text
/// profile P calibrated for a Hoya R72 on a converted E-PL3
///   → user edits P, changing the filter to 590 nm
///   → the calibration still says "P"
///   → its provenance is now false, and nothing detected it
/// ```
///
/// So the calibration carries the camera, the conversion and the filter *as
/// they were*, by value. The profile identity is kept too, but only as
/// context — it is never the description of what was measured.
///
/// The snapshot is also what a future applicability check compares against: a
/// calibration measured for an E-PL3 with a 720 nm filter must not be
/// attachable to a Sony body with a 590 nm one. Matching **validates** a choice
/// a person made; it never makes one.
public struct IRCalibrationCaptureContext: Equatable, Sendable {

    public let camera: IRCalibrationBodyIdentity
    public let sensorConversion: IRSensorConversion
    public let filter: IRCalibrationFilterSnapshot

    /// The capture profile the measurement was taken under, where there was
    /// one.
    ///
    /// Context only. It says who was doing the measuring, not what was
    /// measured — that is the three fields above, and they are by value
    /// precisely so that editing this profile cannot change what this
    /// calibration claims.
    public let measuredUnderProfile: IRCaptureProfileID?

    public init(
        camera: IRCalibrationBodyIdentity,
        sensorConversion: IRSensorConversion,
        filter: IRCalibrationFilterSnapshot,
        measuredUnderProfile: IRCaptureProfileID? = nil
    ) {
        self.camera = camera
        self.sensorConversion = sensorConversion
        self.filter = filter
        self.measuredUnderProfile = measuredUnderProfile
    }

    public var diagnosticDescription: String {
        """
        \(camera.diagnosticDescription), \(sensorConversion.diagnosticDescription), \
        \(filter.diagnosticDescription)
        """
    }
}

/// Whether a calibration may be attached to a capture profile.
public enum IRCalibrationApplicability: Equatable, Sendable {

    case matches

    case cameraMismatch(expected: String, found: String)

    /// The profile does not name a camera at all, so there is nothing to check.
    ///
    /// Refused rather than waved through: a calibration is measured on a
    /// specific optical path, and "any camera" is the one claim it can never
    /// support.
    case profileCameraUnspecified(expected: String)

    case sensorConversionMismatch(expected: String, found: String)

    case filterMismatch(expected: String, found: String)

    public var isApplicable: Bool { self == .matches }
}

extension IRCalibrationCaptureContext {

    /// Whether this calibration's measured context matches a profile's current
    /// capture context.
    ///
    /// ```text
    /// camera make + model      must match, case- and whitespace-insensitively
    /// sensor conversion        must be equal
    /// filter                   nominal cutoff must agree where both state one;
    ///                          product name must agree where both state one
    /// ```
    ///
    /// Exact rather than approximate, and refusing rather than warning. The
    /// failure this prevents is a calibration measured for one optical path
    /// being applied to another, which produces a plausible-looking image that
    /// is wrong in a way nobody can see.
    ///
    /// The filter rule is the loosest of the three, deliberately: a profile
    /// carries *either* a cutoff or a product name while a calibration snapshot
    /// may carry both, so the comparison checks the facts they have in common
    /// and does not demand a field the profile has no way to express. Agreement
    /// on a nominal wavelength is **not** evidence that two filters are the
    /// same filter; it is the weakest check that still catches the mistake
    /// worth catching.
    ///
    /// Nothing calls this in production yet: no capture profile can reference a
    /// calibration, because no calibration in this project is validated. It is
    /// the gate that goes in front of that reference the day one is. See
    /// `docs/decisions/0022-calibration-evidence-and-measurement-protocol.md`.
    public func applicability(to profile: IRCaptureProfile) -> IRCalibrationApplicability {
        guard case .camera(let make, let model) = profile.cameraMatch else {
            return .profileCameraUnspecified(expected: camera.shortDescription)
        }
        guard Self.normalize(make) == Self.normalize(camera.make),
              Self.normalize(model) == Self.normalize(camera.model)
        else {
            return .cameraMismatch(
                expected: "\(camera.make) \(camera.model)", found: "\(make) \(model)"
            )
        }

        guard profile.sensorConversion == sensorConversion else {
            return .sensorConversionMismatch(
                expected: sensorConversion.shortDescription,
                found: profile.sensorConversion.shortDescription
            )
        }

        switch profile.filter {
        case .unknown:
            guard !filter.isDescribed else {
                return .filterMismatch(
                    expected: filter.shortDescription, found: "Unknown"
                )
            }
        case .longPass(let nanometers):
            guard let expected = filter.nominalCutoffNanometers else {
                return .filterMismatch(
                    expected: filter.shortDescription,
                    found: "\(nanometers) nm nominal"
                )
            }
            guard expected == nanometers else {
                return .filterMismatch(
                    expected: filter.shortDescription,
                    found: "\(nanometers) nm nominal"
                )
            }
        case .named(let name):
            guard let product = filter.product else {
                return .filterMismatch(expected: filter.shortDescription, found: name)
            }
            guard Self.normalize(product) == Self.normalize(name) else {
                return .filterMismatch(expected: filter.shortDescription, found: name)
            }
        }

        return .matches
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
