// See include/lava_video.h for what this is and why it is shaped this way.

#define _GNU_SOURCE
#include "lava_video.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include <gbm.h>

#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

// gbm.h spells the FourCCs, with the same values as drm_fourcc.h, which lives
// under libdrm's include directory and would need a pkg-config target of its
// own for two constants. The linear modifier is zero by definition.
#define DRM_FORMAT_ABGR8888 GBM_FORMAT_ABGR8888
#define DRM_FORMAT_XBGR8888 GBM_FORMAT_XBGR8888
#define DRM_FORMAT_MOD_LINEAR 0ull

// Three: one the renderer is copying out of, one mpv is drawing into, and
// one spare so a slow copy does not make mpv wait. The renderer's reply to
// `present` is the release, so two would do; the third costs one frame of
// memory and buys slack on a busy desktop.
#define BUFFER_COUNT 3

typedef void (*PFN_glGenTextures)(GLsizei, GLuint *);
typedef void (*PFN_glDeleteTextures)(GLsizei, const GLuint *);
typedef void (*PFN_glBindTexture)(GLenum, GLuint);
typedef void (*PFN_glTexParameteri)(GLenum, GLenum, GLint);
typedef void (*PFN_glGenFramebuffers)(GLsizei, GLuint *);
typedef void (*PFN_glDeleteFramebuffers)(GLsizei, const GLuint *);
typedef void (*PFN_glBindFramebuffer)(GLenum, GLuint);
typedef void (*PFN_glFramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint,
                                           GLint);
typedef GLenum (*PFN_glCheckFramebufferStatus)(GLenum);
typedef void (*PFN_glFinish)(void);
typedef void (*PFN_glEGLImageTargetTexture2DOES)(GLenum, void *);

typedef struct {
  struct gbm_bo *bo;
  int fd;
  EGLImageKHR image;
  GLuint texture;
  GLuint fbo;
  uint32_t handle;  // the renderer's name for it; 0 = not attached
} Buffer;

struct LavaVideo {
  mpv_handle *mpv;
  mpv_render_context *render;
  LavaVideoCallbacks cb;

  pthread_t thread;
  bool thread_started;
  pthread_mutex_t lock;
  pthread_cond_t wake;
  // Under `lock`.
  bool update_pending;
  bool redraw_pending;
  bool quit;
  uint32_t want_width, want_height;

  // Set once by the render thread before `ready` is signalled.
  pthread_mutex_t ready_lock;
  pthread_cond_t ready_cond;
  bool ready;
  bool failed;
  char error[256];

  // What was asked for, and what came up.
  char *render_node;
  uint64_t *modifiers;
  size_t modifier_count;
  bool dmabuf;

  // Render thread only from here down.
  int drm_fd;
  struct gbm_device *gbm;
  EGLDisplay display;
  EGLContext context;
  PFNEGLCREATEIMAGEKHRPROC eglCreateImageKHR;
  PFNEGLDESTROYIMAGEKHRPROC eglDestroyImageKHR;
  PFNEGLQUERYDMABUFMODIFIERSEXTPROC eglQueryDmaBufModifiersEXT;
  struct {
    PFN_glGenTextures GenTextures;
    PFN_glDeleteTextures DeleteTextures;
    PFN_glBindTexture BindTexture;
    PFN_glTexParameteri TexParameteri;
    PFN_glGenFramebuffers GenFramebuffers;
    PFN_glDeleteFramebuffers DeleteFramebuffers;
    PFN_glBindFramebuffer BindFramebuffer;
    PFN_glFramebufferTexture2D FramebufferTexture2D;
    PFN_glCheckFramebufferStatus CheckFramebufferStatus;
    PFN_glFinish Finish;
    PFN_glEGLImageTargetTexture2DOES EGLImageTargetTexture2DOES;
  } gl;
  Buffer buffers[BUFFER_COUNT];
  uint32_t buffer_width, buffer_height;
  int next_buffer;

  // Pixel mode.
  void *pixels;
  size_t pixel_stride;
  uint32_t pixel_width, pixel_height;
};

