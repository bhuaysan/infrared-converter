# Vendored LibRaw

`vendor/` contains **LibRaw 0.21.4**, taken unmodified from
<https://www.libraw.org/data/LibRaw-0.21.4.tar.gz>.

Licensing is dual LGPL-2.1 / CDDL-1.0; `vendor/LICENSE.LGPL`,
`vendor/LICENSE.CDDL` and `vendor/COPYRIGHT` are kept with the source. See
`docs/decisions/0001-libraw-integration.md` for the distribution obligations.

## Layout

```text
include/libraw_shim.h   the entire C surface Swift sees (ours)
shim/libraw_shim.cpp    the only file that includes libraw/libraw.h (ours)
vendor/libraw/          upstream public headers
vendor/internal/        upstream internal headers
vendor/src/             upstream implementation
```

Only `vendor/` is upstream code. Nothing in it has been edited.

## Build configuration

Set in `Package.swift`:

- header search path `vendor`, so upstream's `#include "libraw/libraw.h"` and
  `#include "../../internal/..."` both resolve,
- `NO_JPEG`, `NO_LCMS`, `LIBRAW_NODLL`,
- C++17,
- `-w`, because upstream's warnings are not actionable for us and would bury our
  own.

Optional back-ends that are **not** enabled: libjpeg (lossy DNG and JPEG
thumbnail decoding), LittleCMS, zlib (deflate-compressed DNG), the Adobe DNG
SDK, RawSpeed, and OpenMP. None is needed for the formats this project targets;
enabling one means adding the dependency and its define together.

Excluded from the build:

- `vendor/src/integration/` — glue for the DNG SDK and RawSpeed, which reference
  headers we do not vendor.
- `vendor/src/postprocessing/postprocessing_ph.cpp`,
  `vendor/src/preprocessing/preprocessing_ph.cpp`,
  `vendor/src/write/write_ph.cpp` — upstream's *placeholder* translation units,
  used when a build leaves the corresponding real implementation out. We build
  the real ones, so including these produces duplicate symbols.
- `vendor/src/Makefile` and the licence files, which are not sources.

## Updating

1. Download and extract the new upstream tarball.
2. Replace `vendor/libraw`, `vendor/internal` and `vendor/src` wholesale, and
   refresh the licence files.
3. Re-check the exclusion list above against the new source tree.
4. `swift build && swift test`.
5. Update the version in this file and in the README.
