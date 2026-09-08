import OSLog

/// Shared OSLog categories. Never log image buffers, and avoid logging full
/// file paths — file names are enough for diagnostics.
enum Log {
    private static let subsystem = "com.infraredconverter"

    static let raw = Logger(subsystem: subsystem, category: "RAW")
    static let ui = Logger(subsystem: subsystem, category: "UI")
}