static void say(const char *format, ...) {
  va_list args;
  va_start(args, format);
  fputs("LavaVideo: ", stderr);
  vfprintf(stderr, format, args);
  fputc('\n', stderr);
  va_end(args);
}

static void set_error(LavaVideo *video, const char *format, ...) {
  va_list args;
  va_start(args, format);
  vsnprintf(video->error, sizeof video->error, format, args);
  va_end(args);
}

// ─── EGL ─────────────────────────────────────────────────────────────────────

static bool has_extension(const char *list, const char *name) {
  if (list == NULL) return false;
  const size_t length = strlen(name);
  for (const char *at = list; (at = strstr(at, name)) != NULL; at += length) {
    const bool starts = at == list || at[-1] == ' ';
    const bool ends = at[length] == ' ' || at[length] == '\0';
    if (starts && ends) return true;
  }
  return false;
}

/// The EGL display on the renderer's GPU.
///
/// By EGLDevice first, matched on the render node: it needs no GBM in EGL,
/// which is the part of this that differs most between drivers. GBM's
/// platform second — Mesa always has it, NVIDIA since 495.
static EGLDisplay open_display(LavaVideo *video) {
  const char *client = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
  PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress(
          "eglGetPlatformDisplayEXT");
  if (getPlatformDisplay == NULL) return EGL_NO_DISPLAY;

  if (has_extension(client, "EGL_EXT_device_enumeration") &&
      has_extension(client, "EGL_EXT_platform_device")) {
    PFNEGLQUERYDEVICESEXTPROC queryDevices =
        (PFNEGLQUERYDEVICESEXTPROC)eglGetProcAddress("eglQueryDevicesEXT");
    PFNEGLQUERYDEVICESTRINGEXTPROC queryDeviceString =
        (PFNEGLQUERYDEVICESTRINGEXTPROC)eglGetProcAddress(
            "eglQueryDeviceStringEXT");
    EGLDeviceEXT devices[16];
    EGLint count = 0;
    if (queryDevices && queryDeviceString &&
        queryDevices(16, devices, &count)) {
      for (EGLint i = 0; i < count; ++i) {
        const char *extensions =
            queryDeviceString(devices[i], EGL_EXTENSIONS);
        if (!has_extension(extensions, "EGL_EXT_device_drm_render_node")) {
          continue;
        }
        const char *node =
            queryDeviceString(devices[i], EGL_DRM_RENDER_NODE_FILE_EXT);
        if (node == NULL || strcmp(node, video->render_node) != 0) continue;
        EGLDisplay display =
            getPlatformDisplay(EGL_PLATFORM_DEVICE_EXT, devices[i], NULL);
        if (display != EGL_NO_DISPLAY) return display;
      }
    }
  }
  if (has_extension(client, "EGL_KHR_platform_gbm") ||
      has_extension(client, "EGL_MESA_platform_gbm")) {
    return getPlatformDisplay(EGL_PLATFORM_GBM_KHR, video->gbm, NULL);
  }
  return EGL_NO_DISPLAY;
}

static bool load_gl(LavaVideo *video) {
#define LOAD(field, name)                                             \
  video->gl.field = (__typeof__(video->gl.field))eglGetProcAddress(name); \
  if (video->gl.field == NULL) {                                      \
    set_error(video, "no %s", name);                                  \
    return false;                                                     \
  }
  LOAD(GenTextures, "glGenTextures");
  LOAD(DeleteTextures, "glDeleteTextures");
  LOAD(BindTexture, "glBindTexture");
  LOAD(TexParameteri, "glTexParameteri");
  LOAD(GenFramebuffers, "glGenFramebuffers");
  LOAD(DeleteFramebuffers, "glDeleteFramebuffers");
  LOAD(BindFramebuffer, "glBindFramebuffer");
  LOAD(FramebufferTexture2D, "glFramebufferTexture2D");
  LOAD(CheckFramebufferStatus, "glCheckFramebufferStatus");
  LOAD(Finish, "glFinish");
  LOAD(EGLImageTargetTexture2DOES, "glEGLImageTargetTexture2DOES");
#undef LOAD
  return true;
}

