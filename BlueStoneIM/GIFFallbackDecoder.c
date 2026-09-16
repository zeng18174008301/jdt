#include "GIFFallbackDecoder.h"
#include <stdlib.h>
#include <string.h>

/* Unmodified Apache-2.0 Wuffs v0.3.5, upstream commit
 * d1a6f2c3de7e52b8775782028e5a49946a7f9184; generated-file SHA256
 * 82c6741dd751eb962a287882991836498526eb02dbe0c7f19adc01810b8bac96.
 * Only BASE/LZW/GIF compile. See ThirdParty/Wuffs/LICENSE. Composition follows
 * upstream example/gifplayer/gifplayer.c; no ImageIO or custom LZW is involved. */
#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__STATIC_FUNCTIONS
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__LZW
#define WUFFS_CONFIG__MODULE__GIF
#include "ThirdParty/Wuffs/wuffs-v0.3.c"

#define WXT_GIF_MAX_BYTES (10u * 1024u * 1024u)
#define WXT_GIF_MAX_PIXELS (16u * 1024u * 1024u)
#define WXT_GIF_INPUT_STEP 64u

typedef struct {
    wuffs_gif__decoder decoder;
    wuffs_base__io_buffer source;
    wuffs_base__image_config image;
    bool (*cancelled)(void *);
    void *context;
} WXTGIFReader;

static bool WXTGIFShouldCancel(WXTGIFReader *reader) {
    return reader->cancelled && reader->cancelled(reader->context);
}

/* Feed bounded chunks so even highly compressed frames have cancellation
 * checkpoints inside Wuffs' resumable decode, not merely between whole frames.
 * A short read at final EOF is always invalid, never a completed frame. */
static bool WXTGIFMoreInput(WXTGIFReader *reader) {
    size_t remaining = reader->source.data.len - reader->source.meta.wi;
    if (!remaining) return false;
    reader->source.meta.wi += remaining < WXT_GIF_INPUT_STEP ? remaining : WXT_GIF_INPUT_STEP;
    reader->source.meta.closed = reader->source.meta.wi == reader->source.data.len;
    return true;
}

static int WXTGIFStart(WXTGIFReader *reader, const uint8_t *bytes, size_t size,
                       bool (*cancelled)(void *), void *context) {
    if (!bytes || size < 14) return WXTGIFInvalid;
    if (size > WXT_GIF_MAX_BYTES) return WXTGIFTooLarge;
    if (memcmp(bytes, "GIF87a", 6) && memcmp(bytes, "GIF89a", 6)) return WXTGIFInvalid;
    memset(reader, 0, sizeof(*reader));
    reader->cancelled = cancelled;
    reader->context = context;
    if (WXTGIFShouldCancel(reader)) return WXTGIFCancelled;
    wuffs_base__status status = wuffs_gif__decoder__initialize(
        &reader->decoder, sizeof(reader->decoder), WUFFS_VERSION, 0);
    if (!wuffs_base__status__is_ok(&status)) return WXTGIFInvalid;
    /* Wuffs only borrows input; its public io_buffer uses a mutable pointer. */
    reader->source.data = wuffs_base__make_slice_u8((uint8_t *)bytes, size);
    WXTGIFMoreInput(reader);
    for (;;) {
        if (WXTGIFShouldCancel(reader)) return WXTGIFCancelled;
        status = wuffs_gif__decoder__decode_image_config(
            &reader->decoder, &reader->image, &reader->source);
        if (wuffs_base__status__is_ok(&status)) break;
        if (status.repr != wuffs_base__suspension__short_read || !WXTGIFMoreInput(reader))
            return WXTGIFInvalid;
    }
    uint32_t width = wuffs_base__pixel_config__width(&reader->image.pixcfg);
    uint32_t height = wuffs_base__pixel_config__height(&reader->image.pixcfg);
    if (!width || !height) return WXTGIFInvalid;
    if ((uint64_t)width * height > WXT_GIF_MAX_PIXELS) return WXTGIFTooLarge;
    return WXTGIFSuccess;
}

/* Returns end separately because only the GIF trailer, not EOF, completes an
 * inspection. This accepts permitted trailing bytes after the first GIF. */
