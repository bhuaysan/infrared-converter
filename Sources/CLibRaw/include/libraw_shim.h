/*
 * libraw_shim.h — the entire C surface Swift sees of LibRaw.
 *
 * LibRaw is a C++ library. Rather than enabling Swift/C++ interoperability for
 * the whole application target (which would pull LibRaw's C++ class hierarchy,
 * iostreams-based datastreams and template machinery into Swift's view of the
 * module), this header declares a deliberately small, plain-C boundary that is
 * implemented in shim/libraw_shim.cpp.
 *
 * Everything here is POD: no ownership subtleties beyond the opaque context and
 * the explicitly freed decoded image.
 *
 * This shim performs no interpretation of RAW data. It reports what LibRaw
 * reports and applies only the processing options the caller passes in.
 */

#ifndef IR_LIBRAW_SHIM_H
#define IR_LIBRAW_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Defensive cap on the number of black-pattern values the shim will copy out
 * of LibRaw's imgdata.color.cblack[6...]. LibRaw itself bounds cblack at
 * LIBRAW_CBLACK_SIZE (4104) entries, 6 of which are the row/column header;
 * this cap is comfortably below that and exists so a malformed file cannot
 * make the shim report an implausibly large pattern.
 */
#define IR_LIBRAW_MAX_BLACK_PATTERN 4096

/* Errors ------------------------------------------------------------------ */

/*
 * Stable, shim-owned error codes. LibRaw's own integer codes (both errno-style
 * positives and LibRaw's negative enum values) are preserved separately in
 * ir_libraw_status.libraw_code so they remain available for diagnostics without
 * leaking into the application's error model.
 */
typedef enum {
    IR_LIBRAW_OK = 0,
    IR_LIBRAW_ERR_UNSUPPORTED_FORMAT = 1,
    IR_LIBRAW_ERR_IO = 2,
    IR_LIBRAW_ERR_OUT_OF_MEMORY = 3,
    IR_LIBRAW_ERR_CORRUPT_DATA = 4,
    IR_LIBRAW_ERR_CANCELLED = 5,
    IR_LIBRAW_ERR_BAD_STATE = 6,
    IR_LIBRAW_ERR_UNKNOWN = 7
} ir_libraw_error;

typedef struct {
    ir_libraw_error error;   /* shim-level classification */
    int libraw_code;         /* raw LibRaw return code, 0 on success */
    char message[128];       /* LibRaw::strerror() text, NUL-terminated */
} ir_libraw_status;

/* Context ----------------------------------------------------------------- */

typedef struct ir_libraw_context ir_libraw_context;

/* Returns NULL only on allocation failure. */
ir_libraw_context *ir_libraw_create(void);
void ir_libraw_destroy(ir_libraw_context *ctx);

/* Returns the vendored LibRaw's own version string, e.g. "0.22.2". */
const char *ir_libraw_version(void);

/* Processing options ------------------------------------------------------ */

/*
 * Mirrors the subset of libraw_output_params_t this project deliberately
 * controls. Every field is set explicitly by ir_libraw_apply_options so that no
 * LibRaw default silently determines processing semantics.
 */
typedef struct {
    int output_bps;          /* 8 or 16 */
    int output_color;        /* LibRaw -o: 0 = raw camera colour, no conversion */
    int linear_gamma;        /* non-zero => gamm[0] = gamm[1] = 1.0 (no gamma) */
    int use_camera_wb;       /* LibRaw -w */
    int use_auto_wb;         /* LibRaw -a */
    int use_camera_matrix;   /* LibRaw +M/-M */
    int no_auto_bright;      /* LibRaw -W */
    int highlight_mode;      /* LibRaw -H: 0 = clip */
    int demosaic_quality;    /* LibRaw -q */
    int half_size;           /* LibRaw -h */
    int user_flip;           /* LibRaw -t: -1 = camera orientation, 0 = none */
    float adjust_maximum_thr;/* 0.0 disables LibRaw's automatic maximum tweak */
    /*
     * Applied verbatim as libraw_output_params_t.user_mul. All-ones means
     * "unity", i.e. LibRaw performs no white-balance colour decision.
     * A zeroed array would let LibRaw fall back to its own pre-multipliers.
     */
    float user_mul[4];
} ir_libraw_options;

/* Fills opts with this project's documented defaults. */
void ir_libraw_default_options(ir_libraw_options *opts);

/* Metadata ---------------------------------------------------------------- */