/// A GL context with no surface, current on this thread, on the renderer's
/// GPU. False with `error` set if any of it is missing.
static bool bring_up_egl(LavaVideo *video) {
  video->drm_fd = open(video->render_node, O_RDWR | O_CLOEXEC);
  if (video->drm_fd < 0) {
    set_error(video, "open %s: %s", video->render_node, strerror(errno));
    return false;
  }
  video->gbm = gbm_create_device(video->drm_fd);
  if (video->gbm == NULL) {
    set_error(video, "gbm_create_device on %s failed", video->render_node);
    return false;
  }
  video->display = open_display(video);
  if (video->display == EGL_NO_DISPLAY) {
    set_error(video, "no EGL display on %s", video->render_node);
    return false;
  }
  if (!eglInitialize(video->display, NULL, NULL)) {
    set_error(video, "eglInitialize failed (0x%x)", eglGetError());
    video->display = EGL_NO_DISPLAY;
    return false;
  }
  const char *extensions = eglQueryString(video->display, EGL_EXTENSIONS);
  const char *needed[] = {
      "EGL_KHR_surfaceless_context",
      "EGL_KHR_no_config_context",
      "EGL_EXT_image_dma_buf_import",
      "EGL_EXT_image_dma_buf_import_modifiers",
  };
  for (size_t i = 0; i < sizeof needed / sizeof needed[0]; ++i) {
    if (!has_extension(extensions, needed[i])) {
      set_error(video, "EGL lacks %s", needed[i]);
      return false;
    }
  }
  video->eglCreateImageKHR =
      (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
  video->eglDestroyImageKHR =
      (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
  video->eglQueryDmaBufModifiersEXT =
      (PFNEGLQUERYDMABUFMODIFIERSEXTPROC)eglGetProcAddress(
          "eglQueryDmaBufModifiersEXT");
  if (!video->eglCreateImageKHR || !video->eglDestroyImageKHR) {
    set_error(video, "no eglCreateImageKHR");
    return false;
  }

  // Desktop GL, as mpv prefers; no version asked, so a compatibility context
  // at whatever the driver's best is — mpv checks for what it needs itself.
  if (!eglBindAPI(EGL_OPENGL_API)) {
    set_error(video, "eglBindAPI(OpenGL) failed");
    return false;
  }
  video->context =
      eglCreateContext(video->display, EGL_NO_CONFIG_KHR, EGL_NO_CONTEXT, NULL);
  if (video->context == EGL_NO_CONTEXT) {
    set_error(video, "eglCreateContext failed (0x%x)", eglGetError());
    return false;
  }
  if (!eglMakeCurrent(video->display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                      video->context)) {
    set_error(video, "eglMakeCurrent failed (0x%x)", eglGetError());
    return false;
  }
  return load_gl(video);
}

static void tear_down_egl(LavaVideo *video) {
  if (video->display != EGL_NO_DISPLAY) {
    eglMakeCurrent(video->display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                   EGL_NO_CONTEXT);
    if (video->context != EGL_NO_CONTEXT) {
      eglDestroyContext(video->display, video->context);
    }
    eglTerminate(video->display);
  }
  video->display = EGL_NO_DISPLAY;
  video->context = EGL_NO_CONTEXT;
  if (video->gbm) gbm_device_destroy(video->gbm);
  video->gbm = NULL;
  if (video->drm_fd >= 0) close(video->drm_fd);
  video->drm_fd = -1;
}

// ─── Buffers ─────────────────────────────────────────────────────────────────

static void free_buffer(LavaVideo *video, Buffer *buffer) {
  if (buffer->handle != 0 && video->cb.detach) {
    video->cb.detach(video->cb.ctx, buffer->handle);
  }
  if (buffer->fbo) video->gl.DeleteFramebuffers(1, &buffer->fbo);
  if (buffer->texture) video->gl.DeleteTextures(1, &buffer->texture);
  if (buffer->image != EGL_NO_IMAGE_KHR) {
    video->eglDestroyImageKHR(video->display, buffer->image);
  }
  if (buffer->fd >= 0) close(buffer->fd);
  if (buffer->bo) gbm_bo_destroy(buffer->bo);
  memset(buffer, 0, sizeof *buffer);
  buffer->fd = -1;
  buffer->image = EGL_NO_IMAGE_KHR;
}

static void free_buffers(LavaVideo *video) {
  for (int i = 0; i < BUFFER_COUNT; ++i) free_buffer(video, &video->buffers[i]);
  video->buffer_width = video->buffer_height = 0;
}

/// The modifiers both sides take: the renderer can import it, and EGL can
/// render to it. Linear is always among them when the renderer lists it.
static size_t usable_modifiers(LavaVideo *video, uint64_t *out, size_t room) {
  uint64_t renderable[128];
  EGLBoolean external[128];
  EGLint count = 0;
  bool asked = video->eglQueryDmaBufModifiersEXT != NULL &&
               video->eglQueryDmaBufModifiersEXT(
                   video->display, DRM_FORMAT_ABGR8888, 128,
                   (EGLuint64KHR *)renderable, external, &count);
  size_t used = 0;
  for (size_t i = 0; i < video->modifier_count && used < room; ++i) {
    const uint64_t modifier = video->modifiers[i];
    bool ok = modifier == DRM_FORMAT_MOD_LINEAR;
    for (EGLint j = 0; asked && j < count && !ok; ++j) {
      ok = renderable[j] == modifier && !external[j];
    }
    if (ok) out[used++] = modifier;
  }
  return used;
}

static bool make_buffer(LavaVideo *video, Buffer *buffer, uint32_t width,
                        uint32_t height) {
  memset(buffer, 0, sizeof *buffer);
  buffer->fd = -1;
  buffer->image = EGL_NO_IMAGE_KHR;

  uint64_t modifiers[64];
  const size_t count = usable_modifiers(video, modifiers, 64);
  if (count > 0) {
    buffer->bo = gbm_bo_create_with_modifiers2(
        video->gbm, width, height, GBM_FORMAT_ABGR8888, modifiers,
        (unsigned)count, GBM_BO_USE_RENDERING);
  }
  if (buffer->bo == NULL) {
    // Some drivers will only do linear by flag, not by modifier.
    buffer->bo = gbm_bo_create(video->gbm, width, height, GBM_FORMAT_ABGR8888,
                               GBM_BO_USE_RENDERING | GBM_BO_USE_LINEAR);
  }
  if (buffer->bo == NULL) {
    set_error(video, "gbm could not allocate %ux%u", width, height);
    return false;
  }
  if (gbm_bo_get_plane_count(buffer->bo) != 1) {
    set_error(video, "gbm chose a layout with %d planes",
              gbm_bo_get_plane_count(buffer->bo));
    return false;
  }
  buffer->fd = gbm_bo_get_fd(buffer->bo);
  if (buffer->fd < 0) {
    set_error(video, "gbm_bo_get_fd failed");
    return false;
  }
  const uint64_t modifier = gbm_bo_get_modifier(buffer->bo);
  const uint32_t stride = gbm_bo_get_stride_for_plane(buffer->bo, 0);
  const uint32_t offset = gbm_bo_get_offset(buffer->bo, 0);

  EGLint attributes[] = {
      EGL_WIDTH, (EGLint)width,
      EGL_HEIGHT, (EGLint)height,
      EGL_LINUX_DRM_FOURCC_EXT, DRM_FORMAT_ABGR8888,
      EGL_DMA_BUF_PLANE0_FD_EXT, buffer->fd,
      EGL_DMA_BUF_PLANE0_OFFSET_EXT, (EGLint)offset,
      EGL_DMA_BUF_PLANE0_PITCH_EXT, (EGLint)stride,
      EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, (EGLint)(modifier & 0xffffffffu),
      EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, (EGLint)(modifier >> 32),
      EGL_NONE,
  };
  buffer->image = video->eglCreateImageKHR(
      video->display, EGL_NO_CONTEXT, EGL_LINUX_DMA_BUF_EXT, NULL, attributes);
  if (buffer->image == EGL_NO_IMAGE_KHR) {
    set_error(video, "eglCreateImageKHR failed (0x%x)", eglGetError());
    return false;
  }
  video->gl.GenTextures(1, &buffer->texture);
  video->gl.BindTexture(GL_TEXTURE_2D, buffer->texture);
  video->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  video->gl.TexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  video->gl.EGLImageTargetTexture2DOES(GL_TEXTURE_2D, buffer->image);
  video->gl.BindTexture(GL_TEXTURE_2D, 0);
  video->gl.GenFramebuffers(1, &buffer->fbo);
  video->gl.BindFramebuffer(GL_FRAMEBUFFER, buffer->fbo);
  video->gl.FramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                 GL_TEXTURE_2D, buffer->texture, 0);
  const GLenum status = video->gl.CheckFramebufferStatus(GL_FRAMEBUFFER);
  video->gl.BindFramebuffer(GL_FRAMEBUFFER, 0);
  if (status != GL_FRAMEBUFFER_COMPLETE) {
    set_error(video, "framebuffer incomplete (0x%x)", status);
    return false;
  }

  // Told as XBGR: the same bytes, but opaque. mpv's alpha is not coverage,
  // and a renderer that believed it would blend the video with the window.
  const LavaVideoBuffer description = {
      .width = width,
      .height = height,
      .fourcc = DRM_FORMAT_XBGR8888,
      .modifier = modifier,
      .offset = offset,
      .stride = stride,
      .fd = buffer->fd,
  };
  buffer->handle = video->cb.attach(video->cb.ctx, &description);
  if (buffer->handle == 0) {
    set_error(video, "the renderer refused a %ux%u buffer (modifier 0x%llx)",
              width, height, (unsigned long long)modifier);
    return false;
  }
  return true;
}

static bool make_buffers(LavaVideo *video, uint32_t width, uint32_t height) {
  free_buffers(video);
  for (int i = 0; i < BUFFER_COUNT; ++i) {
    if (!make_buffer(video, &video->buffers[i], width, height)) {
      free_buffers(video);
      return false;
    }
  }
  video->buffer_width = width;
  video->buffer_height = height;
  video->next_buffer = 0;
  return true;
}

// ─── mpv ─────────────────────────────────────────────────────────────────────

static void *get_proc_address(void *ctx, const char *name) {
  (void)ctx;
  return (void *)eglGetProcAddress(name);
}

static void on_render_update(void *ctx) {
  LavaVideo *video = ctx;
  pthread_mutex_lock(&video->lock);
  video->update_pending = true;
  pthread_cond_signal(&video->wake);
  pthread_mutex_unlock(&video->lock);
}

static void on_mpv_wakeup(void *ctx) {
  LavaVideo *video = ctx;
  if (video->cb.wakeup) video->cb.wakeup(video->cb.ctx);
}

static bool create_gl_render(LavaVideo *video) {
  mpv_opengl_init_params gl_init = {
      .get_proc_address = get_proc_address,
  };
  // The render node, so mpv's VA-API interop decodes on the GPU this draws
  // on rather than opening whichever one it finds first.
  mpv_opengl_drm_params_v2 drm = {
      .fd = -1,
      .crtc_id = -1,
      .connector_id = -1,
      .atomic_request_ptr = NULL,
      .render_fd = video->drm_fd,
  };
  int advanced = 0;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_OPENGL},
      {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
      {MPV_RENDER_PARAM_DRM_DISPLAY_V2, &drm},
      {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
      {MPV_RENDER_PARAM_INVALID, NULL},
  };
  const int status = mpv_render_context_create(&video->render, video->mpv,
                                               params);
  if (status < 0) {
    set_error(video, "mpv OpenGL renderer: %s", mpv_error_string(status));
    video->render = NULL;
    return false;
  }
  return true;
}

static bool create_sw_render(LavaVideo *video) {
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_API_TYPE, MPV_RENDER_API_TYPE_SW},
      {MPV_RENDER_PARAM_INVALID, NULL},
  };
  const int status = mpv_render_context_create(&video->render, video->mpv,
                                               params);
  if (status < 0) {
    set_error(video, "mpv software renderer: %s", mpv_error_string(status));
    video->render = NULL;
    return false;
  }
  return true;
}