static int WXTGIFNextConfig(WXTGIFReader *reader, wuffs_base__frame_config *config,
                            bool *ended) {
    *ended = false;
    for (;;) {
        if (WXTGIFShouldCancel(reader)) return WXTGIFCancelled;
        wuffs_base__status status = wuffs_gif__decoder__decode_frame_config(
            &reader->decoder, config, &reader->source);
        if (wuffs_base__status__is_ok(&status)) return WXTGIFSuccess;
        if (status.repr == wuffs_base__note__end_of_data) {
            size_t position = reader->source.meta.ri;
            if (!position || reader->source.data.ptr[position - 1] != 0x3B)
                return WXTGIFInvalid;
            *ended = true;
            return WXTGIFSuccess;
        }
        if (status.repr != wuffs_base__suspension__short_read || !WXTGIFMoreInput(reader))
            return WXTGIFInvalid;
    }
}

static int WXTGIFInspectInternal(const uint8_t *bytes, size_t size, WXTGIFInfo *info,
                                 bool (*cancelled)(void *), void *context) {
    if (!info) return WXTGIFInvalid;
    memset(info, 0, sizeof(*info));
    WXTGIFReader reader;
    int result = WXTGIFStart(&reader, bytes, size, cancelled, context);
    if (result) return result;
    uint32_t count = 0;
    for (;;) {
        wuffs_base__frame_config config = {0};
        bool ended;
        result = WXTGIFNextConfig(&reader, &config, &ended);
        if (result) return result;
        if (ended) break;
        if (count == UINT32_MAX) return WXTGIFTooLarge;
        count++;
    }
    if (!count) return WXTGIFInvalid;
    info->width = wuffs_base__pixel_config__width(&reader.image.pixcfg);
    info->height = wuffs_base__pixel_config__height(&reader.image.pixcfg);
    info->frame_count = count;
    return WXTGIFSuccess;
}

int WXTGIFInspect(const uint8_t *bytes, size_t size, WXTGIFInfo *info) {
    return WXTGIFInspectInternal(bytes, size, info, NULL, NULL);
}

static int WXTGIFFill(WXTGIFReader *reader, uint8_t *canvas,
                      uint32_t width, uint32_t height,
                      wuffs_base__rect_ie_u32 bounds, uint32_t color) {
    if (bounds.max_excl_x > width || bounds.max_excl_y > height ||
        bounds.min_incl_x > bounds.max_excl_x || bounds.min_incl_y > bounds.max_excl_y)
        return WXTGIFInvalid;
    for (uint32_t y = bounds.min_incl_y; y < bounds.max_excl_y; y++) {
        if (WXTGIFShouldCancel(reader)) return WXTGIFCancelled;
        uint8_t *row = canvas + ((size_t)y * width + bounds.min_incl_x) * 4;
        for (uint32_t x = bounds.min_incl_x; x < bounds.max_excl_x; x++, row += 4) {
            row[0] = (uint8_t)color;
            row[1] = (uint8_t)(color >> 8);
            row[2] = (uint8_t)(color >> 16);
            row[3] = (uint8_t)(color >> 24);
        }
    }
    return WXTGIFSuccess;
}

