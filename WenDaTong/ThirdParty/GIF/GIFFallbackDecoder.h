#ifndef WXT_GIF_FALLBACK_DECODER_H
#define WXT_GIF_FALLBACK_DECODER_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
enum {
    WXTGIFSuccess = 0, WXTGIFInvalid = 1, WXTGIFTooLarge = 2,
    WXTGIFCancelled = 3, WXTGIFOutOfMemory = 4
};
typedef struct {
    uint32_t width, height, frame_count;
} WXTGIFInfo;
typedef struct {
    uint8_t *bgra;
    uint32_t width, height;
    double delay_seconds;
} WXTGIFFrame;
/* Structural inspection does not allocate a pixel canvas or validate LZW pixels.
 * Decode validates pixels through the requested frame. No input is retained.
 * The caller serializes expensive Decode calls; they may use up to two 64 MiB
 * canvases plus a 4 MiB output. Free successful frame.bgra with WXTGIFFree. */
int WXTGIFInspect(const uint8_t *bytes, size_t size, WXTGIFInfo *info);
int WXTGIFDecode(const uint8_t *bytes, size_t size, uint32_t frame_index,
                 uint32_t max_edge, WXTGIFFrame *frame,
                 bool (*is_cancelled)(void *), void *context);
void WXTGIFFree(void *allocation);
#ifdef __cplusplus
}
#endif
#endif
