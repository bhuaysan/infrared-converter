import Foundation

/// Everything the decoder boundary reports *about* a RAW file, independent of
/// any decoded pixels.
///
/// Values that the decoder cannot supply for a given file are represented as
/// `nil` rather than being substituted with a plausible default. Nothing here
/// is interpreted or corrected — it is what the decoder read from the file.
public struct RAWMetadata: Equatable, Sendable {
    public var identity: Identity
    public var geometry: Geometry
    public var sensor: SensorColorLayout
    public var levels: Levels
    public var color: ColorMetadata
    public var exposure: Exposure
    public var lens: String?
    public var artist: String?

    public init(
        identity: Identity,
        geometry: Geometry,
        sensor: SensorColorLayout,
        levels: Levels,
        color: ColorMetadata,
        exposure: Exposure,
        lens: String? = nil,
        artist: String? = nil
    ) {
        self.identity = identity
        self.geometry = geometry
        self.sensor = sensor
        self.levels = levels
        self.color = color
        self.exposure = exposure
        self.lens = lens
        self.artist = artist
    }
}

extension RAWMetadata {
    /// Camera identification as recorded in the file.
    public struct Identity: Equatable, Sendable {
        public var make: String?
        public var model: String?
        /// The decoder's canonicalised make, useful as a profile lookup key.
        public var normalizedMake: String?
        public var normalizedModel: String?
        public var software: String?

        public init(
            make: String? = nil,
            model: String? = nil,
            normalizedMake: String? = nil,
            normalizedModel: String? = nil,
            software: String? = nil
        ) {
            self.make = make
            self.model = model
            self.normalizedMake = normalizedMake
            self.normalizedModel = normalizedModel
            self.software = software
        }

