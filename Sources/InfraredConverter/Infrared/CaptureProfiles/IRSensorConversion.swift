import Foundation

/// What was done to the camera body itself, before any filter was screwed onto
/// the lens.
///
/// ```text
/// unknown             nobody recorded it
/// factorySensor       an unmodified camera, with its hot-mirror in place
/// fullSpectrum        the hot-mirror was removed and nothing put back
/// internalInfrared    an infrared filter was fitted inside, in its place
/// ```
///
/// ## Why this is not the same field as the filter
///
/// It is the distinction `CLAUDE.md` insists on, and it is easy to lose:
///
/// ```text
/// full-spectrum body + 720 nm filter on the lens     720 nm capture, filter removable
/// body converted internally to 720 nm                720 nm capture, filter permanent
/// full-spectrum body, no filter                      not a 720 nm capture at all
/// ```
///
/// The first two record similar light and are different cameras; the third
/// shares a conversion with the first and records something else entirely.
/// Collapsing either pair into one field would make "full spectrum" and
/// "720 nm" look like alternative spellings of each other, and they are not.
///
/// So a capture profile carries **both**: this, and an `IRFilterDescriptor`.
/// A body converted internally carries its permanent filter here, because that
/// filter is part of the conversion rather than something a photographer chose
/// per frame.
///
/// ## Two bodies of one model are not one camera
///
/// `CLAUDE.md`: *do not assume two bodies of the same camera model have
/// identical IR behaviour after physical conversion.* Which is why
/// `conversionVendor` exists and is optional, and why nothing in this project
/// derives a conversion from a camera model.
public enum IRSensorConversion: Equatable, Sendable {

    /// Nothing is recorded about the body's conversion state.
    ///
    /// The honest default, and what the built-in profile carries. It is not a
    /// claim that the camera is unmodified — that is `factorySensor`.
    case unknown

    /// An unmodified camera: the factory sensor stack, hot-mirror included.
    case factorySensor

    /// The internal infrared-blocking filter was removed and not replaced, so
    /// the sensor sees visible and near-infrared light together.
    ///
    /// - Parameter vendor: who performed the conversion, when it is known.
    ///   Recorded because conversions differ between vendors even for one
    ///   camera model; never used for matching.
    case fullSpectrum(vendor: String? = nil)

    /// An infrared filter was fitted inside the body, in place of the
    /// hot-mirror, so every photograph this camera takes is filtered.
    ///
    /// - Parameters:
    ///   - filter: the permanently fitted filter, as far as it is known.
    ///   - vendor: who performed the conversion, when it is known.
    case internalInfrared(filter: IRFilterDescriptor, vendor: String? = nil)

    /// Who performed the conversion, where that is recorded.
    public var conversionVendor: String? {
        switch self {
        case .unknown, .factorySensor: return nil
        case .fullSpectrum(let vendor): return vendor
        case .internalInfrared(_, let vendor): return vendor
        }
    }

    /// The filter built into the body, for the one case that has one.
    ///
    /// Deliberately **not** merged with the profile's own filter descriptor:
    /// one is part of the camera and the other is screwed onto the lens, and a
    /// capture can have both.
    public var internalFilter: IRFilterDescriptor? {
        guard case .internalInfrared(let filter, _) = self else { return nil }
        return filter
    }

    /// Whether anything at all is recorded about the conversion.
    public var isKnown: Bool { self != .unknown }

    /// A label for the inspector.
    public var shortDescription: String {
        switch self {
        case .unknown:
            return "Unknown"
        case .factorySensor:
            return "Factory sensor"
        case .fullSpectrum(let vendor):
            return vendor.map { "Full spectrum (\($0))" } ?? "Full spectrum"
        case .internalInfrared(let filter, let vendor):
            let base = "Internal IR — \(filter.shortDescription)"
            return vendor.map { "\(base) (\($0))" } ?? base
        }
    }

    /// A longer label for diagnostics and provenance reports.
    public var diagnosticDescription: String {
        switch self {
        case .unknown:
            return "unknown sensor conversion (none recorded; not a claim that the camera is stock)"
        case .factorySensor:
            return "factory sensor, unmodified"
        case .fullSpectrum(let vendor):
            return "full-spectrum conversion"
                + (vendor.map { " by \($0)" } ?? " (converter unrecorded)")
        case .internalInfrared(let filter, let vendor):
            return "internal infrared conversion, \(filter.diagnosticDescription)"
                + (vendor.map { ", by \($0)" } ?? "")
        }
    }
}
