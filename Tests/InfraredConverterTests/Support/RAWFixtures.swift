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

    /// Thrown when a test that needs the fixture is run without one. Suites
    /// are gated on `isAvailable`, so this is a programming error rather than
    /// an expected outcome.
    enum Unavailable: Error {
        case noFixture
    }

    /// Copies the fixture into a temporary directory of its own, runs `body`
    /// against the copy, and removes the directory afterwards — whatever
    /// happens.
    ///
    /// ## Why a copy
    ///
    /// The RAW file is provided per-machine and **the directory it sits in is
    /// a developer's working directory**. A sidecar may be beside it, left by
    /// an ordinary session of the application; there may be other files; its
    /// modification date is whatever the file system says.
    ///
    /// A test that asserts something about that directory — "no sidecar was
    /// written", "these are the only files here" — is then asserting something
    /// about the developer's machine rather than about the code. It passes or
    /// fails depending on whether somebody once rotated the photograph, which
    /// is not a property of this project.
    ///
    /// Against a fresh copy the precondition is *established* rather than
    /// hoped for, so the assertion means what it says. And nothing a test does
    /// can touch the original: the fixture is read once, by `copyItem`.
    static func withIsolatedCopy<T>(_ body: (URL) throws -> T) throws -> T {
        guard let original = olympusORF else { throw Unavailable.noFixture }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("infrared-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let copy = directory.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: copy)
        return try body(copy)
    }

    static let unavailableReason =
        "No local RAW fixture. Place an Olympus .ORF at RAW/OLYMPUS.ORF or set INFRARED_TEST_ORF."
}
