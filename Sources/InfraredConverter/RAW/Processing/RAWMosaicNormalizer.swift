import Foundation

/// The first application-owned RAW processing stage: black subtraction and
/// white-level normalisation, `RAWMosaic` (UInt16) → `LinearRAWMosaic`
/// (Float32).
///
/// ```text
/// LibRawDecoder
///       ↓
/// DecodedRAWMosaic          ← LibRaw's responsibility ends here
///       ↓
/// RAWMosaicNormalizer       ← application-owned, knows nothing about LibRaw
///       ↓
/// LinearRAWMosaic
/// ```
///
/// This type deliberately lives outside the decoder: `LibRawDecoder` must not
/// grow processing stages, and this file must not import `CLibRaw`. It takes
/// decoded values and level metadata and does arithmetic on them — it has no
/// idea which decoder produced them.
///
/// ## What it does
///
/// For every sample, with `black` the effective black level at that
/// coordinate and colour plane and `white` the policy's white level:
///
/// ```text
/// black = levels.blackLevel(row:column:colorPlane:)
/// white = levels.maximum                       (.metadataMaximum policy)
///
/// value = (Float(sample) - Float(black)) / Float(white - black)
/// ```
///
/// ## What it does not do
///
/// No clamping in either direction, no white balance, no demosaicing, no
/// colour matrix, no gamma, no orientation. Values below `0` and above `1`
/// are produced and preserved on purpose; see
/// `docs/decisions/0002-raw-normalization.md`.
public struct RAWMosaicNormalizer: Sendable {
    /// Which white level to normalise against. One policy exists; it is a
    /// parameter rather than a hardcoded read so that a future alternative
    /// is an explicit choice at the call site.
    public let whiteLevelPolicy: RAWWhiteLevelPolicy

    public init(whiteLevelPolicy: RAWWhiteLevelPolicy = .metadataMaximum) {
        self.whiteLevelPolicy = whiteLevelPolicy
    }

    /// Processes a decoder result, keeping the original UInt16 mosaic and its
    /// metadata available on the returned `ProcessedRAWMosaic.source`.
    public func process(_ decoded: DecodedRAWMosaic) throws -> ProcessedRAWMosaic {
        let linear = try process(mosaic: decoded.mosaic, levels: decoded.metadata.levels)
        return ProcessedRAWMosaic(source: decoded, mosaic: linear)
    }

    /// Processes a mosaic against a set of level metadata.
    ///
    /// `levels` must be the levels describing the RAW state `mosaic`'s
    /// samples are in — for `LibRawDecoder.decodeMosaic(at:)` that is the
    /// post-unpack snapshot on the same `DecodedRAWMosaic`. How the effective
    /// black is split between `Levels.black`, `perPlaneBlack` and
    /// `blackPattern` is irrelevant here: only the sum that
    /// `blackLevel(row:column:colorPlane:)` returns is ever read, so two
    /// metadata models with the same effective black produce identical output.
    ///
    /// - Throws: `RAWProcessingError`.
    public func process(mosaic: RAWMosaic, levels: RAWMetadata.Levels) throws -> LinearRAWMosaic {
        guard mosaic.isGeometryConsistent else {
            throw RAWProcessingError.invalidGeometry(
                reason: """
                    Mosaic geometry \(mosaic.width)x\(mosaic.height), stride \
                    \(mosaic.bytesPerRow) bytes, buffer \(mosaic.samples.count) bytes.
                    """
            )
        }
        // `isGeometryConsistent` already rejects an overflowing byte count,
        // but the element count is a different product and is checked on its
        // own rather than inferred from that.
        let (valueCount, countOverflow) = mosaic.width.multipliedReportingOverflow(by: mosaic.height)
        guard !countOverflow else {
            throw RAWProcessingError.invalidGeometry(
                reason: "Element count \(mosaic.width) x \(mosaic.height) overflows."
            )
        }

        let white: UInt32
        switch whiteLevelPolicy {
        case .metadataMaximum:
            white = levels.maximum
        }

        let width = mosaic.width
        let height = mosaic.height
        let bytesPerRow = mosaic.bytesPerRow
        let layout = mosaic.sensorColorLayout

        // One owned Float32 allocation, filled once, straight from the source
        // bytes: no intermediate [UInt16] copy of the input, no full-size
        // Double buffer, no second Float buffer.
        let values = try [Float](unsafeUninitializedCapacity: valueCount) { buffer, initializedCount in
            initializedCount = 0
            try mosaic.samples.withUnsafeBytes { rawBytes in
                // Bounds are established once, here, from facts
                // `isGeometryConsistent` guarantees: the buffer holds at
                // least `bytesPerRow * height` bytes and `bytesPerRow` is at
                // least `width * 2`. Every offset below is therefore in
                // range by construction, and the inner loop needs no
                // per-sample bounds check.
                guard let expectedBytes = mosaic.expectedByteCount,
                      rawBytes.count >= expectedBytes,
                      bytesPerRow >= width * 2
                else {
                    throw RAWProcessingError.invalidGeometry(
                        reason: "Sample buffer is smaller than the declared geometry requires."
                    )
                }

                var index = 0
                for row in 0..<height {
                    let rowByteOffset = row * bytesPerRow
                    for column in 0..<width {
                        guard let plane = layout.colorPlaneIndex(row: row, column: column) else {
                            initializedCount = index
                            throw RAWProcessingError.missingColorPlane(row: row, column: column)
                        }
                        let black = levels.blackLevel(row: row, column: column, colorPlane: plane)
                        guard white > black else {
                            initializedCount = index
                            throw RAWProcessingError.invalidNormalizationRange(
                                whiteLevel: white,
                                blackLevel: black,
                                row: row,
                                column: column,
                                colorPlane: plane
                            )
                        }

                        // Little-endian, decoded explicitly rather than by
                        // reinterpreting the pointer — the same decode
                        // `RAWMosaic.sample(row:column:)` performs, and it
                        // needs no alignment assumption about `bytesPerRow`.
                        let byteOffset = rowByteOffset + column * 2
                        let sample = UInt16(rawBytes[byteOffset])
                            | (UInt16(rawBytes[byteOffset + 1]) << 8)

                        // `white > black` makes the denominator at least 1,
                        // and every term is a converted UInt16/UInt32, so the
                        // result is always finite: no NaN, no infinity, for
                        // any metadata this stage accepts.
                        buffer[index] = (Float(sample) - Float(black)) / Float(white - black)
                        index += 1
                    }
                }
                initializedCount = index
            }
        }

        return LinearRAWMosaic(
            width: width,
            height: height,
            values: values,
            sensorColorLayout: layout,
            processing: RAWLinearProcessing(
                whiteLevelPolicy: whiteLevelPolicy,
                whiteLevel: white
            )
        )
    }
}
