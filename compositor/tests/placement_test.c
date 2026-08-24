// Who gets an application's remembered frame.
//
// Unlike the other tests here this one needs a compositor, because the
// answer is spread across the first configure, the placement and the
// close — see `placementHeld` in main.cpp. So it starts one per scenario
// on the headless backend, drives real xdg-shell toplevels at it, and
// reads back both what the compositor configured and what it wrote to
// the window-memory file.
//
// The scenarios are the two shapes that look identical to the compositor
// and must not be treated the same:
//
//   second    two toplevels sharing an app_id, both alive. The second is
//             Double Commander's copy-progress window: it has no parent
//             to mark it a dialog, and it must not open at the file
//             manager's size, nor overwrite the frame when it closes.
//   recreate  the same two, except the first is destroyed a moment after
//             the second maps. That is Qt replacing the window it just
//             mapped — one window, not two — and the frame must follow.
//   lateid    a toplevel that calls set_app_id only after it is mapped.
//             Ownership is decided at placement, when there is no name
//             yet, so without `claimPlacement` it would never record a
//             frame at all.
//
// The compositor binary is argv[1]; meson passes it. Exits 77 (skip) if
// no compositor can be started here.

#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "xdg-shell-client-protocol.h"

// ─── reporting ─────────────────────────────────────────────────────────────

static int failures;
static const char *scenario = "";

static void fail(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  fprintf(stderr, "%s: FAIL: ", scenario);
  vfprintf(stderr, fmt, ap);
  fprintf(stderr, "\n");
  va_end(ap);
  ++failures;
}

#define CHECK(cond, ...)                                                       \
  do {                                                                         \
    if (!(cond)) fail(__VA_ARGS__);                                            \
  } while (0)

static void msleep(int ms) {
  struct timespec t = {ms / 1000, (long)(ms % 1000) * 1000000L};
  nanosleep(&t, NULL);
}

// ─── the compositor under test ─────────────────────────────────────────────

struct session {
  char dir[64];       // private XDG_RUNTIME_DIR, also holds the log
  char windows[96];   // LAVA_WINDOWS path
  pid_t pid;
};

/// The frame every scenario starts from: a distinctive size, maximized, so
/// that a window which wrongly inherits it is obvious in the configure.
static const char *kSavedFrame = "[repapp]\n"
                                 "x = 111\n"
                                 "y = 222\n"
                                 "width = 900\n"
                                 "height = 600\n"
                                 "maximized = true\n\n";

static int write_file(const char *path, const char *text) {
  FILE *f = fopen(path, "w");
  if (f == NULL) return -1;
  if (text != NULL) fputs(text, f);
  fclose(f);
  return 0;
}

/// Start a compositor with a runtime directory of its own, so that neither
/// the developer's session nor another scenario is reachable by accident.
/// `saved` is the window-memory file to start from, or NULL for none.
static int session_start(struct session *s, const char *binary,
                         const char *saved) {
  snprintf(s->dir, sizeof(s->dir), "/tmp/lava-placement-XXXXXX");
  if (mkdtemp(s->dir) == NULL) return -1;
  chmod(s->dir, 0700);
  snprintf(s->windows, sizeof(s->windows), "%s/windows", s->dir);
  if (write_file(s->windows, saved) != 0) return -1;

  char log[96];
  snprintf(log, sizeof(log), "%s/compositor.log", s->dir);

  s->pid = fork();
  if (s->pid < 0) return -1;
  if (s->pid == 0) {
    setenv("XDG_RUNTIME_DIR", s->dir, 1);
    setenv("LAVA_WINDOWS", s->windows, 1);
    setenv("WLR_BACKENDS", "headless", 1);
    // Software rendering: this test is about bookkeeping, and requiring a
    // GPU would make it unrunnable wherever the rest of the suite runs.
    setenv("WLR_RENDERER", "pixman", 1);
    setenv("LAVA_NO_SHELL", "1", 1);
    unsetenv("WAYLAND_DISPLAY");
    unsetenv("DISPLAY");
    int fd = open(log, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd >= 0) {
      dup2(fd, STDOUT_FILENO);
      dup2(fd, STDERR_FILENO);
      close(fd);
    }
    execl(binary, binary, (char *)NULL);
    _exit(127);
  }

  char sock[96];
  snprintf(sock, sizeof(sock), "%s/wayland-0", s->dir);
  for (int i = 0; i < 200; ++i) {   // up to 10 s
    struct stat st;
    if (stat(sock, &st) == 0) return 0;
    int status;
    if (waitpid(s->pid, &status, WNOHANG) == s->pid) {
      s->pid = -1;
      return -1;                    // died before it listened
    }
    msleep(50);
  }
  return -1;
}

