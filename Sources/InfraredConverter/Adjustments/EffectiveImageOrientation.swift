import Foundation

/// The derivation that keeps a file's recorded orientation and a user's
/// correction apart while producing the one orientation the pixels are
/// actually permuted by.
///
/// ```text
/// source          what the decoder reported — an immutable fact about the file
/// userAdjustment  what the user asked for   — an application-owned edit
/// applied         source composed with the adjustment, in that order
/// ```
///
/// Three values, three meanings, no collapsing. A caller holding one of these
/// can answer all three questions, which is exactly what provenance needs and
/// what a single `RAWImageOrientation` cannot provide.
///
/// ## The order, and why it is this way round
///
/// ```swift
/// source.composed(with: userAdjustment.transform)   // source first, then the user
/// ```
///
/// The file's own orientation is what makes the stored pixels viewable as the
/// camera intended; the user's correction is applied to what they are looking
/// at. Pressing "rotate right" turns the picture on screen a quarter turn
/// clockwise — not the sensor readout — and that is only true in this order.
///
/// It genuinely matters. Composition does not commute once reflections are
/// involved: a file recording `.transposed` corrected by a quarter turn right
/// gives `.mirroredHorizontally`, while the reverse order gives
/// `.mirroredVertically`. Both are valid orientations and neither looks
/// broken, so the order is pinned by tests rather than by inspection.
///
/// ## Reset
///
/// `userAdjustment == .identity` makes `applied == source`. It does **not**
/// make `applied == .upright`; those are only the same thing for a file that
/// records upright. A file recording a quarter turn still gets its quarter
/// turn after a reset, which is the correct behaviour and the one most easily
/// implemented wrongly.
public struct EffectiveImageOrientation: Equatable, Sendable {

    /// What the decoder reported, mapped once into an application-owned case.
    /// Never modified by anything the user does.
    public let source: RAWImageOrientation

    /// What the user asked for, on top of `source`.
    public let userAdjustment: UserOrientationAdjustment

    public init(source: RAWImageOrientation, userAdjustment: UserOrientationAdjustment) {
        self.source = source
        self.userAdjustment = userAdjustment
    }

    /// The single orientation the pixels are permuted by: `source`, then the
    /// user's adjustment.
    ///
    /// One orientation, applied once, to the unoriented channel-mixed image.
    /// `ImageOrienter` receives this and knows nothing of the two terms it
    /// came from.
    public var applied: RAWImageOrientation {
        source.composed(with: userAdjustment.transform)
    }

    /// Whether the user has asked for any correction.
    public var isUserAdjusted: Bool { !userAdjustment.isIdentity }

    /// Whether the applied orientation differs from what the file asked for.
    ///
    /// Equivalent to `isUserAdjusted`, since composing with a non-identity
    /// element of a group always moves — but stated separately because it is
    /// the question a reader of a rendered image actually has.
    public var differsFromSource: Bool { applied != source }

    /// The adjustment that would return the displayed geometry to upright,
    /// whatever the file recorded.
    ///
    /// Offered for a future "make upright" affordance, and deliberately
    /// distinct from reset: reset restores the file's orientation, this
    /// overrides it.
    public var adjustmentMakingUpright: UserOrientationAdjustment {
        UserOrientationAdjustment(transform: source.inverse)
    }

    /// A short description of all three facts, for diagnostics and the
    /// inspector.
    public var diagnosticDescription: String {
        "\(source.diagnosticDescription) + user \(userAdjustment.diagnosticDescription)"
            + " → \(applied.diagnosticDescription)"
    }
}
