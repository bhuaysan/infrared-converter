/*
 * libraw_shim.cpp — the only file in this project that includes LibRaw's C++ API.
 */

#include "libraw_shim.h"

#include "libraw/libraw.h"

#include <cstring>
#include <limits>
#include <new>

namespace {

void copy_string(char *dst, size_t capacity, const char *src)
{
    if (capacity == 0) {
        return;
    }
    if (src == nullptr) {
        dst[0] = '\0';
        return;
    }
    std::strncpy(dst, src, capacity - 1);
    dst[capacity - 1] = '\0';
}

/*
 * LibRaw returns either a positive errno value or one of its own negative
 * LibRaw_errors enum values. Map both onto the shim's stable classification.
 */
ir_libraw_error classify(int code)
{
    if (code == 0) {
        return IR_LIBRAW_OK;
    }
    if (code > 0) {
        /* errno from the underlying file access. */
        return IR_LIBRAW_ERR_IO;
    }
    switch (code) {
    case LIBRAW_UNSPECIFIED_ERROR:
        return IR_LIBRAW_ERR_UNKNOWN;
    case LIBRAW_FILE_UNSUPPORTED:
        return IR_LIBRAW_ERR_UNSUPPORTED_FORMAT;
    case LIBRAW_REQUEST_FOR_NONEXISTENT_IMAGE:
    case LIBRAW_OUT_OF_ORDER_CALL:
        return IR_LIBRAW_ERR_BAD_STATE;
    case LIBRAW_NO_THUMBNAIL:
    case LIBRAW_UNSUPPORTED_THUMBNAIL:
        return IR_LIBRAW_ERR_UNSUPPORTED_FORMAT;
    case LIBRAW_UNSUFFICIENT_MEMORY:
        return IR_LIBRAW_ERR_OUT_OF_MEMORY;
    case LIBRAW_DATA_ERROR:
    case LIBRAW_IO_ERROR:
        return IR_LIBRAW_ERR_CORRUPT_DATA;
    case LIBRAW_CANCELLED_BY_CALLBACK:
        return IR_LIBRAW_ERR_CANCELLED;
    case LIBRAW_BAD_CROP:
        return IR_LIBRAW_ERR_BAD_STATE;
    default:
        return IR_LIBRAW_ERR_UNKNOWN;
    }
}

ir_libraw_status make_status(int code)
{
    ir_libraw_status status;
    status.error = classify(code);
    status.libraw_code = code;
    copy_string(status.message, sizeof(status.message), libraw_strerror(code));
    return status;
}

ir_libraw_status bad_state(const char *message)
{
    ir_libraw_status status;
    status.error = IR_LIBRAW_ERR_BAD_STATE;
    status.libraw_code = 0;
    copy_string(status.message, sizeof(status.message), message);
    return status;
}

} // namespace

struct ir_libraw_context {
    LibRaw processor;
    libraw_processed_image_t *image = nullptr;
    bool opened = false;
    bool unpacked = false;
    bool processed = false;
};