/// Stop it and wait: the window-memory file is flushed on the way out, and
/// reading it before the process is gone reads the previous contents.
static void session_stop(struct session *s) {
  if (s->pid > 0) {
    kill(s->pid, SIGTERM);
    int status;
    for (int i = 0; i < 100 && waitpid(s->pid, &status, WNOHANG) == 0; ++i) {
      msleep(50);
    }
    kill(s->pid, SIGKILL);
    waitpid(s->pid, &status, WNOHANG);
    s->pid = -1;
  }
}

static char *read_file(const char *path) {
  FILE *f = fopen(path, "r");
  if (f == NULL) return NULL;
  static char buf[8192];
  size_t n = fread(buf, 1, sizeof(buf) - 1, f);
  buf[n] = '\0';
  fclose(f);
  return buf;
}

/// Dump the compositor's own log; only worth reading when something failed.
static void session_report(struct session *s) {
  char log[96];
  snprintf(log, sizeof(log), "%s/compositor.log", s->dir);
  const char *text = read_file(log);
  if (text == NULL) return;
  fprintf(stderr, "--- %s compositor log ---\n%s\n", scenario, text);
}

static void session_cleanup(struct session *s) {
  char cmd[128];
  snprintf(cmd, sizeof(cmd), "rm -rf '%s'", s->dir);
  if (system(cmd) != 0) { /* a temp directory left behind is not a failure */ }
}

// ─── a minimal xdg-shell client ────────────────────────────────────────────

static struct wl_display *dpy;
static struct wl_compositor *comp;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;

struct win {
  const char *tag;
  struct wl_surface *surf;
  struct xdg_surface *xsurf;
  struct xdg_toplevel *top;
  int cw, ch;          // size of the last configure
  int maximized;       // state of the last configure
  int configures;
};

static void wm_ping(void *d, struct xdg_wm_base *b, uint32_t serial) {
  (void)d;
  xdg_wm_base_pong(b, serial);
}
static const struct xdg_wm_base_listener wm_listener = {.ping = wm_ping};

static void reg_global(void *d, struct wl_registry *r, uint32_t name,
                       const char *iface, uint32_t ver) {
  (void)d;
  (void)ver;
  if (strcmp(iface, "wl_compositor") == 0) {
    comp = wl_registry_bind(r, name, &wl_compositor_interface, 4);
  } else if (strcmp(iface, "wl_shm") == 0) {
    shm = wl_registry_bind(r, name, &wl_shm_interface, 1);
  } else if (strcmp(iface, "xdg_wm_base") == 0) {
    wm = wl_registry_bind(r, name, &xdg_wm_base_interface, 1);
    xdg_wm_base_add_listener(wm, &wm_listener, NULL);
  }
}
static void reg_remove(void *d, struct wl_registry *r, uint32_t n) {
  (void)d;
  (void)r;
  (void)n;
}
static const struct wl_registry_listener reg_listener = {reg_global,
                                                         reg_remove};

static struct wl_buffer *make_buffer(int w, int h) {
  int stride = w * 4;
  int size = stride * h;
  char name[] = "/lava-placement-test";
  int fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
  if (fd < 0) return NULL;
  shm_unlink(name);
  if (ftruncate(fd, size) < 0) {
    close(fd);
    return NULL;
  }
  void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  if (p != MAP_FAILED) {
    memset(p, 0x60, size);
    munmap(p, size);
  }
  struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
  struct wl_buffer *b = wl_shm_pool_create_buffer(pool, 0, w, h, stride,
                                                  WL_SHM_FORMAT_XRGB8888);
  wl_shm_pool_destroy(pool);
  close(fd);
  return b;
}

/// The natural size of a window nobody told what to be. Distinct from the
/// remembered frame so the two are never confused in a check.
#define OWN_W 400
#define OWN_H 300

