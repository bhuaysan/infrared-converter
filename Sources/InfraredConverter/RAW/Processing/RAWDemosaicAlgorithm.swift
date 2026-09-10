import Foundation

/// Which application-owned demosaicing algorithm reconstructed a full-colour
/// image from a CFA mosaic.
///
/// This is **not** `RAWDecodeOptions.Demosaic`. That enum selects one of
/// LibRaw's own algorithms on the legacy processed-RGB path
/// (`LibRawDecoder.decode(at:options:)`), where LibRaw also applies black
/// levels, white balance, a colour matrix and gamma. This one names an
/// algorithm implemented in this project, running on this project's own
/// `WhiteBalancedRAWMosaic`, with no LibRaw involvement whatsoever. The two
/// must not be conflated; see `docs/decisions/0005-application-owned-bayer-demosaicing.md`.
///
/// Exactly one case exists. Cases are added when the algorithm exists, never
/// before: a case for an unimplemented algorithm would let a caller select
/// something that silently falls back to another one.
public enum RAWDemosaicAlgorithm: Equatable, Sendable {
    /// Bilinear interpolation over a repeating 2×2 Bayer RGB mosaic.
    ///
    /// A deterministic reference implementation, chosen for being exactly
    /// specifiable and hand-checkable rather than for image quality. It does
    /// no edge detection, no chroma smoothing, no false-colour suppression
    /// and no highlight handling, so it produces the zippering and colour
    /// fringing every naive bilinear demosaicer produces. Its job is to
    /// establish the mosaic → camera-native-RGB boundary correctly and
    /// testably, not to be the final algorithm.
    case bilinearBayer
}

/// One channel of linear, camera-native RGB.
///
/// ## These are sensor responses, not colour-space coordinates
///
/// `red`, `green` and `blue` name **which colour filter on the sensor
/// produced the value**, resolved through the layout's `colorDescription`.
/// They are not coordinates in sRGB, linear sRGB, Display P3, Adobe RGB,
/// ProPhoto RGB, XYZ, ACES, or any other device-independent space, and no
/// camera colour matrix has been applied by the time these exist. Two
/// different cameras' `red` values are not comparable. See
/// `DemosaicedRAWRGBImage`.
public enum RAWLinearRGBChannel: Equatable, Sendable, CaseIterable {
    case red
    case green
    case blue

    /// This channel's offset inside one interleaved `R G B` pixel.
    public var storageOffset: Int {
        switch self {
        case .red: return 0
        case .green: return 1
        case .blue: return 2
        }
    }

    /// The single letter `RAWMetadata.SensorColorLayout.colorDescription`
    /// uses for this channel.
    public var colorDescriptionLetter: Character {
        switch self {
        case .red: return "R"
        case .green: return "G"
        case .blue: return "B"
        }
    }

    /// The channel a `colorDescription` letter names, or `nil` for any other
    /// letter.
    ///
    /// Only `R`, `G` and `B` participate. LibRaw's `cdesc` can also carry
    /// `E` (emerald, on RGBE sensors) and `C`/`M`/`Y` (CMY-filtered
    /// sensors), and this deliberately refuses them rather than mapping them
    /// onto the nearest RGB channel: a four-filter or subtractive mosaic is
    /// not a Bayer RGB mosaic, and pretending otherwise would invent colour.
    ///
    /// Matching is exact and uppercase, which is what LibRaw produces.
    public init?(colorDescriptionLetter letter: Character) {
        switch letter {
        case "R": self = .red
        case "G": self = .green
        case "B": self = .blue
        default: return nil
        }
    }
}

/// Three `Float32` values for one demosaiced pixel: a convenience returned by
/// `DemosaicedRAWRGBImage.pixel(row:column:)`.
///
/// This is **not** the image's storage representation. The image owns a
/// tightly packed `[Float]` of exactly three floats per pixel; a
/// `SIMD3<Float>` or a struct-of-three-floats array would be allowed a
/// 16-byte stride, silently turning a 148 MB buffer into a 197 MB one. This
/// type exists only to hand one pixel back to a caller.
public struct RAWLinearRGBPixel: Equatable, Sendable {
    public let red: Float
    public let green: Float
    public let blue: Float

    public init(red: Float, green: Float, blue: Float) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The value of one channel.
    public func value(_ channel: RAWLinearRGBChannel) -> Float {
        switch channel {
        case .red: return red
        case .green: return green
        case .blue: return blue
        }
    }
}
