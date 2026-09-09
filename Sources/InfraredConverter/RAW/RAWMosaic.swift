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
    /// What the decoder reports as the source sample width — `12` for the
    /// Olympus E-PL3 — or `nil` when it reported none. For most cameras,
    /// including that one, it is the bit depth of the samples **as stored in
    /// the source file**; see
    /// `RAWMetadata.SensorColorLayout.sourceRawBitDepth` for the formats
    /// where it is not.
    ///
    /// This is `RAWMetadata.SensorColorLayout.sourceRawBitDepth` carried
    /// alongside the data it describes, not re-derived from it.
    ///
    /// ## What it is not
    ///
    /// It is **not** a normalisation white level, and
    /// `2 ^ sourceRawBitDepth - 1` must never be used as one. Three separate
    /// things are easy to conflate here and are deliberately kept apart:
    ///
    /// - *source RAW bit depth* — this property: how wide a sample was in the
    ///   file, before LibRaw touched it, for the formats where LibRaw
    ///   reports it literally;
    /// - *the unpacked sample's numeric domain* — what `unpack()` actually
    ///   produced. Several formats pass samples through a per-format
    ///   linearisation curve inside `unpack()`, which can move values outside
    ///   the source depth's range;
    /// - *white / saturation level* — `RAWMetadata.Levels.maximum` and
    ///   `linearMaximum`, which LibRaw updates to match what it produced.
    ///
    /// A later normalisation stage must take its white level from
    /// `RAWMetadata.Levels`, or from an explicitly chosen white-level model —
    /// never from this property.
    ///
    /// It is optional rather than defaulted: samples are stored in 16-bit
    /// cells regardless, and substituting `16` for an unreported depth would
    /// invent a fact the decoder did not state.
    public let sourceRawBitDepth: Int?
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

    /// The widest source bit depth `sampleFormat`'s storage can represent
    /// without loss. A reported depth above this is a claim the storage
    /// cannot hold, and makes the mosaic inconsistent rather than being
    /// accepted — samples are never rescaled to reconcile the two.
    private var maximumRepresentableBitDepth: Int {
        switch sampleFormat {
        case .uint16: return 16
        }
    }

    public init(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        samples: Data,
        sampleFormat: SampleFormat,
        sourceRawBitDepth: Int?,
        sensorColorLayout: RAWMetadata.SensorColorLayout
    ) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.samples = samples
        self.sampleFormat = sampleFormat
        self.sourceRawBitDepth = sourceRawBitDepth
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
        // An unreported source depth is acceptable. A reported one must be
        // both meaningful (>= 1) and representable in this mosaic's storage:
        // a claim of, say, 24 bits alongside `.uint16` samples cannot be
        // true, and accepting it would leave a later stage to discover the
        // contradiction.
        if let sourceRawBitDepth,
           sourceRawBitDepth < 1 || sourceRawBitDepth > maximumRepresentableBitDepth {
            return false
        }
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
    /// (row:column:)`.
    ///
    /// Never traps, for **any** value the public initialiser accepts. Passing
    /// the row/column bounds check is not sufficient on its own: the
    /// initialiser can build a pathological mosaic — a huge `bytesPerRow`, a
    /// `width` near `Int.max` — for which the offset arithmetic itself
    /// overflows while the coordinate still looks in range. Every multiply
    /// and add below is therefore checked, and any overflow returns `nil`.
    /// Callers are **not** required to consult `isGeometryConsistent` first.
    public func sample(row: Int, column: Int) -> UInt16? {
        guard row >= 0, row < height, column >= 0, column < width else { return nil }

        let (rowOffset, rowOverflow) = row.multipliedReportingOverflow(by: bytesPerRow)
        guard !rowOverflow else { return nil }
        let (columnOffset, columnOverflow) = column.multipliedReportingOverflow(by: bytesPerSampleValue)
        guard !columnOverflow else { return nil }
        let (byteOffset, offsetOverflow) = rowOffset.addingReportingOverflow(columnOffset)
        guard !offsetOverflow, byteOffset >= 0 else { return nil }

        // `samples.startIndex` is 0 for every Data this type is constructed
        // with, but a Data slice can carry a non-zero one, so fold it in with
        // the same checked arithmetic rather than assuming.
        let (base, baseOverflow) = samples.startIndex.addingReportingOverflow(byteOffset)
        guard !baseOverflow else { return nil }
        let (end, endOverflow) = base.addingReportingOverflow(bytesPerSampleValue)
        guard !endOverflow, end <= samples.endIndex else { return nil }

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