static void xsurf_configure(void *data, struct xdg_surface *xs,
                            uint32_t serial) {
  struct win *w = data;
  xdg_surface_ack_configure(xs, serial);
  // 0x0 is the compositor saying "you decide", which is what a window that
  // does not own the frame must be told.
  int bw = w->cw > 0 ? w->cw : OWN_W;
  int bh = w->ch > 0 ? w->ch : OWN_H;
  struct wl_buffer *b = make_buffer(bw, bh);
  if (b == NULL) return;
  wl_surface_attach(w->surf, b, 0, 0);
  wl_surface_damage_buffer(w->surf, 0, 0, bw, bh);
  wl_surface_commit(w->surf);
}
static const struct xdg_surface_listener xsurf_listener = {
    .configure = xsurf_configure};

static void top_configure(void *data, struct xdg_toplevel *t, int32_t w,
                          int32_t h, struct wl_array *states) {
  (void)t;
  struct win *win = data;
  win->cw = w;
  win->ch = h;
  win->maximized = 0;
  uint32_t *state;
  wl_array_for_each(state, states) {
    if (*state == XDG_TOPLEVEL_STATE_MAXIMIZED) win->maximized = 1;
  }
  ++win->configures;
}
static void top_close(void *d, struct xdg_toplevel *t) {
  (void)d;
  (void)t;
}
static const struct xdg_toplevel_listener top_listener = {
    .configure = top_configure, .close = top_close};

/// Run the connection for `ms`, so the compositor's replies actually land.
static void pump(int ms) {
  struct timespec start, now;
  clock_gettime(CLOCK_MONOTONIC, &start);
  for (;;) {
    if (wl_display_roundtrip(dpy) < 0) return;
    clock_gettime(CLOCK_MONOTONIC, &now);
    long elapsed = (now.tv_sec - start.tv_sec) * 1000 +
                   (now.tv_nsec - start.tv_nsec) / 1000000;
    if (elapsed >= ms) return;
    msleep(5);
  }
}

static void open_win(struct win *w, const char *tag, const char *app_id) {
  memset(w, 0, sizeof(*w));
  w->tag = tag;
  w->surf = wl_compositor_create_surface(comp);
  w->xsurf = xdg_wm_base_get_xdg_surface(wm, w->surf);
  xdg_surface_add_listener(w->xsurf, &xsurf_listener, w);
  w->top = xdg_surface_get_toplevel(w->xsurf);
  xdg_toplevel_add_listener(w->top, &top_listener, w);
  if (app_id != NULL) xdg_toplevel_set_app_id(w->top, app_id);
  xdg_toplevel_set_title(w->top, tag);
  wl_surface_commit(w->surf);
}

static void close_win(struct win *w) {
  xdg_toplevel_destroy(w->top);
  xdg_surface_destroy(w->xsurf);
  wl_surface_destroy(w->surf);
}

static int connect_to(struct session *s) {
  char sock[96];
  snprintf(sock, sizeof(sock), "%s/wayland-0", s->dir);
  setenv("XDG_RUNTIME_DIR", s->dir, 1);
  setenv("WAYLAND_DISPLAY", "wayland-0", 1);
  comp = NULL;
  shm = NULL;
  wm = NULL;
  dpy = wl_display_connect(NULL);
  if (dpy == NULL) return -1;
  struct wl_registry *r = wl_display_get_registry(dpy);
  wl_registry_add_listener(r, &reg_listener, NULL);
  wl_display_roundtrip(dpy);
  wl_display_roundtrip(dpy);
  return (comp && shm && wm) ? 0 : -1;
}

static void disconnect(void) {
  if (dpy != NULL) {
    wl_display_roundtrip(dpy);
    wl_display_disconnect(dpy);
    dpy = NULL;
  }
}

// ─── scenarios ─────────────────────────────────────────────────────────────

