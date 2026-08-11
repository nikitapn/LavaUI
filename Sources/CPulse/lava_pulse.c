#include "lava_pulse.h"

#include <math.h>
#include <pulse/pulseaudio.h>
#include <pulse/thread-mainloop.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct LavaPulse {
  pa_threaded_mainloop *loop;
  pa_context *ctx;
  LavaPulseUpdateFn cb;
  void *user;

  uint32_t sink_index;
  char default_sink[256];
  char sink_desc[256];
  pa_cvolume volume;
  int muted;
  int ready;
};

static void publish(LavaPulse *p)
{
  if (p->cb == NULL) return;
  float v = 0.f;
  if (p->volume.channels > 0) {
    const pa_volume_t avg = pa_cvolume_avg(&p->volume);
    v = (float)avg / (float)PA_VOLUME_NORM;
    if (v < 0.f) v = 0.f;
    if (v > 1.5f) v = 1.5f; // allow soft boost up to ~150%
  }
  const char *name =
      p->sink_desc[0] != '\0' ? p->sink_desc : p->default_sink;
  p->cb(p->user, v, p->muted, name, p->ready);
}

static void sink_info_cb(pa_context *c, const pa_sink_info *i, int eol,
                         void *userdata)
{
  (void)c;
  LavaPulse *p = userdata;
  if (eol < 0 || i == NULL) return;
  if (p->default_sink[0] != '\0' &&
      strcmp(i->name, p->default_sink) != 0) {
    return;
  }
  p->sink_index = i->index;
  p->volume = i->volume;
  p->muted = i->mute ? 1 : 0;
  if (i->description && i->description[0]) {
    snprintf(p->sink_desc, sizeof p->sink_desc, "%s", i->description);
  } else if (i->name) {
    snprintf(p->sink_desc, sizeof p->sink_desc, "%s", i->name);
  }
  publish(p);
}

static void refresh_sink(LavaPulse *p)
{
  if (p->ctx == NULL || !p->ready) return;
  if (p->default_sink[0] != '\0') {
    pa_operation *op = pa_context_get_sink_info_by_name(
        p->ctx, p->default_sink, sink_info_cb, p);
    if (op) pa_operation_unref(op);
  } else {
    pa_operation *op =
        pa_context_get_sink_info_by_index(p->ctx, p->sink_index, sink_info_cb, p);
    if (op) pa_operation_unref(op);
  }
}

static void server_info_cb(pa_context *c, const pa_server_info *i, void *userdata)
{
  (void)c;
  LavaPulse *p = userdata;
  if (i == NULL || i->default_sink_name == NULL) return;
  snprintf(p->default_sink, sizeof p->default_sink, "%s", i->default_sink_name);
  refresh_sink(p);
}

static void refresh_server(LavaPulse *p)
{
  if (p->ctx == NULL || !p->ready) return;
  pa_operation *op = pa_context_get_server_info(p->ctx, server_info_cb, p);
  if (op) pa_operation_unref(op);
}

static void subscribe_cb(pa_context *c, pa_subscription_event_type_t t,
                         uint32_t idx, void *userdata)
{
  (void)c;
  (void)idx;
  LavaPulse *p = userdata;
  const pa_subscription_event_type_t facility =
      t & PA_SUBSCRIPTION_EVENT_FACILITY_MASK;
  if (facility == PA_SUBSCRIPTION_EVENT_SERVER) {
    refresh_server(p);
  } else if (facility == PA_SUBSCRIPTION_EVENT_SINK) {
    refresh_sink(p);
  }
}

static void context_state_cb(pa_context *c, void *userdata)
{
  LavaPulse *p = userdata;
  switch (pa_context_get_state(c)) {
  case PA_CONTEXT_READY:
    p->ready = 1;
    pa_context_set_subscribe_callback(c, subscribe_cb, p);
    {
      pa_operation *op = pa_context_subscribe(
          c,
          (pa_subscription_mask_t)(PA_SUBSCRIPTION_MASK_SINK |
                                   PA_SUBSCRIPTION_MASK_SERVER),
          NULL, NULL);
      if (op) pa_operation_unref(op);
    }
    refresh_server(p);
    publish(p);
    break;
  case PA_CONTEXT_FAILED:
  case PA_CONTEXT_TERMINATED:
    p->ready = 0;
    publish(p);
    break;
  default:
    break;
  }
}

