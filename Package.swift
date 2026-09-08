// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "InfraredConverter",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // Vendored LibRaw 0.21.4 plus the small plain-C shim that is the only
        // C++ surface the Swift code ever sees.
        // See docs/decisions/0001-libraw-integration.md.
        .target(
            name: "CLibRaw",
            path: "Sources/CLibRaw",
            exclude: [
                "vendor/COPYRIGHT",
                "vendor/LICENSE.CDDL",
                "vendor/LICENSE.LGPL",
                "vendor/src/Makefile",
                // Glue for optional back-ends we do not build (Adobe DNG SDK,
                // RawSpeed). They compile to nothing but reference headers we
                // do not vendor.
                "vendor/src/integration",
                // LibRaw ships "placeholder" translation units used when the
                // corresponding real implementation is left out of a build.
                // We build the real ones, so these must be excluded or they
                // produce duplicate symbols.
                "vendor/src/postprocessing/postprocessing_ph.cpp",
                "vendor/src/preprocessing/preprocessing_ph.cpp",
                "vendor/src/write/write_ph.cpp"
            ],
            sources: [
                "shim",
                "vendor/src"
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("vendor"),
                .headerSearchPath("include"),
                // LibRaw optional back-ends we deliberately do not build.
                .define("NO_JPEG"),
                .define("NO_LCMS"),
                .define("LIBRAW_NODLL"),
                // LibRaw's own sources produce a large number of warnings that
                // are not actionable for us; keep our build output readable.
                .unsafeFlags(["-w"])
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
            dependencies: ["InfraredConverter"],
            path: "Tests/InfraredConverterTests"
        )
    ],
    cxxLanguageStandard: .cxx17
)
