# Vendored LibRaw

`Sources/CLibRawVendor/` contains **LibRaw 0.22.2**, taken unmodified from
<https://www.libraw.org/data/LibRaw-0.22.2.tar.gz>
(SHA-256 `de86b035655accff8d4010f1a221fdf50d353cb7b1422ba26f14a0db92612cfa`).

Licensing is dual LGPL-2.1 / CDDL-1.0; `LICENSE.LGPL`, `LICENSE.CDDL` and
`COPYRIGHT` are kept with the source. See
`docs/decisions/0001-libraw-integration.md` for the distribution obligations.

## Layout and targets

The build is split into two targets so that upstream's warnings can be silenced
without silencing ours.

```text
Sources/CLibRawVendor/       upstream LibRaw, verbatim          (built with -w)
├── libraw/                  upstream public headers
├── internal/                upstream internal headers
└── src/                     upstream implementation

Sources/CLibRaw/             our plain-C boundary   (built with -Wall -Wextra)
├── include/libraw_shim.h    the entire C surface Swift sees
└── shim/libraw_shim.cpp     the only file that includes libraw/libraw.h
```

```text
InfraredConverter (Swift)  →  CLibRaw (our shim)  →  CLibRawVendor (upstream)
```

Swift imports `CLibRaw` only. LibRaw's C++ API is never exposed to Swift, and
Swift/C++ interoperability is not enabled.

Nothing in `Sources/CLibRawVendor/` has been edited. The only deviation from the
tarball is which files are copied: the upstream `src/Makefile` is dropped, and
everything outside `libraw/`, `internal/`, `src/` and the licence files is not
vendored at all.

## Build configuration

Set in `Package.swift`:

| Setting | `CLibRawVendor` | `CLibRaw` |
| --- | --- | --- |
| `publicHeadersPath` | `.` — the target root is the include root, because upstream mixes `"libraw/…"`, `"internal/…"` and `"../../internal/…"` | `include` |
| `NO_JPEG` | yes | not needed (header-invisible) |
| `LIBRAW_NODLL` | yes | yes — it changes declarations in `libraw_types.h`, so it must match |
| Warnings | `-w` | `-Wall -Wextra`, and the shim builds clean |
| C++ standard | C++17 | C++17 |

`NO_LCMS` is deliberately **not** defined. LibRaw 0.22 derives it itself in
`libraw_types.h` from the absence of `USE_LCMS`/`USE_LCMS2`; defining it
explicitly produces a `-Wmacro-redefined` warning. Letting LibRaw derive it also
guarantees the vendor target and the shim agree, which matters because it gates
a member declaration in `libraw.h`.

Optional back-ends that are **not** enabled: libjpeg (lossy DNG and JPEG
thumbnail decoding), LittleCMS, zlib (deflate-compressed DNG), the Adobe DNG
SDK, RawSpeed / RawSpeed3, GoPro/GPR, and OpenMP. None is needed for the formats
this project targets; enabling one means adding the dependency and its define
together.

Excluded from the build:

- `src/integration/` — glue for the DNG SDK and RawSpeed, which reference
  headers we do not vendor.
- `src/postprocessing/postprocessing_ph.cpp`,
  `src/preprocessing/preprocessing_ph.cpp`, `src/write/write_ph.cpp` —
  upstream's *placeholder* translation units, used when a build leaves the
  corresponding real implementation out. We build the real ones, so including
  these produces duplicate symbols.
- the licence files, which are not sources.

This exclusion list was re-checked against the 0.22.2 tree. Compared with
0.21.4 the tree only gained files — `src/decoders/olympus14.cpp`,
`src/decoders/pana8.cpp`, `src/decoders/sonycc.cpp`,
`src/decompressors/losslessjpeg.cpp`, `internal/losslessjpeg.h` and
`internal/libraw_checked_buffer.h` — none of which needs excluding, and none of
which requires a new define.

## Updating

1. Download and extract the new upstream tarball; record its SHA-256 above.
2. Replace `Sources/CLibRawVendor/libraw`, `internal` and `src` wholesale, drop
   `src/Makefile`, and refresh `COPYRIGHT`, `LICENSE.LGPL` and `LICENSE.CDDL`.
3. Re-check the exclusion list and the defines above against the new tree,
   rather than assuming the previous ones still apply.
4. `swift build && swift test`, with `RAW/OLYMPUS.ORF` present.
5. Compare the fixture's reported metadata against the recorded baseline in the
   README before accepting the upgrade; a decoder change that moves those values
   is a finding, not something to paper over in the tests.
6. Update the version here, in the README, and in
   `docs/decisions/0001-libraw-integration.md`.
