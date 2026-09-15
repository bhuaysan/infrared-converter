import Foundation

/// A filter being described in a form, as opposed to one that is described.
///
/// ```text
/// IRFilterDraft         mutable, possibly invalid, what a form holds
/// IRFilterDescriptor    immutable, valid, what the domain stores
/// ```
///
/// The split is `IRCaptureProfileDraft`'s, applied to the one field that has
/// to exist in more than one form. A form holds `"72"` on the way to `"720"`,
/// and an empty product name until somebody types one; `IRFilterDescriptor`
/// has neither of those states and must not learn them.
///
/// ## Why it is a type of its own rather than a nested one
///
/// Because three different forms now describe a filter, and there must not be
/// three parsers:
///
/// ```text
/// capture profile   the filter on the lens
/// capture profile   the filter fitted inside a converted body
/// creative preset   the filter family a reusable mix is suggested for
/// ```
///
/// Those are three different *facts*, and describing them is one operation.
/// A second implementation of "text into a nominal cutoff" would be a second
/// notion of what "720 nm" is, which is precisely what
/// `docs/decisions/0024-reusable-creative-presets.md` refuses.
/// `IRCaptureProfileDraft.FilterDraft` remains the name the profile editor
/// uses, as an alias for this type.
///
/// ## Invalid input is refused, never normalised
///
/// A cutoff of `0` does not quietly become `.unknown`, and an empty product
/// name does not quietly become one either. Both would record a different
/// filter from the one a person was describing, without telling them.
/// Everything is trimmed, because surrounding whitespace is a typing artefact
/// rather than a decision, and nothing else is changed.
public struct IRFilterDraft: Equatable, Sendable {

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
    /// - Throws: `IRFilterDraftError`.
    public func resolved() throws(IRFilterDraftError) -> IRFilterDescriptor {
        switch kind {
        case .unknown:
            return .unknown

        case .longPass:
            let token = nominalCutoffNanometers.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !token.isEmpty else {
                throw .missingNominalCutoff
            }
            // Locale-independent on purpose. A file written on one machine is
            // read on another, and a decimal comma that parsed here and not
            // there would make a record load in one place and refuse in the
            // other.
            guard let nanometers = Double(token) else {
                throw .invalidNominalCutoff(
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
                    throw .invalidNominalCutoff(token: token, reason: reason)
                }
            } catch {
                throw .invalidNominalCutoff(
                    token: token, reason: error.localizedDescription
                )
            }

        case .named:
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw .emptyFilterName }
            return .named(trimmed)
        }
    }

    /// Prefills the draft from a filter already recorded somewhere else — a
    /// capture profile's, typically.
    ///
    /// **A copy, made once, because somebody pressed something.** The value is
    /// then the draft's own: whatever it was copied from may afterwards be
    /// edited, renamed or deleted, and this draft — and anything saved from it
    /// — is unaffected. It is a prefill and never a binding. See
    /// `docs/decisions/0024-reusable-creative-presets.md`, Decision 7.
    public static func prefilled(from descriptor: IRFilterDescriptor) -> IRFilterDraft {
        IRFilterDraft(descriptor)
    }

    private static func format(_ nanometers: Double) -> String {
        nanometers == nanometers.rounded()
            ? String(Int(nanometers))
            : String(nanometers)
    }
}

/// Why a filter draft could not become a descriptor.
///
/// Deliberately says nothing about *which* filter it is: a draft does not know
/// whether it is describing the filter on a lens, one inside a body, or the
/// family a creative preset is suggested for. The form that owns it adds that,
/// because only the form knows.
public enum IRFilterDraftError: Error, Equatable {

    /// A named filter was chosen and no name was given.
    case emptyFilterName

    /// A long-pass filter was chosen and no cutoff was given.
    case missingNominalCutoff

    /// A cutoff was given that could not describe a real filter.
    case invalidNominalCutoff(token: String, reason: String)
}