/// Both windows alive: the second is a window of its own and keeps its own
/// size, and must not write the frame back either.
static void scenario_second(const char *binary) {
  scenario = "second";
  struct session s;
  if (session_start(&s, binary, kSavedFrame) != 0) {
    fail("compositor did not start");
    session_cleanup(&s);
    return;
  }
  if (connect_to(&s) != 0) {
    fail("could not connect");
    session_stop(&s);
    session_cleanup(&s);
    return;
  }

  struct win a, b;
  open_win(&a, "A", "repapp");
  pump(500);
  CHECK(a.maximized, "first window did not get the remembered maximize");
  CHECK(a.cw > OWN_W, "first window was not sized to the remembered frame "
                      "(got %dx%d)", a.cw, a.ch);

  open_win(&b, "B", "repapp");
  pump(1500);   // comfortably past kPlacementGrace (750 ms)
  CHECK(!b.maximized, "second window inherited the maximize");
  CHECK(b.cw == 0 && b.ch == 0,
        "second window was sized to the remembered frame (got %dx%d)", b.cw,
        b.ch);

  close_win(&b);
  pump(200);
  close_win(&a);
  pump(200);
  disconnect();
  session_stop(&s);

  const char *file = read_file(s.windows);
  CHECK(file != NULL && strstr(file, "width = 900") != NULL,
        "the second window overwrote the remembered frame:\n%s",
        file ? file : "(unreadable)");
  if (failures) session_report(&s);
  session_cleanup(&s);
}

/// The first window is destroyed just after the second maps: one window
/// being re-created by its toolkit, and the frame follows it.
static void scenario_recreate(const char *binary) {
  scenario = "recreate";
  struct session s;
  if (session_start(&s, binary, kSavedFrame) != 0) {
    fail("compositor did not start");
    session_cleanup(&s);
    return;
  }
  if (connect_to(&s) != 0) {
    fail("could not connect");
    session_stop(&s);
    session_cleanup(&s);
    return;
  }

  struct win a, b;
  open_win(&a, "A", "repapp");
  pump(500);
  open_win(&b, "B", "repapp");
  pump(60);           // well inside kPlacementGrace
  close_win(&a);
  pump(800);

  CHECK(b.maximized, "the replacement window did not inherit the maximize");
  CHECK(b.cw > OWN_W,
        "the replacement window did not inherit the frame (got %dx%d)", b.cw,
        b.ch);

  close_win(&b);
  pump(200);
  disconnect();
  session_stop(&s);
  if (failures) session_report(&s);
  session_cleanup(&s);
}

/// Named after it is mapped. Nothing is restored — there is no frame to
/// restore — but the window must still own the slot by the time it closes,
/// or it is never remembered at all.
static void scenario_late_app_id(const char *binary) {
  scenario = "lateid";
  struct session s;
  if (session_start(&s, binary, NULL) != 0) {
    fail("compositor did not start");
    session_cleanup(&s);
    return;
  }
  if (connect_to(&s) != 0) {
    fail("could not connect");
    session_stop(&s);
    session_cleanup(&s);
    return;
  }

  struct win a;
  open_win(&a, "A", NULL);   // no app_id at the first commit
  pump(500);
  xdg_toplevel_set_app_id(a.top, "repapp");
  wl_surface_commit(a.surf);
  pump(400);
  close_win(&a);
  pump(300);
  disconnect();
  session_stop(&s);

  const char *file = read_file(s.windows);
  CHECK(file != NULL && strstr(file, "[repapp]") != NULL,
        "a window that named itself late was never remembered:\n%s",
        file ? file : "(unreadable)");
  if (failures) session_report(&s);
  session_cleanup(&s);
}

// ─── main ──────────────────────────────────────────────────────────────────

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <compositor-binary>\n", argv[0]);
    return 2;
  }
  const char *binary = argv[1];
  if (access(binary, X_OK) != 0) {
    fprintf(stderr, "cannot execute %s: %s\n", binary, strerror(errno));
    return 77;
  }

  // One probe run first: where there is no headless backend to be had —
  // a build container without DRM or shm — this is a skip and not a
  // failure, and finding that out once is tidier than three times.
  struct session probe;
  if (session_start(&probe, binary, NULL) != 0) {
    fprintf(stderr, "no headless compositor available here; skipping\n");
    session_report(&probe);
    session_stop(&probe);
    session_cleanup(&probe);
    return 77;
  }
  session_stop(&probe);
  session_cleanup(&probe);

  scenario_second(binary);
  scenario_recreate(binary);
  scenario_late_app_id(binary);

  if (failures == 0) printf("window placement: ok\n");
  return failures == 0 ? 0 : 1;
}