// ─── The render thread ───────────────────────────────────────────────────────

/// Gives up on dma-bufs for the life of this video: GL renderer, buffers and
/// EGL go, and mpv's software renderer takes over. mpv allows a render
/// context to be replaced; the player does not notice beyond the frame rate.
static bool fall_back_to_pixels(LavaVideo *video) {
  say("dma-buf path failed (%s); rendering in software", video->error);
  mpv_render_context_set_update_callback(video->render, NULL, NULL);
  mpv_render_context_free(video->render);
  video->render = NULL;
  free_buffers(video);
  tear_down_egl(video);
  video->dmabuf = false;
  if (video->cb.present_pixels == NULL || !create_sw_render(video)) {
    return false;
  }
  mpv_render_context_set_update_callback(video->render, on_render_update,
                                         video);
  return true;
}

/// False when the frame could not be drawn and the caller should try pixels.
static bool render_dmabuf(LavaVideo *video, uint32_t width, uint32_t height) {
  if (width != video->buffer_width || height != video->buffer_height) {
    if (!make_buffers(video, width, height)) return false;
  }
  Buffer *buffer = &video->buffers[video->next_buffer];
  video->next_buffer = (video->next_buffer + 1) % BUFFER_COUNT;

  mpv_opengl_fbo fbo = {
      .fbo = (int)buffer->fbo,
      .w = (int)width,
      .h = (int)height,
      .internal_format = 0,
  };
  // Not flipped: an FBO's first row is the texture's first row is the
  // buffer's first row, which is the top as the renderer reads it. Flipping
  // is for GL's default framebuffer, which this is not.
  int flip = 0;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
      {MPV_RENDER_PARAM_FLIP_Y, &flip},
      {MPV_RENDER_PARAM_INVALID, NULL},
  };
  mpv_render_context_render(video->render, params);
  // The renderer is told there is no acquire fence — see `ShowVideoBuffer`
  // in the IDL — so the frame has to be finished before it is named. Waiting
  // here costs this thread and nobody else.
  video->gl.Finish();
  video->cb.present(video->cb.ctx, buffer->handle);
  mpv_render_context_report_swap(video->render);
  return true;
}

