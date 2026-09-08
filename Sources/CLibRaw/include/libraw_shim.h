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

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

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

/* "0.21.4" */
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
    uint32_t cblack_pattern_rows;
    uint32_t cblack_pattern_cols;
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
    uint32_t bytes_per_row;
    uint32_t byte_count;
    const uint8_t *bytes;       /* owned by the context until _free_image */
} ir_libraw_image;

/* Pipeline ---------------------------------------------------------------- */

/* Must be called before open; the options are stored on the context. */
void ir_libraw_apply_options(ir_libraw_context *ctx, const ir_libraw_options *opts);

ir_libraw_status ir_libraw_open_file(ir_libraw_context *ctx, const char *path);
ir_libraw_status ir_libraw_unpack(ir_libraw_context *ctx);
ir_libraw_status ir_libraw_process(ir_libraw_context *ctx);

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