int WXTGIFDecode(const uint8_t *bytes, size_t size, uint32_t frame_index,
                 uint32_t max_edge, WXTGIFFrame *frame,
                 bool (*is_cancelled)(void *), void *context) {
    if (!frame) return WXTGIFInvalid;
    memset(frame, 0, sizeof(*frame));
    if (!max_edge || max_edge > 1024) return WXTGIFInvalid;
    WXTGIFInfo info;
    int result = WXTGIFInspectInternal(bytes, size, &info, is_cancelled, context);
    if (result) return result;
    if (frame_index >= info.frame_count) return WXTGIFInvalid;
    WXTGIFReader reader;
    result = WXTGIFStart(&reader, bytes, size, is_cancelled, context);
    if (result) return result;
    /* Pinned GIF decoder requires zero external work bytes. */
    if (wuffs_gif__decoder__workbuf_len(&reader.decoder).max_incl != 0)
        return WXTGIFInvalid;
    size_t canvas_size = (size_t)info.width * info.height * 4;
    uint8_t *canvas = calloc(canvas_size, 1);
    uint8_t *previous = NULL;
    uint8_t *output = NULL;
    if (!canvas) return WXTGIFOutOfMemory;
    wuffs_base__pixel_config pixcfg = {0};
    wuffs_base__pixel_config__set(&pixcfg, WUFFS_BASE__PIXEL_FORMAT__BGRA_PREMUL,
        WUFFS_BASE__PIXEL_SUBSAMPLING__NONE, info.width, info.height);
    wuffs_base__pixel_buffer pixels = {0};
    wuffs_base__status status = wuffs_base__pixel_buffer__set_from_slice(
        &pixels, &pixcfg, wuffs_base__make_slice_u8(canvas, canvas_size));
    if (!wuffs_base__status__is_ok(&status)) { result = WXTGIFInvalid; goto done; }
    for (uint32_t index = 0; index <= frame_index; index++) {
        wuffs_base__frame_config config = {0};
        bool ended;
        result = WXTGIFNextConfig(&reader, &config, &ended);
        if (result) goto done;
        if (ended) { result = WXTGIFInvalid; goto done; }
        uint32_t background = wuffs_base__frame_config__background_color(&config);
        if (!index) {
            wuffs_base__rect_ie_u32 full = {0, 0, info.width, info.height};
            result = WXTGIFFill(&reader, canvas, info.width, info.height, full, background);
            if (result) goto done;
        }
        uint32_t disposal = wuffs_base__frame_config__disposal(&config);
        if (index != frame_index && disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_PREVIOUS) {
            previous = malloc(canvas_size);
            if (!previous) { result = WXTGIFOutOfMemory; goto done; }
            for (uint32_t y = 0; y < info.height; y++) {
                if (WXTGIFShouldCancel(&reader)) { result = WXTGIFCancelled; goto done; }
                memcpy(previous + (size_t)y * info.width * 4,
                       canvas + (size_t)y * info.width * 4, (size_t)info.width * 4);
            }
        }
        for (;;) {
            if (WXTGIFShouldCancel(&reader)) { result = WXTGIFCancelled; goto done; }
            status = wuffs_gif__decoder__decode_frame(&reader.decoder, &pixels, &reader.source,
                wuffs_base__frame_config__overwrite_instead_of_blend(&config)
                    ? WUFFS_BASE__PIXEL_BLEND__SRC : WUFFS_BASE__PIXEL_BLEND__SRC_OVER,
                wuffs_base__make_slice_u8(NULL, 0), NULL);
            if (wuffs_base__status__is_ok(&status)) break;
            if (status.repr != wuffs_base__suspension__short_read || !WXTGIFMoreInput(&reader)) {
                result = WXTGIFInvalid; goto done;
            }
        }
        if (WXTGIFShouldCancel(&reader)) { result = WXTGIFCancelled; goto done; }
        if (index == frame_index) {
            uint32_t longest = info.width > info.height ? info.width : info.height;
            uint32_t out_width = longest <= max_edge ? info.width : (uint32_t)((uint64_t)info.width * max_edge / longest);
            uint32_t out_height = longest <= max_edge ? info.height : (uint32_t)((uint64_t)info.height * max_edge / longest);
            if (!out_width) out_width = 1;
            if (!out_height) out_height = 1;
            output = malloc((size_t)out_width * out_height * 4);
            if (!output) { result = WXTGIFOutOfMemory; goto done; }
            for (uint32_t y = 0; y < out_height; y++) {
                if (WXTGIFShouldCancel(&reader)) { result = WXTGIFCancelled; goto done; }
                uint32_t sy = (uint32_t)((uint64_t)y * info.height / out_height);
                for (uint32_t x = 0; x < out_width; x++) {
                    uint32_t sx = (uint32_t)((uint64_t)x * info.width / out_width);
                    memcpy(output + ((size_t)y * out_width + x) * 4,
                           canvas + ((size_t)sy * info.width + sx) * 4, 4);
                }
            }
            if (WXTGIFShouldCancel(&reader)) { result = WXTGIFCancelled; goto done; }
            frame->bgra = output;
            frame->width = out_width;
            frame->height = out_height;
            double delay = (double)wuffs_base__frame_config__duration(&config) / WUFFS_BASE__FLICKS_PER_SECOND;
            frame->delay_seconds = delay <= 0 ? 0.1 : (delay < 0.02 ? 0.02 : delay);
            output = NULL;
            break;
        }
        if (disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_BACKGROUND) {
            result = WXTGIFFill(&reader, canvas, info.width, info.height,
                wuffs_base__frame_config__bounds(&config), background);
            if (result) goto done;
        } else if (disposal == WUFFS_BASE__ANIMATION_DISPOSAL__RESTORE_PREVIOUS) {
            for (uint32_t y = 0; y < info.height; y++) {
                if (WXTGIFShouldCancel(&reader)) { result = WXTGIFCancelled; goto done; }
                memcpy(canvas + (size_t)y * info.width * 4,
                       previous + (size_t)y * info.width * 4, (size_t)info.width * 4);
            }
        }
        free(previous);
        previous = NULL;
    }
done:
    free(output);
    free(previous);
    free(canvas);
    return result;
}

void WXTGIFFree(void *allocation) { free(allocation); }