static void render_pixels(LavaVideo *video, uint32_t width, uint32_t height) {
  if (width != video->pixel_width || height != video->pixel_height) {
    free(video->pixels);
    // 64-byte rows and a 64-byte base, as mpv's header asks for its fast path.
    video->pixel_stride = ((size_t)width * 4 + 63) & ~(size_t)63;
    if (posix_memalign(&video->pixels, 64, video->pixel_stride * height) != 0) {
      video->pixels = NULL;
      video->pixel_width = video->pixel_height = 0;
      return;
    }
    video->pixel_width = width;
    video->pixel_height = height;
  }
  int size[2] = {(int)width, (int)height};
  size_t stride = video->pixel_stride;
  char format[] = "rgb0";
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_SW_SIZE, size},
      {MPV_RENDER_PARAM_SW_FORMAT, format},
      {MPV_RENDER_PARAM_SW_STRIDE, &stride},
      {MPV_RENDER_PARAM_SW_POINTER, video->pixels},
      {MPV_RENDER_PARAM_INVALID, NULL},
  };
  if (mpv_render_context_render(video->render, params) < 0) return;
  video->cb.present_pixels(video->cb.ctx, video->pixels, width, height,
                           (uint32_t)stride);
  mpv_render_context_report_swap(video->render);
}

