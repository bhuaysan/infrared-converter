import Foundation
import CLibRaw

/// `RAWDecoder` backed by the vendored LibRaw 0.21.4 via the plain-C shim in
/// `Sources/CLibRaw`.
///
/// This is the only Swift type that imports `CLibRaw`.
///
/// ## Decoder configuration
///
/// The options passed to LibRaw are chosen so that no irreversible colour
/// decision happens here. Concretely, LibRaw is asked to:
///
/// - subtract black levels and linearly scale to full 16-bit range,
/// - use **unity** white-balance multipliers (`user_mul = 1,1,1,1`), so neither
///   the as-shot nor the daylight multipliers are baked in,
/// - skip any colour-matrix conversion (`output_color = 0`, camera-native RGB),
/// - use a linear transfer function (`gamm = 1, 1`),
/// - skip auto-brightness, highlight reconstruction, noise reduction and
///   LibRaw's automatic saturation-level adjustment,
/// - emit 16 bits per channel.
///
/// Demosaicing is the one non-trivial operation LibRaw still performs, because
/// this milestone needs an RGB buffer. It is reported in
/// `RAWDecoderProcessing.demosaic`.
public struct LibRawDecoder: RAWDecoder {
    public init() {}

    public static var libRawVersion: String {
        String(cString: ir_libraw_version())
    }

    public func readMetadata(at url: URL) throws -> RAWMetadata {
        try withOpenContext(url: url, options: .init()) { context in
            try Self.metadata(from: context, url: url)
        }
    }

    public func decode(at url: URL, options: RAWDecodeOptions) throws -> DecodedRAW {
        try withOpenContext(url: url, options: options) { context in
            var shimOptions = ir_libraw_options()
            ir_libraw_default_options(&shimOptions)
            Self.apply(options, to: &shimOptions)

            let metadata = try Self.metadata(from: context, url: url)

            var status = ir_libraw_unpack(context)
            guard status.error == IR_LIBRAW_OK else {
                throw Self.error(from: status, url: url, stage: .unpack)
            }

            status = ir_libraw_process(context)
            guard status.error == IR_LIBRAW_OK else {
                throw Self.error(from: status, url: url, stage: .process)
            }

            var shimImage = ir_libraw_image()
            status = ir_libraw_make_image(context, &shimImage)
            guard status.error == IR_LIBRAW_OK, let bytes = shimImage.bytes else {
                throw Self.error(from: status, url: url, stage: .makeImage)
            }
            defer { ir_libraw_free_image(context) }

            let image = try Self.rawImage(from: shimImage, bytes: bytes, url: url)

            // process_warnings is only meaningful once unpack/process have
            // run, hence reading it here rather than from the metadata-only
            // path (readMetadata never reaches this point).
            let rawWarningBits = ir_libraw_process_warnings(context)

            let processing = RAWDecoderProcessing(
                decoderIdentifier: "LibRaw \(Self.libRawVersion)",
                blackLevelSubtracted: true,
                normalizedToFullRange: true,
                appliedWhiteBalanceMultipliers: [
                    shimOptions.user_mul.0, shimOptions.user_mul.1,
                    shimOptions.user_mul.2, shimOptions.user_mul.3
                ],
                demosaic: options.halfSize ? nil : options.demosaic,
                cameraColorMatrixApplied: false,
                autoBrightnessApplied: false,
                highlightReconstructionApplied: false,
                noiseReductionApplied: false,
                orientationHandlingRequested: options.applyCameraOrientation,
                appliedOrientationFlip: options.applyCameraOrientation ? metadata.geometry.flip : 0,
                warnings: RAWDecoderProcessing.decode(rawWarningBits: rawWarningBits),
                rawWarningBits: rawWarningBits
            )

            Log.raw.debug(
                """
                Decoded \(url.lastPathComponent, privacy: .public): \
                \(image.width, privacy: .public)×\(image.height, privacy: .public), \
                \(image.channelCount, privacy: .public)ch × \
                \(image.bitsPerChannel, privacy: .public)bit
                """
            )

            return DecodedRAW(
                url: url,
                metadata: metadata,
                image: image,
                processing: processing
            )
        }
    }

