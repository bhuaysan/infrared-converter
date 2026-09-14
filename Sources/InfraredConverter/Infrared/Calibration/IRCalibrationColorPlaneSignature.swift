import Foundation

/// Which colour planes the sensor layout produced, and what each one is.
///
/// ```text
/// 0 -> R
/// 1 -> G
/// 2 -> B
/// 3 -> G
/// ```
///
/// ## Why evidence records this rather than inferring it
///
/// An `IRCalibrationPatchMeasurement` carries the planes that were *present*
/// inside its region. Nothing in a list of present planes says which planes
/// were supposed to be there, so a measurement set assembled by hand, or read
/// from a file somebody edited, could carry `0 R, 1 G, 2 B` for every patch of
/// a four-plane RGGB sensor and look complete. The fitter would see red, green
/// and blue, collapse a one-element green "pair", and produce a transform
/// fitted to half the green sites — a calibration of a sensor that does not
/// exist, with nothing anywhere saying so.
///
/// The failure is invisible precisely when it is systematic: a plane missing
/// from *one* patch shows up as an incomplete patch, and a plane missing from
/// *every* patch shows up as nothing at all. Deriving the expectation from the
/// measurements cannot catch it, because the measurements are what is in
/// question.
///
/// So the expectation is recorded separately, from the one authority that
/// knows it — the sensor colour layout at the moment of measurement, read
/// through `IRCalibrationMeasurementPipeline.channelsByColorPlane(in:)`, which
/// is the same reading of `colorDescription` the demosaicer uses. Never a
/// union of the planes the patches happen to contain, never the first patch,
/// and never an assumption that a four-plane mosaic is `0,1,2,3` RGGB.
///
/// See `docs/decisions/0022-calibration-evidence-and-measurement-protocol.md`.
public struct IRCalibrationColorPlaneSignature: Equatable, Sendable {

    /// One colour plane of the layout, and the RGB channel its filter is.
    public struct Entry: Equatable, Sendable {

        /// The CFA colour-plane index, as the decoder's layout numbers them.
        public let colorPlane: Int

        /// Which RGB channel that plane's filter is.
        public let channel: RAWLinearRGBChannel

        public init(colorPlane: Int, channel: RAWLinearRGBChannel) {
            self.colorPlane = colorPlane
            self.channel = channel
        }
    }

    /// The expected planes, ascending by plane index.
    ///
    /// Sorted rather than stored in whatever order a caller supplied, so that
    /// two signatures describing the same layout are equal and encode to the
    /// same bytes. A signature is a description of a sensor, and the order
    /// somebody wrote it down in is not part of that description.
    public let entries: [Entry]

    /// Refuses a signature that cannot describe a layout a 3x3 transform can
    /// be fitted from.
    ///
    /// The three-channel requirement is the same one
    /// `IRCalibrationMeasurementPipeline.channelsByColorPlane(in:)` enforces
    /// against a live sensor, restated here because a signature can also
    /// arrive from a file: a layout with no blue plane does not determine the
    /// blue column of the transform, whatever number of patches is measured.
    public init(_ entries: [Entry]) throws(IRCalibrationError) {
        guard !entries.isEmpty else {
            throw .invalidColorPlaneSignature(
                reason: """
                    A measurement set with no expected colour planes states no expectation at \
                    all, which is the condition this type exists to make impossible.
                    """
            )
        }

        var seen = Set<Int>()
        for entry in entries {
            guard entry.colorPlane >= 0 else {
                throw .invalidColorPlaneSignature(
                    reason: "Colour plane \(entry.colorPlane) is not a plane index."
                )
            }
            guard seen.insert(entry.colorPlane).inserted else {
                throw .invalidColorPlaneSignature(
                    reason: """
                        Colour plane \(entry.colorPlane) appears twice. Which channel it is \
                        would then depend on ordering nobody chose.
                        """
                )
            }
        }

        let represented = Set(entries.map(\.channel))
        for channel in [RAWLinearRGBChannel.red, .green, .blue]
        where !represented.contains(channel) {
            throw .invalidColorPlaneSignature(
                reason: """
                    No plane of this layout is \
                    \(IRCalibrationColorPlaneSignature.name(of: channel)). A 3x3 transform \
                    from its responses is not determined by any number of patches.
                    """
            )
        }

        self.entries = entries.sorted { $0.colorPlane < $1.colorPlane }
    }

    /// The signature the measurement pipeline's reading of the sensor layout
    /// describes.
    ///
    /// Takes the pipeline's own `[plane: channel]` map rather than re-reading
    /// `colorDescription`, so there is exactly one interpretation of a sensor
    /// layout in the calibration path.
    public init(
        channelsByColorPlane: [Int: RAWLinearRGBChannel]
    ) throws(IRCalibrationError) {
        try self.init(
            channelsByColorPlane
                .map { Entry(colorPlane: $0.key, channel: $0.value) }
        )
    }

    /// The expected plane indices, ascending.
    public var colorPlanes: [Int] { entries.map(\.colorPlane) }

    public func channel(forColorPlane plane: Int) -> RAWLinearRGBChannel? {
        entries.first { $0.colorPlane == plane }?.channel
    }

    /// The expected planes belonging to one RGB channel.
    public func colorPlanes(for channel: RAWLinearRGBChannel) -> [Int] {
        entries.filter { $0.channel == channel }.map(\.colorPlane)
    }

    static func name(of channel: RAWLinearRGBChannel) -> String {
        switch channel {
        case .red: return "red"
        case .green: return "green"
        case .blue: return "blue"
        }
    }

    public var diagnosticDescription: String {
        entries
            .map { "\($0.colorPlane) -> \(Self.name(of: $0.channel))" }
            .joined(separator: ", ")
    }
}