extern "C" {

ir_libraw_context *ir_libraw_create(void)
{
    return new (std::nothrow) ir_libraw_context();
}

void ir_libraw_destroy(ir_libraw_context *ctx)
{
    if (ctx == nullptr) {
        return;
    }
    ir_libraw_free_image(ctx);
    ctx->processor.recycle();
    delete ctx;
}

const char *ir_libraw_version(void)
{
    return LibRaw::version();
}

void ir_libraw_default_options(ir_libraw_options *opts)
{
    if (opts == nullptr) {
        return;
    }
    /*
     * These defaults exist to keep the decoder boundary free of irreversible
     * colour decisions. See docs/decisions/0001-libraw-integration.md.
     */
    opts->output_bps = 16;
    opts->output_color = 0;   /* raw camera colour: no colour-space conversion */
    opts->linear_gamma = 1;
    opts->use_camera_wb = 0;
    opts->use_auto_wb = 0;
    opts->use_camera_matrix = 0;
    opts->no_auto_bright = 1;
    opts->highlight_mode = 0; /* clip; no undocumented reconstruction */
    opts->demosaic_quality = 3; /* AHD */
    opts->half_size = 0;
    opts->user_flip = -1;     /* honour the camera's recorded orientation */
    opts->adjust_maximum_thr = 0.0f;
    opts->user_mul[0] = 1.0f;
    opts->user_mul[1] = 1.0f;
    opts->user_mul[2] = 1.0f;
    opts->user_mul[3] = 1.0f;
}

void ir_libraw_apply_options(ir_libraw_context *ctx, const ir_libraw_options *opts)
{
    if (ctx == nullptr || opts == nullptr) {
        return;
    }
    libraw_output_params_t &p = ctx->processor.imgdata.params;

    p.output_bps = opts->output_bps;
    p.output_color = opts->output_color;
    p.gamm[0] = opts->linear_gamma ? 1.0 : (1.0 / 2.4);
    p.gamm[1] = opts->linear_gamma ? 1.0 : 12.92;
    p.use_camera_wb = opts->use_camera_wb;
    p.use_auto_wb = opts->use_auto_wb;
    p.use_camera_matrix = opts->use_camera_matrix;
    p.no_auto_bright = opts->no_auto_bright;
    p.bright = 1.0f;
    p.highlight = opts->highlight_mode;
    p.user_qual = opts->demosaic_quality;
    p.half_size = opts->half_size;
    p.user_flip = opts->user_flip;
    p.adjust_maximum_thr = opts->adjust_maximum_thr;
    for (int i = 0; i < 4; ++i) {
        p.user_mul[i] = opts->user_mul[i];
    }

    /* Explicitly pin everything else that would otherwise alter pixel values. */
    p.four_color_rgb = 0;
    p.med_passes = 0;
    p.threshold = 0.0f;    /* no wavelet noise reduction */
    p.fbdd_noiserd = 0;
    p.exp_correc = 0;
    p.green_matching = 0;
    p.use_fuji_rotate = 1; /* geometric only */
    p.no_auto_scale = 0;
    p.no_interpolation = 0;
    p.user_black = -1;     /* use the camera's black level */
    p.user_sat = -1;       /* use the camera's saturation level */
    p.output_profile = nullptr;
    p.camera_profile = nullptr;
    p.bad_pixels = nullptr;
    p.dark_frame = nullptr;
}

ir_libraw_status ir_libraw_open_file(ir_libraw_context *ctx, const char *path)
{
    if (ctx == nullptr || path == nullptr) {
        return bad_state("Invalid decoder context");
    }
    const int code = ctx->processor.open_file(path);
    ctx->opened = (code == LIBRAW_SUCCESS);
    return make_status(code);
}

ir_libraw_status ir_libraw_unpack(ir_libraw_context *ctx)
{
    if (ctx == nullptr) {
        return bad_state("Invalid decoder context");
    }
    if (!ctx->opened) {
        return bad_state("unpack called before a successful open");
    }
    const int code = ctx->processor.unpack();
    ctx->unpacked = (code == LIBRAW_SUCCESS);
    return make_status(code);
}

ir_libraw_status ir_libraw_process(ir_libraw_context *ctx)
{
    if (ctx == nullptr) {
        return bad_state("Invalid decoder context");
    }
    if (!ctx->unpacked) {
        return bad_state("process called before a successful unpack");
    }
    const int code = ctx->processor.dcraw_process();
    ctx->processed = (code == LIBRAW_SUCCESS);
    return make_status(code);
}

ir_libraw_status ir_libraw_copy_metadata(ir_libraw_context *ctx,
                                         ir_libraw_metadata *out)
{
    if (ctx == nullptr || out == nullptr) {
        return bad_state("Invalid decoder context");
    }
    if (!ctx->opened) {
        return bad_state("Metadata requested before a successful open");
    }

    std::memset(out, 0, sizeof(*out));

    const libraw_data_t &d = ctx->processor.imgdata;

    copy_string(out->make, sizeof(out->make), d.idata.make);
    copy_string(out->model, sizeof(out->model), d.idata.model);
    copy_string(out->normalized_make, sizeof(out->normalized_make), d.idata.normalized_make);
    copy_string(out->normalized_model, sizeof(out->normalized_model), d.idata.normalized_model);
    copy_string(out->software, sizeof(out->software), d.idata.software);

    out->raw_width = d.sizes.raw_width;
    out->raw_height = d.sizes.raw_height;
    out->visible_width = d.sizes.width;
    out->visible_height = d.sizes.height;
    out->top_margin = d.sizes.top_margin;
    out->left_margin = d.sizes.left_margin;
    out->output_width = d.sizes.iwidth;
    out->output_height = d.sizes.iheight;
    out->flip = d.sizes.flip;
    out->pixel_aspect = d.sizes.pixel_aspect;

    out->filters = d.idata.filters;
    copy_string(out->cdesc, sizeof(out->cdesc), d.idata.cdesc);
    out->colors = d.idata.colors;
    out->raw_bps = d.color.raw_bps;
    out->is_foveon = static_cast<int>(d.idata.is_foveon);

    /* filters == 9 is LibRaw's marker for a 6x6 X-Trans layout. */
    out->has_xtrans = (d.idata.filters == 9) ? 1 : 0;
    std::memcpy(out->xtrans, d.idata.xtrans, sizeof(out->xtrans));

    out->black = d.color.black;
    for (int i = 0; i < 4; ++i) {
        out->cblack[i] = d.color.cblack[i];
        out->linear_max[i] = static_cast<int32_t>(d.color.linear_max[i]);
    }

    /*
     * cblack[4]/cblack[5] describe an optional per-pixel black pattern;
     * cblack[6 + r*cols + c] holds the pattern value at pattern row r,
     * column c. Copy defensively: a malformed file could report rows/cols
     * that do not fit LibRaw's own LIBRAW_CBLACK_SIZE-entry storage, or that
     * exceed this shim's IR_LIBRAW_MAX_BLACK_PATTERN cap; in either case we
     * report no pattern rather than read out of bounds or overrun our
     * fixed-size array.
     */
    {
        const uint64_t rows = d.color.cblack[4];
        const uint64_t cols = d.color.cblack[5];
        const uint64_t headerEntries = 6;
        const uint64_t available =
            (LIBRAW_CBLACK_SIZE > headerEntries) ? (LIBRAW_CBLACK_SIZE - headerEntries) : 0;
        uint64_t count = (rows > 0 && cols > 0) ? (rows * cols) : 0;
        if (count > available || count > IR_LIBRAW_MAX_BLACK_PATTERN) {
            count = 0;
        }
        if (count > 0) {
            out->cblack_pattern_rows = static_cast<uint32_t>(rows);
            out->cblack_pattern_cols = static_cast<uint32_t>(cols);
            for (uint64_t i = 0; i < count; ++i) {
                out->black_pattern[i] = d.color.cblack[headerEntries + i];
            }
            out->black_pattern_count = static_cast<uint32_t>(count);
        } else {
            out->cblack_pattern_rows = 0;
            out->cblack_pattern_cols = 0;
            out->black_pattern_count = 0;
        }
    }

    out->maximum = d.color.maximum;
    out->data_maximum = d.color.data_maximum;

    out->has_cam_mul = (d.color.cam_mul[0] > 0.0f) ? 1 : 0;
    out->has_pre_mul = (d.color.pre_mul[0] > 0.0f) ? 1 : 0;
    for (int i = 0; i < 4; ++i) {
        out->cam_mul[i] = d.color.cam_mul[i];
        out->pre_mul[i] = d.color.pre_mul[i];
    }
    std::memcpy(out->rgb_cam, d.color.rgb_cam, sizeof(out->rgb_cam));
    std::memcpy(out->cam_xyz, d.color.cam_xyz, sizeof(out->cam_xyz));
    out->has_rgb_cam = (d.color.rgb_cam[0][0] != 0.0f || d.color.rgb_cam[1][1] != 0.0f) ? 1 : 0;
    out->has_cam_xyz = (d.color.cam_xyz[0][0] != 0.0f || d.color.cam_xyz[1][1] != 0.0f) ? 1 : 0;
    out->as_shot_wb_applied = d.color.as_shot_wb_applied;

    out->iso_speed = d.other.iso_speed;
    out->has_iso = (d.other.iso_speed > 0.0f) ? 1 : 0;
    out->shutter = d.other.shutter;
    out->has_shutter = (d.other.shutter > 0.0f) ? 1 : 0;
    out->aperture = d.other.aperture;
    out->has_aperture = (d.other.aperture > 0.0f) ? 1 : 0;
    out->focal_len = d.other.focal_len;
    out->has_focal = (d.other.focal_len > 0.0f) ? 1 : 0;
    out->timestamp = static_cast<int64_t>(d.other.timestamp);
    out->has_timestamp = (d.other.timestamp != 0) ? 1 : 0;

    copy_string(out->lens, sizeof(out->lens), d.lens.Lens);
    copy_string(out->artist, sizeof(out->artist), d.other.artist);

    return make_status(LIBRAW_SUCCESS);
}

ir_libraw_status ir_libraw_make_image(ir_libraw_context *ctx, ir_libraw_image *out)
{
    if (ctx == nullptr || out == nullptr) {
        return bad_state("Invalid decoder context");
    }
    if (!ctx->processed) {
        return bad_state("Image requested before a successful process");
    }

    ir_libraw_free_image(ctx);

    int code = LIBRAW_SUCCESS;
    libraw_processed_image_t *image = ctx->processor.dcraw_make_mem_image(&code);
    if (image == nullptr) {
        return make_status(code == LIBRAW_SUCCESS ? LIBRAW_UNSPECIFIED_ERROR : code);
    }
    if (image->type != LIBRAW_IMAGE_BITMAP) {
        LibRaw::dcraw_clear_mem(image);
        return bad_state("LibRaw returned a non-bitmap image");
    }

    /*
     * LibRaw's own fields are narrower (width/height/colors/bits are all
     * unsigned short), but this project's contract does not trust that: a
     * malformed or hostile file could still make width * colors * (bits / 8)
     * wrap if computed in 32 bits, so every step is validated in size_t
     * before it is reported. Any failure here is a shim-level bad-state
     * status, never a wrapped size handed to the caller.
     */
    if (image->width == 0 || image->height == 0 || image->colors == 0 || image->bits == 0) {
        LibRaw::dcraw_clear_mem(image);
        return bad_state("LibRaw produced a zero-sized image");
    }
    if (image->bits % 8 != 0) {
        LibRaw::dcraw_clear_mem(image);
        return bad_state("LibRaw produced a non-byte-aligned bit depth");
    }

    const size_t width = static_cast<size_t>(image->width);
    const size_t height = static_cast<size_t>(image->height);
    const size_t colors = static_cast<size_t>(image->colors);
    const size_t bytesPerSample = static_cast<size_t>(image->bits / 8);

    auto checkedMul = [](size_t a, size_t b, size_t &result) -> bool {
        if (a != 0 && b > (std::numeric_limits<size_t>::max)() / a) {
            return false;
        }
        result = a * b;
        return true;
    };

    size_t bytesPerRow = 0;
    size_t bytesPerPixel = 0;
    if (!checkedMul(colors, bytesPerSample, bytesPerPixel) ||
        !checkedMul(width, bytesPerPixel, bytesPerRow)) {
        LibRaw::dcraw_clear_mem(image);
        return bad_state("Row size for the decoded image overflows");
    }

    size_t expectedBytes = 0;
    if (!checkedMul(bytesPerRow, height, expectedBytes)) {
        LibRaw::dcraw_clear_mem(image);
        return bad_state("Buffer size for the decoded image overflows");
    }

    const size_t reportedBytes = static_cast<size_t>(image->data_size);
    if (reportedBytes < expectedBytes) {
        LibRaw::dcraw_clear_mem(image);
        return bad_state("LibRaw's reported buffer size is smaller than its own geometry implies");
    }

    ctx->image = image;

    std::memset(out, 0, sizeof(*out));
    out->width = image->width;
    out->height = image->height;
    out->colors = image->colors;
    out->bits = image->bits;
    out->bytes_per_row = bytesPerRow;
    out->byte_count = reportedBytes;
    out->bytes = image->data;

    return make_status(LIBRAW_SUCCESS);
}

uint32_t ir_libraw_process_warnings(const ir_libraw_context *ctx)
{
    if (ctx == nullptr || !ctx->processed) {
        return 0;
    }
    return static_cast<uint32_t>(ctx->processor.imgdata.process_warnings);
}

void ir_libraw_free_image(ir_libraw_context *ctx)
{
    if (ctx == nullptr || ctx->image == nullptr) {
        return;
    }
    LibRaw::dcraw_clear_mem(ctx->image);
    ctx->image = nullptr;
}

} // extern "C"
