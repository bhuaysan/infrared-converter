import Foundation

/// Per-CFA-colour-plane linear white-balance multipliers.
///
/// ## Indexed by colour plane, not by channel
///
/// The index is the **CFA colour-plane index** the sensor layout returns from
/// `RAWMetadata.SensorColorLayout.colorPlaneIndex(row:column:)`, and there are
/// four slots because that lookup can return `3` — even on a sensor whose
/// `colorCount` is `3`.
///
/// The reference camera is exactly that case:
///
/// ```text
/// colorDescription = "RGBG"
/// colorCount       = 3
///
/// plane 0 = R
/// plane 1 = G1
/// plane 2 = B
/// plane 3 = G2   ← real, reachable, and not covered by colorCount
/// ```
///
/// Sizing this model from `colorCount` would therefore be wrong, and reducing
/// a plane index modulo `colorCount` would silently alias the second green
/// onto the red gain. Four slots, addressed literally, avoid both.
///
/// ## G1 and G2 are independent
///
/// `plane1` and `plane3` are separate values and this type never forces them
/// to agree. The CFA model exposes the two green positions as distinct planes,
/// and some sensors and metadata treat them differently, so collapsing them
/// here would delete information the primitive is supposed to carry. A future
/// estimator or UI may choose to link them; that is a policy decision made
/// above this type, not inside it.
///
/// ## Gains are literal
///
/// Whatever is stored here is what gets multiplied. See `RAWWhiteBalancer` for
/// the full statement of that contract — in particular, nothing normalises
/// green to `1` or divides through by the largest gain.
///
/// ## Not temperature and tint
///
/// Infrared white balance regularly lands far outside the assumptions behind
/// visible-light correlated-colour-temperature models, so the core
/// representation is direct multipliers. Any Kelvin/tint control a later UI
/// offers must resolve down to values of this type; it is not the other way
/// round. See `docs/decisions/0003-infrared-white-balance.md`.
public struct RAWWhiteBalanceGains: Equatable, Sendable {
    /// How many CFA colour-plane slots this model carries.
    public static let planeCount = 4

    /// Multiplier for CFA colour plane `0` — red on an RGBG layout.
    public var plane0: Float
    /// Multiplier for CFA colour plane `1` — the first green on an RGBG
    /// layout. Independent of `plane3`.
    public var plane1: Float
    /// Multiplier for CFA colour plane `2` — blue on an RGBG layout.
    public var plane2: Float
    /// Multiplier for CFA colour plane `3` — the second green on an RGBG
    /// layout. A real plane index even when `colorCount == 3`, and
    /// independent of `plane1`.
    public var plane3: Float

    public init(plane0: Float, plane1: Float, plane2: Float, plane3: Float) {
        self.plane0 = plane0
        self.plane1 = plane1
        self.plane2 = plane2
        self.plane3 = plane3
    }

    /// All-ones. Multiplying by this leaves every finite value bit-identical.
    public static let identity = RAWWhiteBalanceGains(
        plane0: 1, plane1: 1, plane2: 1, plane3: 1
    )

    /// The multiplier for a CFA colour-plane index, or `nil` when the index
    /// is outside `0..<planeCount` and this model has no slot for it.
    ///
    /// O(1) and allocation-free: a switch over four stored properties, not a
    /// dictionary lookup, because callers run this once per sample.
    public func gain(forColorPlane index: Int) -> Float? {
        switch index {
        case 0: return plane0
        case 1: return plane1
        case 2: return plane2
        case 3: return plane3
        default: return nil
        }
    }

    /// The four multipliers in colour-plane order, for provenance and
    /// diagnostics. Not for the per-sample path.
    public var gainsByColorPlane: [Float] { [plane0, plane1, plane2, plane3] }

    /// Rejects gains that cannot describe a multiplication.
    ///
    /// A gain must be finite and strictly greater than zero. There is
    /// deliberately **no upper bound**: infrared white balance can need
    /// multipliers far outside anything visible-light processing would use,
    /// and an arbitrary ceiling here would quietly rule out legitimate IR
    /// work. `0.01`, `20` and `100` are all valid.
    ///
    /// Zero is rejected because it discards a plane rather than balancing it,
    /// and negatives because they invert the sign of every sample in a plane;
    /// neither is white balance, and a caller that wants either should be
    /// forced to say so through some other stage.
    ///
    /// - Throws: `RAWProcessingError.invalidWhiteBalanceGain`.
    public func validate() throws {
        for index in 0..<Self.planeCount {
            // `gain(forColorPlane:)` cannot return nil for these indices.
            guard let value = gain(forColorPlane: index) else { continue }
            guard value.isFinite, value > 0 else {
                throw RAWProcessingError.invalidWhiteBalanceGain(
                    colorPlane: index,
                    value: value
                )
            }
        }
    }
}