static void signal_ready(LavaVideo *video, bool failed) {
  pthread_mutex_lock(&video->ready_lock);
  video->ready = true;
  video->failed = failed;
  pthread_cond_signal(&video->ready_cond);
  pthread_mutex_unlock(&video->ready_lock);
}

static void *render_main(void *arg) {
  LavaVideo *video = arg;

  // Everything GL is made on this thread and used only here: mpv requires
  // its render calls on the thread that created the render context, and the
  // context is current nowhere else.
  if (video->dmabuf) {
    if (!bring_up_egl(video) || !create_gl_render(video)) {
      say("no dma-buf path (%s); rendering in software", video->error);
      tear_down_egl(video);
      video->dmabuf = false;
    }
  }
  if (!video->dmabuf && !create_sw_render(video)) {
    signal_ready(video, true);
    return NULL;
  }
  mpv_render_context_set_update_callback(video->render, on_render_update,
                                         video);
  signal_ready(video, false);

  for (;;) {
    pthread_mutex_lock(&video->lock);
    while (!video->quit && !video->update_pending && !video->redraw_pending) {
      pthread_cond_wait(&video->wake, &video->lock);
    }
    if (video->quit) {
      pthread_mutex_unlock(&video->lock);
      break;
    }
    const bool update = video->update_pending;
    bool draw = video->redraw_pending;
    video->update_pending = false;
    video->redraw_pending = false;
    const uint32_t width = video->want_width;
    const uint32_t height = video->want_height;
    pthread_mutex_unlock(&video->lock);

    if (update) {
      const uint64_t flags = mpv_render_context_update(video->render);
      draw = draw || (flags & MPV_RENDER_UPDATE_FRAME);
    }
    if (!draw || width == 0 || height == 0) continue;

    if (video->dmabuf && !render_dmabuf(video, width, height)) {
      if (!fall_back_to_pixels(video)) {
        say("no renderer left: %s", video->error);
        break;
      }
    }
    if (!video->dmabuf && video->render) render_pixels(video, width, height);
  }

  // Before EGL goes: mpv's GL objects live in this context.
  if (video->render) mpv_render_context_free(video->render);
  video->render = NULL;
  if (video->dmabuf) {
    free_buffers(video);
    tear_down_egl(video);
  }
  free(video->pixels);
  video->pixels = NULL;
  return NULL;
}

