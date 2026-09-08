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
        /// Bits per raw sample as reported by the decoder, when known.
        public var bitsPerRawSample: Int?
        /// 6×6 colour-plane indices, present only for `.xTrans`.
        public var xTransPattern: [[Int]]?

        public init(
            pattern: Pattern,
            filters: UInt32,
            colorDescription: String,
            colorCount: Int,
            bitsPerRawSample: Int? = nil,
            xTransPattern: [[Int]]? = nil
        ) {
            self.pattern = pattern
            self.filters = filters
            self.colorDescription = colorDescription
            self.colorCount = colorCount
            self.bitsPerRawSample = bitsPerRawSample
            self.xTransPattern = xTransPattern
        }

        /// The colour-plane index sampled at a raw sensor coordinate, or `nil`
        /// when the layout has no per-pixel mosaic.
        ///
        /// Coordinates are relative to the full raw readout, matching the
        /// convention the decoder uses for `filters`.
        public func colorPlaneIndex(row: Int, column: Int) -> Int? {
            switch pattern {
            case .bayer:
                // Same packing dcraw/LibRaw use: two bits per position in a
                // 2-row × 2-column cell.
                let shift = ((row << 1 & 14) | (column & 1)) << 1
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

        /// The letter of the colour plane sampled at a raw sensor coordinate.
        public func colorPlaneLetter(row: Int, column: Int) -> Character? {
            guard let index = colorPlaneIndex(row: row, column: column) else { return nil }
            let letters = Array(colorDescription)
            guard index >= 0, index < letters.count else { return nil }
            return letters[index]
        }
    }

    /// Black and saturation levels, in raw sample units.
    public struct Levels: Equatable, Sendable {
        /// The decoder's global black level.
        public var black: UInt32
        /// Additional per-colour-plane black offsets, added to `black`.
        public var perPlaneBlack: [UInt32]
        /// Dimensions of an optional per-pixel black pattern, when present.
        public var blackPatternRows: Int
        public var blackPatternColumns: Int
        /// The saturation level the decoder will treat as white.
        public var maximum: UInt32
        /// The largest sample actually observed, when the decoder computed it.
        public var dataMaximum: UInt32?
        /// Per-plane linearity limits, when the file declares them.
        public var linearMaximum: [Int32]?

        public init(
            black: UInt32,
            perPlaneBlack: [UInt32],
            blackPatternRows: Int,
            blackPatternColumns: Int,
            maximum: UInt32,
            dataMaximum: UInt32? = nil,
            linearMaximum: [Int32]? = nil
        ) {
            self.black = black
            self.perPlaneBlack = perPlaneBlack
            self.blackPatternRows = blackPatternRows
            self.blackPatternColumns = blackPatternColumns
            self.maximum = maximum
            self.dataMaximum = dataMaximum
            self.linearMaximum = linearMaximum
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