typedef struct {
    /* Identity */
    char make[64];
    char model[64];
    char normalized_make[64];
    char normalized_model[64];
    char software[64];

    /* Geometry (all in sensor/pixel units) */
    uint32_t raw_width, raw_height;
    uint32_t visible_width, visible_height;
    uint32_t top_margin, left_margin;
    uint32_t output_width, output_height; /* iwidth/iheight, after flip */
    int flip;
    double pixel_aspect;

    /* Sensor colour layout */
    uint32_t filters;      /* LibRaw CFA pattern code; 0 => not a simple mosaic */
    char cdesc[5];         /* colour-plane letters, e.g. "RGBG" */
    int colors;            /* number of distinct colour planes */
    uint32_t raw_bps;      /* bits per raw sample as reported by the decoder */
    int is_foveon;
    int has_xtrans;        /* non-zero => xtrans[6][6] is meaningful */
    char xtrans[6][6];

    /* Levels */
    uint32_t black;
    uint32_t cblack[4];        /* per-plane black offsets */
    /*
     * Optional repeating per-pixel black pattern, from LibRaw's
     * imgdata.color.cblack[4] (row count), cblack[5] (column count) and
     * cblack[6 + r * cblack[5] + c] (the pattern value at pattern row r,
     * column c). The pattern is indexed by active/visible-image coordinates
     * (the convention LibRaw itself uses when applying it), not raw-frame
     * coordinates.
     *
     * cblack_pattern_rows/cols are 0 when LibRaw reports no pattern, or when
     * the reported dimensions do not fit LibRaw's own cblack storage or this
     * shim's IR_LIBRAW_MAX_BLACK_PATTERN cap — in that case black_pattern is
     * unpopulated and must not be used. black_pattern_count is always
     * cblack_pattern_rows * cblack_pattern_cols when a pattern is present.
     */
    uint32_t cblack_pattern_rows;
    uint32_t cblack_pattern_cols;
    uint32_t black_pattern[IR_LIBRAW_MAX_BLACK_PATTERN];
    uint32_t black_pattern_count;
    uint32_t maximum;
    uint32_t data_maximum;
    int32_t linear_max[4];

    /* Colour metadata (visible-light calibrated; see docs) */
    int has_cam_mul;
    float cam_mul[4];          /* as-shot camera white balance */
    int has_pre_mul;
    float pre_mul[4];          /* LibRaw daylight pre-multipliers */
    int has_rgb_cam;
    float rgb_cam[3][4];
    int has_cam_xyz;
    float cam_xyz[4][3];
    int as_shot_wb_applied;

    /* Capture */
    int has_iso;      float iso_speed;
    int has_shutter;  float shutter;      /* seconds */
    int has_aperture; float aperture;     /* f-number */
    int has_focal;    float focal_len;    /* mm */
    int has_timestamp; int64_t timestamp; /* Unix seconds */

    char lens[128];
    char artist[64];
} ir_libraw_metadata;

/* Decoded image ----------------------------------------------------------- */

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t colors;            /* channels per pixel, interleaved */
    uint32_t bits;              /* bits per channel */
    /*
     * Memory-describing fields, sized size_t and validated (non-overflowing,
     * consistent with LibRaw's own reported data size) before being handed
     * back — see ir_libraw_make_image. bytes_per_row == width * colors *
     * (bits / 8); byte_count is LibRaw's reported buffer size, which may
     * exceed bytes_per_row * height but is guaranteed not to be smaller.
     */
    size_t bytes_per_row;
    size_t byte_count;
    const uint8_t *bytes;       /* owned by the context until _free_image */
} ir_libraw_image;

/* Pipeline ---------------------------------------------------------------- */

/* Must be called before open; the options are stored on the context. */
void ir_libraw_apply_options(ir_libraw_context *ctx, const ir_libraw_options *opts);

ir_libraw_status ir_libraw_open_file(ir_libraw_context *ctx, const char *path);
ir_libraw_status ir_libraw_unpack(ir_libraw_context *ctx);
ir_libraw_status ir_libraw_process(ir_libraw_context *ctx);

/*
 * Bitfield of LibRaw_warnings values (see LibRaw_warnings in
 * Sources/CLibRawVendor/libraw/libraw_const.h), raised while unpacking and
 * processing this file. This is a verbatim, uninterpreted copy of
 * imgdata.process_warnings — the shim performs no filtering or mapping;
 * Swift decides which flags are meaningful for this build.
 *
 * Only meaningful after a successful ir_libraw_process (process_warnings is
 * populated during unpack/dcraw_process, not at open); returns 0 before
 * that, which is indistinguishable from "no warnings" but the caller only
 * calls this post-process.
 */
uint32_t ir_libraw_process_warnings(const ir_libraw_context *ctx);

/* Valid any time after a successful open. */
ir_libraw_status ir_libraw_copy_metadata(ir_libraw_context *ctx,
                                         ir_libraw_metadata *out);

/*
 * Valid after ir_libraw_process. The returned bytes stay alive until
 * ir_libraw_free_image or ir_libraw_destroy.
 */
ir_libraw_status ir_libraw_make_image(ir_libraw_context *ctx, ir_libraw_image *out);
void ir_libraw_free_image(ir_libraw_context *ctx);

#ifdef __cplusplus
}
#endif

#endif /* IR_LIBRAW_SHIM_H */
