// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "InfraredConverter",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Vendored LibRaw, built verbatim from the upstream tarball.
        //
        // This target exists purely so that upstream's warnings can be silenced
        // without silencing ours: `-w` applies here and nowhere else. See
        // Sources/CLibRaw/VENDOR.md.
        .target(
            name: "CLibRawVendor",
            path: "Sources/CLibRawVendor",
            exclude: [
                "COPYRIGHT",
                "LICENSE.CDDL",
                "LICENSE.LGPL",
                // Glue for optional back-ends we do not build (Adobe DNG SDK,
                // RawSpeed). They compile to nothing but reference headers we
                // do not vendor.
                "src/integration",
                // LibRaw ships "placeholder" translation units used when the
                // corresponding real implementation is left out of a build.
                // We build the real ones, so these must be excluded or they
                // produce duplicate symbols.
                "src/postprocessing/postprocessing_ph.cpp",
                "src/preprocessing/preprocessing_ph.cpp",
                "src/write/write_ph.cpp"
            ],
            sources: [
                "src"
            ],
            // The target root is the include root: upstream's sources use
            // "libraw/…", "internal/…" and "../../internal/…" interchangeably.
            publicHeadersPath: ".",
            cxxSettings: [
                // LibRaw optional back-ends we deliberately do not build.
                // NO_LCMS is deliberately absent: LibRaw derives it itself from
                // the absence of USE_LCMS/USE_LCMS2, and defining it here warns.
                .define("NO_JPEG"),
                .define("LIBRAW_NODLL"),
                // Upstream's own warnings are not actionable for us and would
                // bury the ones from code we own. Scoped to this target only.
                .unsafeFlags(["-w"])
            ]
        ),
        // Our plain-C boundary: the only C++ surface Swift ever sees, and the
        // only file in the project that includes libraw/libraw.h.
        //
        // Compiled with warnings enabled — it is code we own.
        .target(
            name: "CLibRaw",
            dependencies: ["CLibRawVendor"],
            path: "Sources/CLibRaw",
            sources: [
                "shim"
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                // Must match the vendor target: LIBRAW_NODLL changes the
                // declarations in libraw_types.h.
                .define("LIBRAW_NODLL"),
                .unsafeFlags(["-Wall", "-Wextra"])
            ],
            linkerSettings: [
                .linkedLibrary("c++")
            ]
        ),
        .executableTarget(
            name: "InfraredConverter",
            dependencies: ["CLibRaw"],
            path: "Sources/InfraredConverter"
        ),
        .testTarget(
            name: "InfraredConverterTests",
            // CLibRaw is a direct dependency so the shim's own lifecycle
            // contract (which calls are valid at which stage, and what they
            // return before that) can be tested at the C boundary rather than
            // only inferred through LibRawDecoder.
            dependencies: ["InfraredConverter", "CLibRaw"],
            path: "Tests/InfraredConverterTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
