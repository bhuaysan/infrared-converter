import Foundation

/// The white-balance gains, each paired with the colour plane it multiplies
/// and with what the sensor's own layout says that plane is.
///
/// ## Why this type exists
///
/// `RAWWhiteBalanceGains` is four numbers addressed by CFA colour-plane index
/// and nothing else, deliberately: the gains are literal multipliers and the
/// primitive that carries them has no business knowing what colour any plane
/// is. But four bare numbers cannot be *read* by a person. An infrared gain
/// set is routinely far from a visible-light one, and
///
/// ```text
/// 1.000  2.143  4.827  2.097
/// ```
///
/// says nothing about which of those is the blue plane that was lifted nearly
/// five stops, or that the last number is a second green measured
/// independently of the first.
///
/// This type answers that question once, from the layout, so that no view has
/// to:
///
/// ```text
/// P0 R ×1.000
/// P1 G ×2.143
/// P2 B ×4.827
/// P3 G ×2.097
/// ```
///
/// ## The layout is the authority, and RGGB is never assumed
///
/// Two facts come from `RAWMetadata.SensorColorLayout` and from nowhere else:
///
/// ```text
/// which planes exist      RAWWhiteBalanceEstimator.colorPlanes(in:)
/// what each plane is      layout.colorDescription, indexed by plane
/// ```
///
/// Plane enumeration is delegated to the estimator's own helper rather than
/// reimplemented, because the set of planes a listing describes must be the
/// same set the estimator measured — a second walk of the CFA cell here could
/// disagree with the one that produced the gains. And a plane index is mapped
/// to a letter through `colorDescription`, which is the file's own statement of
/// what its planes are: `RGBG`, `GBTG`, `RGBE` and `GMCY` all occur, and a
/// hard-coded `["R", "G", "B", "G"]` would mislabel three of them.
///
/// A letter outside `R`, `G` and `B` yields a `nil` `channel` and keeps its
/// letter, which is the honest reading: `RAWLinearRGBChannel` refuses to invent
/// an RGB channel for an emerald or a CMY filter (see
/// `RAWLinearRGBChannel.init(colorDescriptionLetter:)`), and the label can
/// still name the plane the file named.
///
/// ## Two greens stay two greens
///
/// An `RGBG` layout has four reachable planes and two of them are green, and
/// they are listed separately because the pipeline balanced them separately.
/// Collapsing them here would hide the one comparison most likely to matter on
/// a converted camera.
///
/// ## Presentation, not processing
///
/// Nothing multiplies a pixel by anything in this file, and no stage reads it.
/// It is a derived description of an estimate that has already been applied,
/// which is why it lives beside the gains rather than inside any engine.
public struct RAWWhiteBalanceGainListing: Equatable, Sendable {

    /// One colour plane: its index, what the layout calls it, and its gain.
    public struct Entry: Equatable, Sendable {

        /// The CFA colour-plane index the gain is addressed by.
        public let colorPlane: Int

        /// The letter this plane has in the layout's `colorDescription`, or
        /// `nil` if the description is too short to name it.
        public let colorDescriptionLetter: Character?

        /// The linear RGB channel the letter names, or `nil` for a letter that
        /// names no RGB channel (`E`, `C`, `M`, `Y`) and for an unnamed plane.
        public let channel: RAWLinearRGBChannel?

        /// The literal multiplier this plane's samples were multiplied by.
        public let gain: Float

        init(
            colorPlane: Int,
            colorDescriptionLetter: Character?,
            channel: RAWLinearRGBChannel?,
            gain: Float
        ) {
            self.colorPlane = colorPlane
            self.colorDescriptionLetter = colorDescriptionLetter
            self.channel = channel
            self.gain = gain
        }

        /// The plane's identity, as short as it can be without being a guess:
        /// `P1 G`, or `P1` for a plane the layout does not name.
        public var label: String {
            guard let colorDescriptionLetter else { return "P\(colorPlane)" }
            return "P\(colorPlane) \(colorDescriptionLetter)"
        }

        /// The multiplier, to three decimals — enough to distinguish two
        /// independently measured greens.
        public var gainDescription: String { String(format: "×%.3f", gain) }

        public var diagnosticDescription: String { "\(label) \(gainDescription)" }
    }

    /// One entry per colour plane the layout produces, in ascending plane
    /// order. Never a fixed four: a three-plane layout has three.
    public let entries: [Entry]

    /// Pairs an estimate's gains with the layout they are indexed by.
    ///
    /// Throws the estimator's own refusal for a layout that has no CFA colour
    /// planes to describe — a Foveon, a pre-interpolated buffer, or a pattern
    /// this build cannot read. Such a layout could not have produced gains
    /// through the neutral-patch estimator in the first place, so for any
    /// applied estimate this cannot throw; it is `throws` rather than a
    /// silently empty listing because "this sensor has no colour planes" and
    /// "this sensor's planes are unlabelled" are different facts.
    public init(
        gains: RAWWhiteBalanceGains,
        sensorColorLayout layout: RAWMetadata.SensorColorLayout
    ) throws {
        let planes = try RAWWhiteBalanceEstimator.colorPlanes(in: layout)
        let letters = Array(layout.colorDescription)

        entries = try planes.map { plane in
            // `colorPlanes(in:)` has already refused any plane outside the
            // gain model's range, so this cannot fail. Written out rather than
            // forced: the typed refusal is the right thing to surface if that
            // ever stops being true.
            guard let gain = gains.gain(forColorPlane: plane) else {
                throw RAWProcessingError.unsupportedColorPlaneIndex(colorPlane: plane)
            }
            let letter = plane >= 0 && plane < letters.count ? letters[plane] : nil
            return Entry(
                colorPlane: plane,
                colorDescriptionLetter: letter,
                channel: letter.flatMap(RAWLinearRGBChannel.init(colorDescriptionLetter:)),
                gain: gain
            )
        }
    }

    /// The colour planes described, ascending.
    public var colorPlanes: [Int] { entries.map(\.colorPlane) }

    /// The entries whose letter names one linear RGB channel — two of them for
    /// the green of an `RGBG` layout.
    public func entries(for channel: RAWLinearRGBChannel) -> [Entry] {
        entries.filter { $0.channel == channel }
    }

    public var diagnosticDescription: String {
        entries.map(\.diagnosticDescription).joined(separator: "  ")
    }
}