    // MARK: - Context lifetime

    private func withOpenContext<T>(
        url: URL,
        options: RAWDecodeOptions,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard url.isFileURL else { throw RAWDecodingError.fileNotReadable(url) }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RAWDecodingError.fileNotFound(url)
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw RAWDecodingError.fileNotReadable(url)
        }
        guard let context = ir_libraw_create() else {
            throw RAWDecodingError.decoderUnavailable
        }
        defer { ir_libraw_destroy(context) }

        var shimOptions = ir_libraw_options()
        ir_libraw_default_options(&shimOptions)
        Self.apply(options, to: &shimOptions)
        ir_libraw_apply_options(context, &shimOptions)

        let status = url.withUnsafeFileSystemRepresentation { path -> ir_libraw_status in
            guard let path else {
                var invalid = ir_libraw_status()
                invalid.error = IR_LIBRAW_ERR_IO
                return invalid
            }
            return ir_libraw_open_file(context, path)
        }
        guard status.error == IR_LIBRAW_OK else {
            throw Self.error(from: status, url: url, stage: .open)
        }

        return try body(context)
    }

    private static func apply(_ options: RAWDecodeOptions, to shim: inout ir_libraw_options) {
        shim.demosaic_quality = Int32(options.demosaic.rawValue)
        shim.half_size = options.halfSize ? 1 : 0
        shim.user_flip = options.applyCameraOrientation ? -1 : 0
    }

    // MARK: - Errors

    private enum Stage {
        case open, unpack, process, makeImage
    }

    private static func error(
        from status: ir_libraw_status,
        url: URL,
        stage: Stage
    ) -> RAWDecodingError {
        let diagnostic = RAWDecodingError.DecoderDiagnostic(
            code: status.libraw_code,
            message: withUnsafeBytes(of: status.message) { buffer in
                String(cString: buffer.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
        )

        Log.raw.error(
            """
            LibRaw failure for \(url.lastPathComponent, privacy: .public): \
            \(diagnostic.description, privacy: .public)
            """
        )

        if status.error == IR_LIBRAW_ERR_OUT_OF_MEMORY {
            return .outOfMemory(url)
        }
        if status.error == IR_LIBRAW_ERR_UNSUPPORTED_FORMAT {
            return .unsupportedFormat(url, diagnostic)
        }

        switch stage {
        case .open:
            // A positive LibRaw code is an errno from the file access itself.
            if status.error == IR_LIBRAW_ERR_IO, status.libraw_code > 0 {
                return .fileNotReadable(url)
            }
            return .openFailed(url, diagnostic)
        case .unpack:
            return .unpackFailed(url, diagnostic)
        case .process:
            return .processingFailed(url, diagnostic)
        case .makeImage:
            return .imageExtractionFailed(url, diagnostic)
        }
    }

    // MARK: - Image

    /// Multiplies a chain of values, reporting `nil` on the first overflow
    /// rather than wrapping. Used to re-validate every geometry value that
    /// crosses the decoder boundary before it is used to allocate or copy.
    private static func checkedMultiply(_ values: Int...) -> Int? {
        var result = 1
        for value in values {
            let (product, overflow) = result.multipliedReportingOverflow(by: value)
            if overflow { return nil }
            result = product
        }
        return result
    }

    private static func rawImage(
        from shim: ir_libraw_image,
        bytes: UnsafePointer<UInt8>,
        url: URL
    ) throws -> RAWImage {
        guard shim.width > 0, shim.height > 0, shim.colors > 0, shim.bits > 0 else {
            throw RAWDecodingError.invalidDecodedImage(url, reason: "zero-sized buffer")
        }
        guard shim.bits % 8 == 0 else {
            throw RAWDecodingError.invalidDecodedImage(
                url,
                reason: "unsupported bit depth \(shim.bits)"
            )
        }

        // The C shim already validated its own geometry (ir_libraw_make_image
        // rejects overflowing or inconsistent buffers before returning), but
        // this boundary re-validates independently with checked arithmetic:
        // it is exactly the seam a malformed or hostile file would exploit,
        // and nothing here should trust a size without checking it first.
        guard let width = Int(exactly: shim.width),
              let height = Int(exactly: shim.height),
              let colors = Int(exactly: shim.colors),
              let bits = Int(exactly: shim.bits),
              let bytesPerRow = Int(exactly: shim.bytes_per_row),
              let byteCount = Int(exactly: shim.byte_count)
        else {
            throw RAWDecodingError.invalidDecodedImage(url, reason: "geometry does not fit a native Int")
        }

        let bytesPerSample = bits / 8
        guard let minimumRowBytes = checkedMultiply(width, colors, bytesPerSample) else {
            throw RAWDecodingError.invalidDecodedImage(
                url,
                reason: "row size implied by \(width)×\(colors)ch×\(bits)bit overflows"
            )
        }
        guard bytesPerRow >= minimumRowBytes else {
            throw RAWDecodingError.invalidDecodedImage(
                url,
                reason: "stride of \(bytesPerRow) bytes is smaller than the \(minimumRowBytes) bytes "
                    + "implied by width × channels × depth"
            )
        }
        guard let expected = checkedMultiply(bytesPerRow, height) else {
            throw RAWDecodingError.invalidDecodedImage(
                url,
                reason: "buffer size implied by a \(bytesPerRow)-byte stride × \(height) rows overflows"
            )
        }
        guard byteCount >= expected else {
            throw RAWDecodingError.invalidDecodedImage(
                url,
                reason: "buffer of \(byteCount) bytes is smaller than the \(expected) bytes "
                    + "implied by \(width)×\(height) at a \(bytesPerRow)-byte stride"
            )
        }

        let image = RAWImage(
            width: width,
            height: height,
            channelCount: colors,
            bitsPerChannel: bits,
            bytesPerRow: bytesPerRow,
            samples: Data(bytes: bytes, count: expected),
            // Set by our decoder configuration; see the type documentation.
            encoding: .linear,
            colorSpace: .cameraNative
        )

        guard image.isGeometryConsistent else {
            throw RAWDecodingError.invalidDecodedImage(url, reason: "inconsistent geometry")
        }
        return image
    }

    // MARK: - Metadata

    private static func metadata(from context: OpaquePointer, url: URL) throws -> RAWMetadata {
        var shim = ir_libraw_metadata()
        let status = ir_libraw_copy_metadata(context, &shim)
        guard status.error == IR_LIBRAW_OK else {
            throw Self.error(from: status, url: url, stage: .open)
        }
        return convert(shim)
    }

    private static func convert(_ shim: ir_libraw_metadata) -> RAWMetadata {
        let identity = RAWMetadata.Identity(
            make: string(shim.make),
            model: string(shim.model),
            normalizedMake: string(shim.normalized_make),
            normalizedModel: string(shim.normalized_model),
            software: string(shim.software)
        )

        let geometry = RAWMetadata.Geometry(
            rawWidth: Int(shim.raw_width),
            rawHeight: Int(shim.raw_height),
            visibleWidth: Int(shim.visible_width),
            visibleHeight: Int(shim.visible_height),
            topMargin: Int(shim.top_margin),
            leftMargin: Int(shim.left_margin),
            outputWidth: Int(shim.output_width),
            outputHeight: Int(shim.output_height),
            flip: Int(shim.flip),
            pixelAspect: shim.pixel_aspect
        )

        let sensor = RAWMetadata.SensorColorLayout(
            pattern: pattern(for: shim),
            filters: shim.filters,
            colorDescription: string(shim.cdesc) ?? "",
            colorCount: Int(shim.colors),
            bitsPerRawSample: shim.raw_bps > 0 ? Int(shim.raw_bps) : nil,
            xTransPattern: shim.has_xtrans != 0 ? xTransPattern(shim.xtrans) : nil
        )

        let levels = RAWMetadata.Levels(
            black: shim.black,
            perPlaneBlack: array4(shim.cblack),
            blackPattern: blackPattern(from: shim),
            maximum: shim.maximum,
            dataMaximum: shim.data_maximum > 0 ? shim.data_maximum : nil,
            linearMaximum: {
                let values: [Int32] = array4(shim.linear_max)
                return values.contains(where: { $0 != 0 }) ? values : nil
            }()
        )

        let color = RAWMetadata.ColorMetadata(
            cameraMultipliers: shim.has_cam_mul != 0 ? array4(shim.cam_mul) : nil,
            daylightMultipliers: shim.has_pre_mul != 0 ? array4(shim.pre_mul) : nil,
            rgbFromCamera: shim.has_rgb_cam != 0 ? matrix3x4(shim.rgb_cam) : nil,
            cameraFromXYZ: shim.has_cam_xyz != 0 ? matrix4x3(shim.cam_xyz) : nil,
            asShotWhiteBalanceApplied: shim.as_shot_wb_applied != 0
        )

        let exposure = RAWMetadata.Exposure(
            iso: shim.has_iso != 0 ? shim.iso_speed : nil,
            shutterSeconds: shim.has_shutter != 0 ? shim.shutter : nil,
            aperture: shim.has_aperture != 0 ? shim.aperture : nil,
            focalLength: shim.has_focal != 0 ? shim.focal_len : nil,
            captureDate: shim.has_timestamp != 0
                ? Date(timeIntervalSince1970: TimeInterval(shim.timestamp))
                : nil
        )

        return RAWMetadata(
            identity: identity,
            geometry: geometry,
            sensor: sensor,
            levels: levels,
            color: color,
            exposure: exposure,
            lens: string(shim.lens),
            artist: string(shim.artist)
        )
    }

    /// Builds the black pattern from the shim's fixed-size `black_pattern`
    /// array, honouring `black_pattern_count` — the shim already validated
    /// row/column consistency and capped the count defensively, so this only
    /// needs to trust `black_pattern_count` as the slice length.
    private static func blackPattern(from shim: ir_libraw_metadata) -> RAWMetadata.Levels.BlackPattern? {
        let rows = Int(shim.cblack_pattern_rows)
        let columns = Int(shim.cblack_pattern_cols)
        let count = Int(shim.black_pattern_count)
        guard rows > 0, columns > 0, count == rows * columns else { return nil }

        let values: [UInt32] = withUnsafeBytes(of: shim.black_pattern) { buffer in
            Array(buffer.bindMemory(to: UInt32.self).prefix(count))
        }
        guard values.count == count else { return nil }
        return RAWMetadata.Levels.BlackPattern(rows: rows, columns: columns, values: values)
    }

    private static func pattern(for shim: ir_libraw_metadata) -> RAWMetadata.SensorColorLayout.Pattern {
        if shim.is_foveon != 0 { return .foveon }
        // LibRaw encodes X-Trans as the sentinel value 9 and "no mosaic" as 0.
        switch shim.filters {
        case 9: return .xTrans
        case 0: return .none
        case 1: return .unknown  // 1 marks a non-standard 16-pixel layout.
        default: return .bayer
        }
    }

    // MARK: - C tuple bridging

    private static func string<T>(_ tuple: T) -> String? {
        let value = withUnsafeBytes(of: tuple) { buffer -> String in
            guard let base = buffer.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return value.isEmpty ? nil : value
    }

    private static func array4<Element, T>(_ tuple: T) -> [Element] {
        withUnsafeBytes(of: tuple) { buffer in
            Array(buffer.bindMemory(to: Element.self).prefix(4))
        }
    }

    private static func matrix3x4<T>(_ tuple: T) -> [[Float]] {
        let flat = withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Float.self)) }
        return (0..<3).map { row in Array(flat[(row * 4)..<(row * 4 + 4)]) }
    }

    private static func matrix4x3<T>(_ tuple: T) -> [[Float]] {
        let flat = withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: Float.self)) }
        return (0..<4).map { row in Array(flat[(row * 3)..<(row * 3 + 3)]) }
    }

    private static func xTransPattern<T>(_ tuple: T) -> [[Int]] {
        let flat = withUnsafeBytes(of: tuple) { Array($0.bindMemory(to: CChar.self)) }
        return (0..<6).map { row in
            (0..<6).map { column in Int(flat[row * 6 + column]) }
        }
    }
}