        /// "Olympus E-PL3", or whichever half is available.
        public var displayName: String? {
            let parts = [make, model].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// Sensor and output geometry, in pixels.
    public struct Geometry: Equatable, Sendable {
        /// Full sensor readout, including masked/optical-black borders.
        public var rawWidth: Int
        public var rawHeight: Int
        /// The active image area inside the raw readout.
        public var visibleWidth: Int
        public var visibleHeight: Int
        public var topMargin: Int
        public var leftMargin: Int
        /// Dimensions of a full-size processed image from this file.
        /// A reduced-resolution decode produces smaller dimensions than these.
        public var outputWidth: Int
        public var outputHeight: Int
        /// EXIF-style orientation code as understood by the decoder.
        public var flip: Int
        public var pixelAspect: Double

        public init(
            rawWidth: Int,
            rawHeight: Int,
            visibleWidth: Int,
            visibleHeight: Int,
            topMargin: Int,
            leftMargin: Int,
            outputWidth: Int,
            outputHeight: Int,
            flip: Int,
            pixelAspect: Double
        ) {
            self.rawWidth = rawWidth
            self.rawHeight = rawHeight
            self.visibleWidth = visibleWidth
            self.visibleHeight = visibleHeight
            self.topMargin = topMargin
            self.leftMargin = leftMargin
            self.outputWidth = outputWidth
            self.outputHeight = outputHeight
            self.flip = flip
            self.pixelAspect = pixelAspect
        }
    }

    /// How colour is laid out across the sensor.
    ///
    /// Deliberately not Bayer-specific: `pattern` distinguishes the mosaic
    /// families the decoder can describe, and callers must branch on it rather
    /// than assuming RGGB.
    public struct SensorColorLayout: Equatable, Sendable {
        public enum Pattern: Equatable, Sendable {
            /// A repeating 2×2 colour filter array, encoded in `filters`.
            case bayer
            /// A 6×6 X-Trans layout; see `xTransPattern`.
            case xTrans
            /// Stacked-photodiode sensors have no mosaic.
            case foveon
            /// The file is already full-colour per pixel (e.g. linear DNG).
            case none
            /// The decoder reported a layout we do not model yet.
            case unknown
        }

        public var pattern: Pattern
        /// The decoder's packed 2×2 CFA code. Only meaningful for `.bayer`.
        public var filters: UInt32
        /// One letter per colour plane, e.g. "RGBG".
        public var colorDescription: String
        /// Number of distinct colour planes (3 or 4 for most cameras).
        public var colorCount: Int
        /// The bit depth of the samples **as stored in the source file**,
        /// as the decoder's format parser reports it (LibRaw's
        /// `imgdata.color.raw_bps`), or `nil` when it reported none.
        ///
        /// This is source/file-format information. It is deliberately **not**
        /// a white level, and `2^sourceRawBitDepth - 1` must never be used as
        /// one: `unpack()` may apply a format-specific linearisation curve
        /// that changes the samples' numeric domain, and LibRaw updates
        /// `Levels.maximum` accordingly. Normalisation belongs to
        /// `Levels.maximum` / `Levels.linearMaximum` and an explicitly chosen
        /// white-level model, not to this value.
        ///
        /// It is optional rather than defaulted: substituting `16` for an
        /// unreported depth would invent a fact the decoder did not state.
        public var sourceRawBitDepth: Int?
        /// 6×6 colour-plane indices, present only for `.xTrans`.
        public var xTransPattern: [[Int]]?

        public init(
            pattern: Pattern,
            filters: UInt32,
            colorDescription: String,
            colorCount: Int,
            sourceRawBitDepth: Int? = nil,
            xTransPattern: [[Int]]? = nil
        ) {
            self.pattern = pattern
            self.filters = filters
            self.colorDescription = colorDescription
            self.colorCount = colorCount
            self.sourceRawBitDepth = sourceRawBitDepth
            self.xTransPattern = xTransPattern
        }

        /// The colour-plane index sampled at an **active-image** coordinate
        /// (row/column `0` is the top-left of `RAWMetadata.Geometry`'s
        /// visible area, i.e. `topMargin`/`leftMargin` into the raw
        /// readout), or `nil` when the layout has no per-pixel mosaic.
        ///
        /// This matches LibRaw 0.22.2's own convention: its `COLOR`/`fcol`
        /// accessor adds `top_margin`/`left_margin` to the row/column it is
        /// given before indexing `filters`, and the X-Trans table it exposes
        /// (`xtrans`) is built from the sensor-absolute table
        /// (`xtrans_abs`) by folding those same margins in once, at parse
        /// time (`identify.cpp`). In both cases the margin is already
        /// accounted for by the time this type sees `filters`/
        /// `xTransPattern` — so this method deliberately does **not** add
        /// the margins again. Callers holding raw-readout coordinates must
        /// subtract `Geometry.topMargin`/`leftMargin` first, or use
        /// `colorPlaneIndex(rawReadoutRow:rawReadoutColumn:geometry:)`.
        ///
        /// `filters == 1` denotes LibRaw's non-standard 16×16 layout, which
        /// would be the one case where LibRaw itself still needs the
        /// margins at lookup time — this type does not carry that 16×16
        /// table, so `.bayer` layouts with `filters == 1` are unsupported
        /// here and should be represented as `.unknown` (returning `nil`),
        /// not modelled as an ordinary 2×2 pattern.
        ///
        /// Both the Bayer and X-Trans paths wrap out-of-range coordinates
        /// (including negative ones) onto the repeating pattern rather than
        /// producing an undefined result.
        public func colorPlaneIndex(row: Int, column: Int) -> Int? {
            switch pattern {
            case .bayer:
                guard filters != 1 else { return nil }
                // Same packing dcraw/LibRaw use: two bits per position in an
                // 8-row × 2-column cell. Wrap explicitly first so the result
                // is correct regardless of how row/column relate to zero.
                let r = ((row % 8) + 8) % 8
                let c = ((column % 2) + 2) % 2
                let shift = ((r << 1) | c) << 1
                return Int((filters >> UInt32(shift)) & 3)
            case .xTrans:
                guard let xTransPattern, xTransPattern.count == 6 else { return nil }
                let cell = xTransPattern[((row % 6) + 6) % 6]
                guard cell.count == 6 else { return nil }
                return cell[((column % 6) + 6) % 6]
            case .foveon, .none, .unknown:
                return nil
            }
        }

        /// Convenience for callers that hold raw-readout coordinates (i.e.
        /// including the optical-black border): converts to active-image
        /// coordinates by subtracting `geometry`'s margins, then looks up
        /// the colour plane as `colorPlaneIndex(row:column:)`.
        public func colorPlaneIndex(
            rawReadoutRow: Int,
            rawReadoutColumn: Int,
            geometry: RAWMetadata.Geometry
        ) -> Int? {
            colorPlaneIndex(
                row: rawReadoutRow - geometry.topMargin,
                column: rawReadoutColumn - geometry.leftMargin
            )
        }

        /// The letter of the colour plane sampled at an active-image
        /// coordinate. See `colorPlaneIndex(row:column:)` for the
        /// coordinate convention.
        public func colorPlaneLetter(row: Int, column: Int) -> Character? {
            guard let index = colorPlaneIndex(row: row, column: column) else { return nil }
            let letters = Array(colorDescription)
            guard index >= 0, index < letters.count else { return nil }
            return letters[index]
        }
    }

    /// Black and saturation levels, in raw sample units.
    ///
    /// The effective black level at a given sample is the *sum* of every
    /// contributing term: the global `black`, the `perPlaneBlack` offset for
    /// that sample's colour plane (when in range), and the `blackPattern`
    /// contribution at that sample's position (when a pattern is present).
    /// Use `blackLevel(row:column:colorPlane:)` rather than combining the
    /// fields by hand.
    ///
    /// This mirrors LibRaw's own model (`imgdata.color.black`, `cblack[0...3]`,
    /// and the repeating pattern packed into `cblack[4...]`), read before
    /// `LibRaw::adjust_bl()` / `subtract_black_internal()` run — those are
    /// part of `dcraw_process`, and they fold `black` into `cblack[0...3]`
    /// and then zero both.
    ///
    /// **How `black` and `perPlaneBlack` are split depends on which decode
    /// path produced this metadata, and the split is not stable across
    /// `unpack()`.** `unpack()` canonicalises the common component of
    /// `cblack[0...3]` into `black`: it takes `i = min(cblack[0...3])`,
    /// subtracts `i` from each entry and adds it to `black`. For the Olympus
    /// E-PL3 that turns `black 0, cblack [64, 64, 64, 64]` into
    /// `black 64, cblack [0, 0, 0, 0]`.
    ///
    /// - `LibRawDecoder.decodeMosaic(at:)` reports the **post-unpack** split,
    ///   because that is the state describing the samples in its `RAWMosaic`.
    /// - `LibRawDecoder.decode(at:options:)` and `readMetadata(at:)` report
    ///   the **pre-unpack** split, as read from the file.
    ///
    /// The redistribution is value-preserving, so
    /// `blackLevel(row:column:colorPlane:)` returns the same effective level
    /// either way. That is exactly why the terms are kept separate and summed
    /// through one accessor: **never compare `black` or `perPlaneBlack`
    /// across paths, and never pre-sum them by hand.**
    public struct Levels: Equatable, Sendable {
        /// A repeating per-pixel black-offset pattern, in active-image
        /// coordinates (the convention LibRaw itself uses when applying it,
        /// not raw-frame coordinates).
        public struct BlackPattern: Equatable, Sendable {
            /// Number of pattern rows; the pattern repeats every `rows` rows.
            public var rows: Int
            /// Number of pattern columns; the pattern repeats every `columns`
            /// columns.
            public var columns: Int
            /// `rows * columns` values, row-major: `values[r * columns + c]`.
            public var values: [UInt32]

            public init(rows: Int, columns: Int, values: [UInt32]) {
                self.rows = rows
                self.columns = columns
                self.values = values
            }

            /// The pattern value at a pattern-relative position, wrapping
            /// (modulo) on both axes. Coordinates may be negative or exceed
            /// the pattern extent; wrapping always yields an in-range index.
            ///
            /// Returns `nil` when the pattern is degenerate (zero rows,
            /// columns, or a `values` count that does not match `rows *
            /// columns`), so callers never index out of bounds.
            public func value(row: Int, column: Int) -> UInt32? {
                guard rows > 0, columns > 0 else { return nil }
                // `rows * columns` can overflow for a pathological pattern —
                // this type has a public memberwise initialiser, so a caller
                // can construct one with unchecked extent. Fail closed rather
                // than trap.
                let (extent, overflow) = rows.multipliedReportingOverflow(by: columns)
                guard !overflow, values.count == extent else { return nil }
                let r = ((row % rows) + rows) % rows
                let c = ((column % columns) + columns) % columns
                return values[r * columns + c]
            }
        }

        /// The decoder's global black level.
        public var black: UInt32
        /// Additional per-colour-plane black offsets, added to `black`.
        public var perPlaneBlack: [UInt32]
        /// An optional repeating per-pixel black pattern, added on top of
        /// `black` and `perPlaneBlack`.
        public var blackPattern: BlackPattern?
        /// The saturation level the decoder will treat as white.
        public var maximum: UInt32
        /// The largest sample actually observed, when the decoder computed it.
        public var dataMaximum: UInt32?
        /// Per-plane linearity limits, when the file declares them.
        public var linearMaximum: [Int32]?

        public init(
            black: UInt32,
            perPlaneBlack: [UInt32],
            blackPattern: BlackPattern? = nil,
            maximum: UInt32,
            dataMaximum: UInt32? = nil,
            linearMaximum: [Int32]? = nil
        ) {
            self.black = black
            self.perPlaneBlack = perPlaneBlack
            self.blackPattern = blackPattern
            self.maximum = maximum
            self.dataMaximum = dataMaximum
            self.linearMaximum = linearMaximum
        }

        /// The effective black level at a sample, combining the global,
        /// per-plane and pattern contributions.
        ///
        /// `row`/`column` are active-image coordinates (matching
        /// `BlackPattern.value(row:column:)`); `colorPlane` is a colour-plane
        /// index as produced by `SensorColorLayout.colorPlaneIndex(row:
        /// column:)`. Out-of-range `colorPlane` values contribute nothing
        /// (rather than trapping), since not every caller has plane
        /// information at hand. Negative `row`/`column` wrap safely.
        public func blackLevel(row: Int, column: Int, colorPlane: Int) -> UInt32 {
            // Saturating, never wrapping: these terms are decoded from a file
            // and a wrapped sum would be a silently wrong black level, which
            // is far worse than a clamped one. Real sensor levels are orders
            // of magnitude below UInt32.max, so saturation is unreachable for
            // well-formed input.
            func add(_ lhs: UInt32, _ rhs: UInt32) -> UInt32 {
                let (sum, overflow) = lhs.addingReportingOverflow(rhs)
                return overflow ? .max : sum
            }

            var total = black
            if colorPlane >= 0, colorPlane < perPlaneBlack.count {
                total = add(total, perPlaneBlack[colorPlane])
            }
            if let patternValue = blackPattern?.value(row: row, column: column) {
                total = add(total, patternValue)
            }
            return total
        }
    }

    /// Colour information the file carries.
    ///
    /// Important: the matrices here are camera vendor / decoder data calibrated
    /// for **visible light**. They are exposed for completeness and for future
    /// visible-light work; they must not be assumed valid for infrared capture.
    /// See `docs/decisions/0001-libraw-integration.md`.
    public struct ColorMetadata: Equatable, Sendable {
        /// As-shot camera white-balance multipliers, per colour plane.
        public var cameraMultipliers: [Float]?
        /// The decoder's daylight pre-multipliers, per colour plane.
        public var daylightMultipliers: [Float]?
        /// Camera-RGB → sRGB matrix, 3×4. Visible-light calibrated.
        public var rgbFromCamera: [[Float]]?
        /// XYZ → camera-RGB matrix, 4×3. Visible-light calibrated.
        public var cameraFromXYZ: [[Float]]?
        /// True when the file's raw data already has white balance baked in.
        public var asShotWhiteBalanceApplied: Bool

        public init(
            cameraMultipliers: [Float]? = nil,
            daylightMultipliers: [Float]? = nil,
            rgbFromCamera: [[Float]]? = nil,
            cameraFromXYZ: [[Float]]? = nil,
            asShotWhiteBalanceApplied: Bool = false
        ) {
            self.cameraMultipliers = cameraMultipliers
            self.daylightMultipliers = daylightMultipliers
            self.rgbFromCamera = rgbFromCamera
            self.cameraFromXYZ = cameraFromXYZ
            self.asShotWhiteBalanceApplied = asShotWhiteBalanceApplied
        }
    }

    /// Capture settings, all optional because not every file records them.
    public struct Exposure: Equatable, Sendable {
        public var iso: Float?
        public var shutterSeconds: Float?
        public var aperture: Float?
        public var focalLength: Float?
        public var captureDate: Date?

        public init(
            iso: Float? = nil,
            shutterSeconds: Float? = nil,
            aperture: Float? = nil,
            focalLength: Float? = nil,
            captureDate: Date? = nil
        ) {
            self.iso = iso
            self.shutterSeconds = shutterSeconds
            self.aperture = aperture
            self.focalLength = focalLength
            self.captureDate = captureDate
        }
    }
}
