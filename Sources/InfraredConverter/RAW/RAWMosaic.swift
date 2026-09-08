import Foundation

/// One LibRaw-unpacked sample per sensor mosaic location, active area only.
///
/// ## What a sample IS
///
/// Each sample is the value LibRaw's `unpack()` wrote into its single-channel
/// `raw_image` storage for one sensor mosaic position: after LibRaw's
/// format-specific decoding (bit unpacking, byte-order handling, and — for
/// formats that use one — LibRaw's per-format linearisation curve). It is a
/// **LibRaw-unpacked sensor sample**, not a raw ADC value: several formats
/// LibRaw supports pass samples through a decoding curve inside `unpack()`
/// itself (see `Sources/CLibRawVendor/src/decoders/decoders_dcraw.cpp`), so
/// "straight off the sensor" would overstate what this type represents.
///
/// ## What a sample is NOT
///
/// Nothing beyond `unpack()` has run. In particular, a sample here has **not**
/// had any of the following applied:
///
/// - black-level subtraction (`LibRaw::subtract_black` /
///   `LibRaw::adjust_bl`, which also run inside `dcraw_process`)
/// - white-level / saturation normalisation
/// - white balance (camera, daylight, or otherwise)
/// - demosaicing (there is one sample per mosaic location, not one full-colour
///   pixel)
/// - camera or vendor colour-matrix conversion
/// - gamma / any transfer-function encoding
/// - orientation (rotation/flip) handling
///
/// This is verified, not assumed: `unpack()` and everything it calls in
/// `Sources/CLibRawVendor/src/decoders/` never reads `imgdata.params`
/// (LibRaw's output-processing options) — only `dcraw_process` and the
/// preprocessing it triggers do, and this type's producer
/// (`LibRawDecoder.decodeMosaic`) never calls `dcraw_process`. Black-level
/// subtraction specifically runs inside `adjust_bl()` /
/// `subtract_black_internal()`, both reachable only from `dcraw_process` /
/// `raw2image_ex`, neither of which this path calls.
///
/// ## Coordinate convention
///
/// `(0, 0)` is the top-left of the **active image area** — the same
/// active-image convention `RAWMetadata.SensorColorLayout.colorPlaneIndex(row:
/// column:)` and `RAWMetadata.Levels.blackLevel(row:column:colorPlane:)`
/// already use. LibRaw's `top_margin`/`left_margin` are already applied by
/// the extraction that produced this mosaic (LibRaw's optical-black border is
/// excluded); do not apply them again when indexing into `samples`.
public struct RAWMosaic: Equatable, Sendable {
    /// The in-memory representation of one sample.
    ///
    /// Only `.uint16` exists for this milestone: LibRaw's single-channel
    /// `raw_image` storage is always `unsigned short`. Samples are **not**
    /// converted to `Float32`, and 12-bit (or other sub-16-bit) values are
    /// **not** rescaled to fill the `UInt16` range — a 12-bit E-PL3 sample
    /// stays a value in `0...4095`, just stored in a 16-bit cell.
    public enum SampleFormat: Equatable, Sendable {
        case uint16
    }

    /// Width of the active mosaic area, in samples.
    public let width: Int
    /// Height of the active mosaic area, in samples.
    public let height: Int
    /// Byte offset between the starts of consecutive rows. Tightly packed:
    /// `bytesPerRow == width * bytesPerSampleValue`.
    public let bytesPerRow: Int
    /// Tightly packed sample storage, active area only, `sampleFormat`-typed,
    /// little-endian. LibRaw writes native `unsigned short`, and every
    /// platform this project targets (arm64 and x86_64 macOS) is
    /// little-endian, so native and little-endian coincide here; `sample(row:
    /// column:)` decodes explicitly rather than relying on that.
    public let samples: Data
    public let sampleFormat: SampleFormat
    /// Useful precision of each sample, e.g. `12` for the Olympus E-PL3, or
    /// `nil` when the decoder did not report it.
    ///
    /// This is `RAWMetadata.SensorColorLayout.bitsPerRawSample` carried
    /// alongside the data it describes, not re-derived from it. It is
    /// deliberately optional rather than defaulted: the samples are stored in
    /// 16-bit cells regardless, and substituting `16` for an unknown
    /// precision would silently mis-scale the white-level normalisation that
    /// a later stage derives from it.
    public let bitsPerSample: Int?
    /// The sensor's colour-filter layout, needed to interpret each sample's
    /// colour plane. Its `colorPlaneIndex(row:column:)` already uses the same
    /// active-image coordinate convention as this type.
    public let sensorColorLayout: RAWMetadata.SensorColorLayout

    /// Bytes occupied by one sample value. `2` for `.uint16`.
    private var bytesPerSampleValue: Int {
        switch sampleFormat {
        case .uint16: return 2
        }
    }

    public init(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        samples: Data,
        sampleFormat: SampleFormat,
        bitsPerSample: Int?,
        sensorColorLayout: RAWMetadata.SensorColorLayout
    ) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.samples = samples
        self.sampleFormat = sampleFormat
        self.bitsPerSample = bitsPerSample
        self.sensorColorLayout = sensorColorLayout
    }

    /// The minimum row size implied by `width * bytesPerSampleValue`, or
    /// `nil` when that multiplication would overflow `Int`.
    private var minimumRowByteCount: Int? {
        let (perRow, overflow) = width.multipliedReportingOverflow(by: bytesPerSampleValue)
        return overflow ? nil : perRow
    }

    /// The buffer size implied by `bytesPerRow * height`, or `nil` when that
    /// multiplication would overflow `Int`.
    public var expectedByteCount: Int? {
        let (result, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        return overflow ? nil : result
    }

    /// True when `samples` is large enough for the declared geometry and
    /// `bytesPerRow` is consistent with `width * bytesPerSampleValue`.
    ///
    /// Non-positive dimensions, or geometry whose implied byte count would
    /// overflow, make this `false` rather than trap.
    public var isGeometryConsistent: Bool {
        // An unreported precision is acceptable; a reported nonsensical one
        // is not.
        if let bitsPerSample, bitsPerSample <= 0 { return false }
        guard width > 0, height > 0 else { return false }
        guard let minimumRowBytes = minimumRowByteCount, let expected = expectedByteCount else {
            return false
        }
        return bytesPerRow >= minimumRowBytes && samples.count >= expected
    }

    /// The sample at an active-image coordinate, or `nil` when out of bounds.
    ///
    /// `row`/`column` are active-image coordinates: `(0, 0)` is the top-left
    /// of the active mosaic area, matching `sensorColorLayout.colorPlaneIndex
    /// (row:column:)`. Bounds-checked; never traps.
    public func sample(row: Int, column: Int) -> UInt16? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        let byteOffset = row * bytesPerRow + column * bytesPerSampleValue
        guard byteOffset >= 0, byteOffset + bytesPerSampleValue <= samples.count else { return nil }

        let base = samples.startIndex + byteOffset
        switch sampleFormat {
        case .uint16:
            let low = UInt16(samples[base])
            let high = UInt16(samples[base + 1])
            return low | (high << 8)
        }
    }

    /// The colour-plane index sampled at an active-image coordinate,
    /// delegating to `sensorColorLayout.colorPlaneIndex(row:column:)`.
    /// Bounds-checked against this mosaic's own extent first, so an
    /// out-of-range coordinate returns `nil` rather than wrapping onto the
    /// sensor's repeating CFA pattern the way the layout's own lookup would.
    public func colorPlaneIndex(row: Int, column: Int) -> Int? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }
        return sensorColorLayout.colorPlaneIndex(row: row, column: column)
    }
}
