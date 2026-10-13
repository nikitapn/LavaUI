#pragma once

// mpv, rendered by mpv and drawn by whoever owns the GPU.
//
// libmpv's render API has two backends, OpenGL and software, and neither one
// is a window. That is what makes it embeddable, and it fixes the shape of
// this: a thread of our own owns a GL context with no window behind it, mpv
// renders into framebuffers we hand it, and every finished frame is given to
// the caller to show.
//
// Two ways to give it, picked at create time:
//
//   * **dma-buf.** The framebuffers are dma-bufs allocated on the GPU the
//     *renderer* uses — a compositor's — and wrapped as EGLImages. The caller
//     hands each buffer to the renderer once (`attach`) and then names the one
//     holding a finished frame (`present`). No pixel crosses the CPU.
//   * **pixels.** mpv's software renderer into memory, handed over as rows
//     (`present_pixels`). For a renderer that cannot import a buffer — the
//     built-in, windowed one — and as the fallback when the GPU path will not
//     come up. Slow, and correct.
//
// mpv itself is driven through its own client API (`lava_video_mpv`):
// commands, properties, events. This file owns only the drawing.

#include <stddef.h>
#include <stdint.h>

// Forward-declared rather than included, so a Swift module importing both
// this and `CMpv` sees one `mpv_handle`, not two. Both are an OpaquePointer.
struct mpv_handle;

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LavaVideo LavaVideo;

/// One dma-buf as its allocator describes it. `fd` is the bridge's; a callee
/// that wants to keep it duplicates it.
typedef struct {
  uint32_t width;
  uint32_t height;
  /// DRM FourCC. Always `XBGR8888`: RGBA in memory, opaque.
  uint32_t fourcc;
  uint64_t modifier;
  uint32_t offset;
  uint32_t stride;
  int fd;
} LavaVideoBuffer;

/// Called on the render thread, except `wakeup`, which mpv calls from
/// wherever it likes. Each may block — the render thread waits on them, and
/// that is the point: `present` returning is what says the buffer is free.
typedef struct {
  void *ctx;
  /// A new buffer: hand it to the renderer. The handle it is named by later,
  /// or 0 if refused — then the bridge gives up on dma-bufs and falls back to
  /// pixels for good. dma-buf mode only.
  uint32_t (*attach)(void *ctx, const LavaVideoBuffer *buffer);
  /// A buffer that is going away; the renderer may let go of it. dma-buf
  /// mode only.
  void (*detach)(void *ctx, uint32_t handle);
  /// A finished frame is in the buffer named `handle`. dma-buf mode only.
  void (*present)(void *ctx, uint32_t handle);
  /// A finished frame in memory, `height` rows `stride` bytes apart, four
  /// bytes a pixel in the order R, G, B, X. Valid until this returns. Pixel
  /// mode only.
  void (*present_pixels)(void *ctx, const void *pixels, uint32_t width,
                         uint32_t height, uint32_t stride);
  /// mpv has events to read: call `mpv_wait_event(…, 0)` until it says
  /// `MPV_EVENT_NONE`, on a thread of your choosing. From any thread.
  void (*wakeup)(void *ctx);
} LavaVideoCallbacks;

/// Where to render.
typedef struct {
  /// The renderer's `/dev/dri/renderD*`, or null for pixel mode.
  const char *render_node;
  /// The modifiers the renderer can import. Null/0 with `render_node` means
  /// linear only.
  const uint64_t *modifiers;
  size_t modifier_count;
} LavaVideoTarget;

/// Creates mpv and its render thread. `options` are `name=value` pairs set
/// before mpv initialises (`hwdec`, `vo`, … — whatever `mpv --name=value`
/// takes), `option_count` of them. Null on failure, with the reason in `error`
/// (which may itself be null).
///
/// If the dma-buf path was asked for and will not come up, this falls back to
/// pixels and says so on stderr rather than failing: a slow video is better
/// than none. `lava_video_uses_dmabuf` tells which it got.
LavaVideo *lava_video_create(LavaVideoTarget target,
                             LavaVideoCallbacks callbacks,
                             const char *const *options, size_t option_count,
                             char *error, size_t error_size);

/// Stops the render thread, detaches every buffer and destroys mpv.
void lava_video_destroy(LavaVideo *video);

/// The mpv instance, for commands and properties. Owned by the bridge.
struct mpv_handle *lava_video_mpv(LavaVideo *video);

int lava_video_uses_dmabuf(LavaVideo *video);

/// The size to render at, in pixels — the box the video is drawn in, so mpv
/// scales with its own filters and draws subtitles at screen resolution.
/// mpv letterboxes inside it. Cheap to call every frame: only a change does
/// anything, and a change redraws the current frame at the new size.
void lava_video_set_size(LavaVideo *video, uint32_t width, uint32_t height);

/// Draw the current frame again, for a buffer the renderer lost.
void lava_video_redraw(LavaVideo *video);

/// The app has presented a frame drawn from buffer `handle` (the one
/// `present` named). After a resize the buffers of the old size are kept
/// until this names one of the new — the app's last frame still draws them.
/// Cheap to call every frame.
void lava_video_shown(LavaVideo *video, uint32_t handle);

#ifdef __cplusplus
}
#endif