LavaPulse *lava_pulse_create(LavaPulseUpdateFn cb, void *user)
{
  LavaPulse *p = calloc(1, sizeof *p);
  if (p == NULL) return NULL;
  p->cb = cb;
  p->user = user;
  p->sink_index = PA_INVALID_INDEX;
  pa_cvolume_init(&p->volume);

  p->loop = pa_threaded_mainloop_new();
  if (p->loop == NULL) {
    free(p);
    return NULL;
  }

  pa_mainloop_api *api = pa_threaded_mainloop_get_api(p->loop);
  p->ctx = pa_context_new(api, "LavaTaskbar");
  if (p->ctx == NULL) {
    pa_threaded_mainloop_free(p->loop);
    free(p);
    return NULL;
  }

  pa_context_set_state_callback(p->ctx, context_state_cb, p);
  if (pa_context_connect(p->ctx, NULL, PA_CONTEXT_NOFLAGS, NULL) < 0) {
    fprintf(stderr, "lava_pulse: connect failed: %s\n",
            pa_strerror(pa_context_errno(p->ctx)));
    pa_context_unref(p->ctx);
    pa_threaded_mainloop_free(p->loop);
    free(p);
    return NULL;
  }

  if (pa_threaded_mainloop_start(p->loop) < 0) {
    fprintf(stderr, "lava_pulse: mainloop start failed\n");
    pa_context_disconnect(p->ctx);
    pa_context_unref(p->ctx);
    pa_threaded_mainloop_free(p->loop);
    free(p);
    return NULL;
  }

  return p;
}

void lava_pulse_destroy(LavaPulse *p)
{
  if (p == NULL) return;
  if (p->loop) {
    pa_threaded_mainloop_lock(p->loop);
    if (p->ctx) {
      pa_context_disconnect(p->ctx);
      pa_context_unref(p->ctx);
      p->ctx = NULL;
    }
    pa_threaded_mainloop_unlock(p->loop);
    pa_threaded_mainloop_stop(p->loop);
    pa_threaded_mainloop_free(p->loop);
  }
  free(p);
}

static void with_lock(LavaPulse *p, void (*fn)(LavaPulse *))
{
  if (p == NULL || p->loop == NULL) return;
  pa_threaded_mainloop_lock(p->loop);
  fn(p);
  pa_threaded_mainloop_unlock(p->loop);
}

static void do_set_volume(LavaPulse *p, float volume)
{
  if (!p->ready || p->ctx == NULL || p->sink_index == PA_INVALID_INDEX) return;
  if (volume < 0.f) volume = 0.f;
  if (volume > 1.5f) volume = 1.5f;
  pa_volume_t v = (pa_volume_t)lroundf(volume * (float)PA_VOLUME_NORM);
  if (v > PA_VOLUME_MAX) v = PA_VOLUME_MAX;
  pa_cvolume vol = p->volume;
  const int channels = vol.channels > 0 ? vol.channels : 2;
  pa_cvolume_set(&vol, (uint8_t)channels, v);
  p->volume = vol;
  pa_operation *op = pa_context_set_sink_volume_by_index(
      p->ctx, p->sink_index, &vol, NULL, NULL);
  if (op) pa_operation_unref(op);
  publish(p);
}

void lava_pulse_set_volume(LavaPulse *p, float volume)
{
  if (p == NULL || p->loop == NULL) return;
  pa_threaded_mainloop_lock(p->loop);
  do_set_volume(p, volume);
  pa_threaded_mainloop_unlock(p->loop);
}

void lava_pulse_set_mute(LavaPulse *p, int muted)
{
  if (p == NULL || p->loop == NULL) return;
  pa_threaded_mainloop_lock(p->loop);
  if (p->ready && p->ctx && p->sink_index != PA_INVALID_INDEX) {
    p->muted = muted ? 1 : 0;
    pa_operation *op = pa_context_set_sink_mute_by_index(
        p->ctx, p->sink_index, p->muted, NULL, NULL);
    if (op) pa_operation_unref(op);
    publish(p);
  }
  pa_threaded_mainloop_unlock(p->loop);
}

void lava_pulse_toggle_mute(LavaPulse *p)
{
  if (p == NULL || p->loop == NULL) return;
  pa_threaded_mainloop_lock(p->loop);
  const int next = p->muted ? 0 : 1;
  if (p->ready && p->ctx && p->sink_index != PA_INVALID_INDEX) {
    p->muted = next;
    pa_operation *op = pa_context_set_sink_mute_by_index(
        p->ctx, p->sink_index, p->muted, NULL, NULL);
    if (op) pa_operation_unref(op);
    publish(p);
  }
  pa_threaded_mainloop_unlock(p->loop);
}

void lava_pulse_adjust_volume(LavaPulse *p, float delta)
{
  if (p == NULL || p->loop == NULL) return;
  pa_threaded_mainloop_lock(p->loop);
  float cur = 0.f;
  if (p->volume.channels > 0) {
    cur = (float)pa_cvolume_avg(&p->volume) / (float)PA_VOLUME_NORM;
  }
  do_set_volume(p, cur + delta);
  pa_threaded_mainloop_unlock(p->loop);
}