// ─── Public ──────────────────────────────────────────────────────────────────

LavaVideo *lava_video_create(LavaVideoTarget target,
                             LavaVideoCallbacks callbacks,
                             const char *const *options, size_t option_count,
                             char *error, size_t error_size) {
  LavaVideo *video = calloc(1, sizeof *video);
  if (video == NULL) return NULL;
  video->cb = callbacks;
  video->drm_fd = -1;
  video->display = EGL_NO_DISPLAY;
  video->context = EGL_NO_CONTEXT;
  for (int i = 0; i < BUFFER_COUNT; ++i) {
    video->buffers[i].fd = -1;
    video->buffers[i].image = EGL_NO_IMAGE_KHR;
  }
  pthread_mutex_init(&video->lock, NULL);
  pthread_cond_init(&video->wake, NULL);
  pthread_mutex_init(&video->ready_lock, NULL);
  pthread_cond_init(&video->ready_cond, NULL);

  video->dmabuf = target.render_node != NULL && target.render_node[0] != '\0' &&
                  callbacks.attach && callbacks.present;
  if (video->dmabuf) {
    video->render_node = strdup(target.render_node);
    if (target.modifier_count > 0) {
      video->modifiers = calloc(target.modifier_count, sizeof(uint64_t));
      memcpy(video->modifiers, target.modifiers,
             target.modifier_count * sizeof(uint64_t));
      video->modifier_count = target.modifier_count;
    } else {
      static const uint64_t linear = DRM_FORMAT_MOD_LINEAR;
      video->modifiers = calloc(1, sizeof(uint64_t));
      video->modifiers[0] = linear;
      video->modifier_count = 1;
    }
  }

  video->mpv = mpv_create();
  if (video->mpv == NULL) {
    if (error) snprintf(error, error_size, "mpv_create failed");
    lava_video_destroy(video);
    return NULL;
  }
  // The render API, not a window of mpv's own; and mpv's own keys and
  // on-screen controller off, since the app draws its own.
  mpv_set_option_string(video->mpv, "vo", "libmpv");
  mpv_set_option_string(video->mpv, "input-default-bindings", "no");
  mpv_set_option_string(video->mpv, "input-vo-keyboard", "no");
  mpv_set_option_string(video->mpv, "osc", "no");
  mpv_set_option_string(video->mpv, "keep-open", "yes");
  mpv_set_option_string(video->mpv, "idle", "yes");
  mpv_set_option_string(video->mpv, "hwdec", "auto-safe");
  for (size_t i = 0; i < option_count; ++i) {
    const char *pair = options[i];
    const char *equals = strchr(pair, '=');
    if (equals == NULL) continue;
    char name[128];
    const size_t length = (size_t)(equals - pair);
    if (length == 0 || length >= sizeof name) continue;
    memcpy(name, pair, length);
    name[length] = '\0';
    if (mpv_set_option_string(video->mpv, name, equals + 1) < 0) {
      say("option %s refused", pair);
    }
  }
  const int status = mpv_initialize(video->mpv);
  if (status < 0) {
    if (error) {
      snprintf(error, error_size, "mpv_initialize: %s",
               mpv_error_string(status));
    }
    lava_video_destroy(video);
    return NULL;
  }

  if (pthread_create(&video->thread, NULL, render_main, video) != 0) {
    if (error) snprintf(error, error_size, "no render thread");
    lava_video_destroy(video);
    return NULL;
  }
  video->thread_started = true;
  pthread_setname_np(video->thread, "lava-video");

  pthread_mutex_lock(&video->ready_lock);
  while (!video->ready) pthread_cond_wait(&video->ready_cond, &video->ready_lock);
  const bool failed = video->failed;
  pthread_mutex_unlock(&video->ready_lock);
  if (failed) {
    if (error) snprintf(error, error_size, "%s", video->error);
    lava_video_destroy(video);
    return NULL;
  }
  // Last, so the first event cannot arrive before the caller has the handle.
  mpv_set_wakeup_callback(video->mpv, on_mpv_wakeup, video);
  return video;
}

