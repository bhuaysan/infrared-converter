import Foundation

/// Locates the optional local RAW fixture.
///
/// RAW files are large and usually not redistributable, so none is committed.
/// Tests that need one skip cleanly when it is absent.
///
/// Resolution order:
/// 1. the `INFRARED_TEST_ORF` environment variable (an absolute path),
/// 2. `RAW/OLYMPUS.ORF` in the package root,
/// 3. any other `.orf` file in the package's `RAW/` directory.
enum RAWFixtures {
    /// The package root, derived from this file's location at compile time.
    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // InfraredConverterTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root

    static let rawDirectory: URL = packageRoot.appendingPathComponent("RAW", isDirectory: true)

    /// The Olympus ORF fixture, or `nil` when it has not been provided.
    static var olympusORF: URL? {
        let fileManager = FileManager.default

        if let path = ProcessInfo.processInfo.environment["INFRARED_TEST_ORF"],
           fileManager.isReadableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let preferred = rawDirectory.appendingPathComponent("OLYMPUS.ORF")
        if fileManager.isReadableFile(atPath: preferred.path) {
            return preferred
        }

        let contents = (try? fileManager.contentsOfDirectory(
            at: rawDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "orf" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// Whether the fixture-dependent tests can run at all.
    static var isAvailable: Bool { olympusORF != nil }

    static let unavailableReason =
        "No local RAW fixture. Place an Olympus .ORF at RAW/OLYMPUS.ORF or set INFRARED_TEST_ORF."
}
