import Foundation

/// Why a creative preset value could not be built, or a library of them
/// composed.
///
/// The value-level boundary, kept apart from
/// `IRCreativePresetPersistenceError` — which is about files —
/// `IRCreativePresetRecordError` — which is about a record's shape — and
/// `IRCreativePresetDraftError` — which is about a half-filled form. The same
/// four-way split the capture-profile types make, for the same reason: a
/// refusal that says which layer refused is one a caller can act on.
public enum IRCreativePresetError: Error, Equatable {

    /// A token that is not a well-formed ``IRCreativePresetID``.
    case invalidPresetID(token: String, reason: String)

    /// Two presets claim one identity.
    ///
    /// Neither is admitted. Choosing one would make which mix a menu entry
    /// applies depend on directory-enumeration order — an answer nobody chose,
    /// that can differ between machines.
    case duplicatePresetID(id: IRCreativePresetID)
}

extension IRCreativePresetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPresetID:
            return "That is not a usable creative preset identifier."
        case .duplicatePresetID:
            return "Two creative presets claim the same identifier."
        }
    }

    public var failureReason: String? {
        switch self {
        case .invalidPresetID(let token, let reason):
            return "\"\(token)\": \(reason)"
        case .duplicatePresetID(let id):
            return """
                More than one stored preset is identified as "\(id)". None of them was \
                loaded: which mix a menu entry applied would otherwise depend on the order \
                the folder happened to be read in.
                """
        }
    }
}