void lava_video_destroy(LavaVideo *video) {
  if (video == NULL) return;
  if (video->mpv) mpv_set_wakeup_callback(video->mpv, NULL, NULL);
  if (video->thread_started) {
    pthread_mutex_lock(&video->lock);
    video->quit = true;
    pthread_cond_signal(&video->wake);
    pthread_mutex_unlock(&video->lock);
    pthread_join(video->thread, NULL);
  }
  // After the render context, which mpv requires to go first.
  if (video->mpv) mpv_terminate_destroy(video->mpv);
  free(video->render_node);
  free(video->modifiers);
  pthread_mutex_destroy(&video->lock);
  pthread_cond_destroy(&video->wake);
  pthread_mutex_destroy(&video->ready_lock);
  pthread_cond_destroy(&video->ready_cond);
  free(video);
}

struct mpv_handle *lava_video_mpv(LavaVideo *video) { return video->mpv; }

int lava_video_uses_dmabuf(LavaVideo *video) { return video->dmabuf ? 1 : 0; }

void lava_video_set_size(LavaVideo *video, uint32_t width, uint32_t height) {
  pthread_mutex_lock(&video->lock);
  if (width != video->want_width || height != video->want_height) {
    video->want_width = width;
    video->want_height = height;
    video->redraw_pending = true;
    pthread_cond_signal(&video->wake);
  }
  pthread_mutex_unlock(&video->lock);
}

void lava_video_redraw(LavaVideo *video) {
  pthread_mutex_lock(&video->lock);
  video->redraw_pending = true;
  pthread_cond_signal(&video->wake);
  pthread_mutex_unlock(&video->lock);
}
