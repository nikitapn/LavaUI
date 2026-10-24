#include "lava_pulse.h"

#include <math.h>
#include <pulse/pulseaudio.h>
#include <pulse/thread-mainloop.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// One refresh's worth of lists, built up by the info callbacks and thrown
// away once published. Every string in it is owned.
typedef struct {
  LavaPulseDevice *items;
  size_t count, cap;
} DeviceList;

typedef struct {
  LavaPulseStream *items;
  size_t count, cap;
} StreamList;

struct LavaPulse {
  pa_threaded_mainloop *loop;
  pa_context *ctx;
  LavaPulseSnapshotFn cb;
  void *user;
  int ready;

  // A refresh is five queries; `pending` counts the ones still out. An
  // event that lands while they are out only sets `dirty`, so a slider
  // drag's hundred change events are a handful of refreshes, not a queue.
  int pending;
  int dirty;
  char *default_sink;
  char *default_source;
  DeviceList sinks, sources;
  StreamList streams;

  // Monitor sources from the last refresh — what not to move a recording
  // off when the default input changes.
  uint32_t *monitors;
  size_t monitor_count, monitors_cap;
  uint32_t *monitors_next;
  size_t monitors_next_count, monitors_next_cap;
};

static char *dup(const char *s) { return strdup(s ? s : ""); }

static const char *prop(pa_proplist *list, const char *key)
{
  const char *v = list ? pa_proplist_gets(list, key) : NULL;
  return v ? v : "";
}

static float average(const pa_cvolume *v)
{
  if (v->channels == 0) return 0.f;
  float f = (float)pa_cvolume_avg(v) / (float)PA_VOLUME_NORM;
  if (f < 0.f) f = 0.f;
  if (f > 1.5f) f = 1.5f; // soft boost up to ~150%
  return f;
}

static void free_device(LavaPulseDevice *d)
{
  free((char *)d->name);
  free((char *)d->description);
  free((char *)d->card);
  free((char *)d->icon);
  free((char *)d->form_factor);
  free((char *)d->bus);
  free((char *)d->active_port);
  for (size_t i = 0; i < d->port_count; i++) {
    free((char *)d->ports[i].name);
    free((char *)d->ports[i].description);
  }
  free((LavaPulsePort *)d->ports);
}

static void clear_devices(DeviceList *list)
{
  for (size_t i = 0; i < list->count; i++) free_device(&list->items[i]);
  list->count = 0;
}

static void clear_streams(StreamList *list)
{
  for (size_t i = 0; i < list->count; i++) {
    LavaPulseStream *s = &list->items[i];
    free((char *)s->app);
    free((char *)s->media);
    free((char *)s->icon);
    free((char *)s->binary);
  }
  list->count = 0;
}

static LavaPulseDevice *push_device(DeviceList *list)
{
  if (list->count == list->cap) {
    size_t cap = list->cap ? list->cap * 2 : 8;
    LavaPulseDevice *grown = realloc(list->items, cap * sizeof *grown);
    if (grown == NULL) return NULL;
    list->items = grown;
    list->cap = cap;
  }
  LavaPulseDevice *d = &list->items[list->count++];
  memset(d, 0, sizeof *d);
  return d;
}

static LavaPulseStream *push_stream(StreamList *list)
{
  if (list->count == list->cap) {
    size_t cap = list->cap ? list->cap * 2 : 8;
    LavaPulseStream *grown = realloc(list->items, cap * sizeof *grown);
    if (grown == NULL) return NULL;
    list->items = grown;
    list->cap = cap;
  }
  LavaPulseStream *s = &list->items[list->count++];
  memset(s, 0, sizeof *s);
  return s;
}

static void publish(LavaPulse *p)
{
  if (p->cb == NULL) return;
  LavaPulseSnapshot snap = {
      .ready = p->ready,
      .default_sink = p->default_sink ? p->default_sink : "",
      .default_source = p->default_source ? p->default_source : "",
      .sinks = p->sinks.items,
      .sink_count = p->sinks.count,
      .sources = p->sources.items,
      .source_count = p->sources.count,
      .streams = p->streams.items,
      .stream_count = p->streams.count,
  };
  p->cb(p->user, &snap);
}

static void start_refresh(LavaPulse *p);

static void finish_query(LavaPulse *p)
{
  if (--p->pending > 0) return;
  // The monitor list swaps only once the source query is complete, so a
  // move issued mid-refresh still sees a whole list.
  uint32_t *old = p->monitors;
  const size_t old_cap = p->monitors_cap;
  p->monitors = p->monitors_next;
  p->monitor_count = p->monitors_next_count;
  p->monitors_cap = p->monitors_next_cap;
  p->monitors_next = old;
  p->monitors_next_cap = old_cap;
  p->monitors_next_count = 0;
  publish(p);
  if (p->dirty) start_refresh(p);
}

// The port list is the same shape for sinks and sources, but the two info
// structs are different types, so each side copies its own.
#define COPY_PORTS(d, info)                                                    \
  do {                                                                         \
    if ((info)->n_ports > 0) {                                                 \
      LavaPulsePort *ports = calloc((info)->n_ports, sizeof *ports);           \
      if (ports) {                                                             \
        for (uint32_t k = 0; k < (info)->n_ports; k++) {                       \
          ports[k].name = dup((info)->ports[k]->name);                         \
          ports[k].description = dup((info)->ports[k]->description);           \
          ports[k].available = (info)->ports[k]->available ==                  \
                                       PA_PORT_AVAILABLE_YES                   \
                                   ? LAVA_PULSE_PORT_YES                       \
                               : (info)->ports[k]->available ==                \
                                       PA_PORT_AVAILABLE_NO                    \
                                   ? LAVA_PULSE_PORT_NO                        \
                                   : LAVA_PULSE_PORT_UNKNOWN;                  \
          ports[k].type = (int)(info)->ports[k]->type;                         \
        }                                                                      \
        (d)->ports = ports;                                                    \
        (d)->port_count = (info)->n_ports;                                     \
      }                                                                        \
    }                                                                          \
    (d)->active_port =                                                         \
        dup((info)->active_port ? (info)->active_port->name : "");             \
  } while (0)

static void sink_cb(pa_context *c, const pa_sink_info *i, int eol, void *userdata)
{
  (void)c;
  LavaPulse *p = userdata;
  if (eol) { finish_query(p); return; }
  if (i == NULL) return;
  LavaPulseDevice *d = push_device(&p->sinks);
  if (d == NULL) return;
  d->index = i->index;
  d->name = dup(i->name);
  d->description = dup(i->description && i->description[0] ? i->description : i->name);
  d->card = dup(prop(i->proplist, PA_PROP_DEVICE_DESCRIPTION));
  d->icon = dup(prop(i->proplist, PA_PROP_DEVICE_ICON_NAME));
  d->form_factor = dup(prop(i->proplist, PA_PROP_DEVICE_FORM_FACTOR));
  d->bus = dup(prop(i->proplist, PA_PROP_DEVICE_BUS));
  d->volume = average(&i->volume);
  d->muted = i->mute ? 1 : 0;
  d->channels = i->volume.channels;
  COPY_PORTS(d, i);
}

static void source_cb(pa_context *c, const pa_source_info *i, int eol, void *userdata)
{
  (void)c;
  LavaPulse *p = userdata;
  if (eol) { finish_query(p); return; }
  if (i == NULL) return;
  if (i->monitor_of_sink != PA_INVALID_INDEX) {
    if (p->monitors_next_count == p->monitors_next_cap) {
      size_t cap = p->monitors_next_cap ? p->monitors_next_cap * 2 : 8;
      uint32_t *grown = realloc(p->monitors_next, cap * sizeof *grown);
      if (grown == NULL) return;
      p->monitors_next = grown;
      p->monitors_next_cap = cap;
    }
    p->monitors_next[p->monitors_next_count++] = i->index;
    return;
  }
  LavaPulseDevice *d = push_device(&p->sources);
  if (d == NULL) return;
  d->index = i->index;
  d->name = dup(i->name);
  d->description = dup(i->description && i->description[0] ? i->description : i->name);
  d->card = dup(prop(i->proplist, PA_PROP_DEVICE_DESCRIPTION));
  d->icon = dup(prop(i->proplist, PA_PROP_DEVICE_ICON_NAME));
  d->form_factor = dup(prop(i->proplist, PA_PROP_DEVICE_FORM_FACTOR));
  d->bus = dup(prop(i->proplist, PA_PROP_DEVICE_BUS));
  d->volume = average(&i->volume);
  d->muted = i->mute ? 1 : 0;
  d->channels = i->volume.channels;
  COPY_PORTS(d, i);
}

static void sink_input_cb(pa_context *c, const pa_sink_input_info *i, int eol,
                          void *userdata)
{
  (void)c;
  LavaPulse *p = userdata;
  if (eol) { finish_query(p); return; }
  if (i == NULL) return;
  LavaPulseStream *s = push_stream(&p->streams);
  if (s == NULL) return;
  s->index = i->index;
  s->sink = i->sink;
  s->app = dup(prop(i->proplist, PA_PROP_APPLICATION_NAME));
  s->media = dup(prop(i->proplist, PA_PROP_MEDIA_NAME));
  s->icon = dup(prop(i->proplist, PA_PROP_APPLICATION_ICON_NAME));
  s->binary = dup(prop(i->proplist, PA_PROP_APPLICATION_PROCESS_BINARY));
  s->volume = average(&i->volume);
  s->muted = i->mute ? 1 : 0;
  s->channels = i->volume.channels;
  s->corked = i->corked ? 1 : 0;
}

static void server_cb(pa_context *c, const pa_server_info *i, void *userdata)
{
  (void)c;
  LavaPulse *p = userdata;
  if (i) {
    free(p->default_sink);
    free(p->default_source);
    p->default_sink = dup(i->default_sink_name);
    p->default_source = dup(i->default_source_name);
  }
  finish_query(p);
}

static void start_refresh(LavaPulse *p)
{
  if (p->ctx == NULL || !p->ready) return;
  if (p->pending > 0) { p->dirty = 1; return; }
  p->dirty = 0;
  clear_devices(&p->sinks);
  clear_devices(&p->sources);
  clear_streams(&p->streams);
  p->monitors_next_count = 0;

  pa_operation *ops[4] = {
      pa_context_get_server_info(p->ctx, server_cb, p),
      pa_context_get_sink_info_list(p->ctx, sink_cb, p),
      pa_context_get_source_info_list(p->ctx, source_cb, p),
      pa_context_get_sink_input_info_list(p->ctx, sink_input_cb, p),
  };
  for (int k = 0; k < 4; k++) {
    if (ops[k]) {
      p->pending++;
      pa_operation_unref(ops[k]);
    }
  }
}

static void subscribe_cb(pa_context *c, pa_subscription_event_type_t t,
                         uint32_t idx, void *userdata)
{
  (void)c;
  (void)t;
  (void)idx;
  start_refresh(userdata);
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
                                   PA_SUBSCRIPTION_MASK_SOURCE |
                                   PA_SUBSCRIPTION_MASK_SINK_INPUT |
                                   PA_SUBSCRIPTION_MASK_CARD |
                                   PA_SUBSCRIPTION_MASK_SERVER),
          NULL, NULL);
      if (op) pa_operation_unref(op);
    }
    start_refresh(p);
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

LavaPulse *lava_pulse_create(LavaPulseSnapshotFn cb, void *user)
{
  LavaPulse *p = calloc(1, sizeof *p);
  if (p == NULL) return NULL;
  p->cb = cb;
  p->user = user;

  p->loop = pa_threaded_mainloop_new();
  if (p->loop == NULL) {
    free(p);
    return NULL;
  }

  pa_mainloop_api *api = pa_threaded_mainloop_get_api(p->loop);
  p->ctx = pa_context_new(api, "LavaPanel");
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
  clear_devices(&p->sinks);
  clear_devices(&p->sources);
  clear_streams(&p->streams);
  free(p->sinks.items);
  free(p->sources.items);
  free(p->streams.items);
  free(p->default_sink);
  free(p->default_source);
  free(p->monitors);
  free(p->monitors_next);
  free(p);
}

// MARK: - Commands

static int usable(LavaPulse *p) { return p->ready && p->ctx != NULL; }

static void flat_volume(pa_cvolume *out, int channels, float volume)
{
  if (volume < 0.f) volume = 0.f;
  if (volume > 1.5f) volume = 1.5f;
  pa_volume_t v = (pa_volume_t)lroundf(volume * (float)PA_VOLUME_NORM);
  if (v > PA_VOLUME_MAX) v = PA_VOLUME_MAX;
  pa_cvolume_init(out);
  int n = channels > 0 && channels <= PA_CHANNELS_MAX ? channels : 2;
  pa_cvolume_set(out, (unsigned)n, v);
}

static void done(pa_operation *op)
{
  if (op) pa_operation_unref(op);
}

void lava_pulse_set_device_volume(LavaPulse *p, int kind, const char *name,
                                  int channels, float volume)
{
  if (p == NULL || p->loop == NULL || name == NULL) return;
  pa_threaded_mainloop_lock(p->loop);
  if (usable(p)) {
    pa_cvolume vol;
    flat_volume(&vol, channels, volume);
    done(kind == LAVA_PULSE_SOURCE
             ? pa_context_set_source_volume_by_name(p->ctx, name, &vol, NULL, NULL)
             : pa_context_set_sink_volume_by_name(p->ctx, name, &vol, NULL, NULL));
  }
  pa_threaded_mainloop_unlock(p->loop);
}

void lava_pulse_set_device_mute(LavaPulse *p, int kind, const char *name, int muted)
{
  if (p == NULL || p->loop == NULL || name == NULL) return;
  pa_threaded_mainloop_lock(p->loop);
  if (usable(p)) {
    done(kind == LAVA_PULSE_SOURCE
             ? pa_context_set_source_mute_by_name(p->ctx, name, muted != 0, NULL, NULL)
             : pa_context_set_sink_mute_by_name(p->ctx, name, muted != 0, NULL, NULL));
  }
  pa_threaded_mainloop_unlock(p->loop);
}

// What a move needs to know once the stream list comes back.
typedef struct {
  LavaPulse *p;
  char *target;
} Move;

static void move_sink_inputs_cb(pa_context *c, const pa_sink_input_info *i,
                                int eol, void *userdata)
{
  Move *m = userdata;
  if (eol) {
    free(m->target);
    free(m);
    return;
  }
  if (i == NULL) return;
  done(pa_context_move_sink_input_by_name(c, i->index, m->target, NULL, NULL));
}

static void move_source_outputs_cb(pa_context *c, const pa_source_output_info *i,
                                   int eol, void *userdata)
{
  Move *m = userdata;
  if (eol) {
    free(m->target);
    free(m);
    return;
  }
  if (i == NULL) return;
  // Something recording a monitor — a screen recorder taking the desktop's
  // sound — is not using a microphone, and must not be handed one.
  for (size_t k = 0; k < m->p->monitor_count; k++) {
    if (m->p->monitors[k] == i->source) return;
  }
  done(pa_context_move_source_output_by_name(c, i->index, m->target, NULL, NULL));
}

void lava_pulse_set_default(LavaPulse *p, int kind, const char *name, const char *port)
{
  if (p == NULL || p->loop == NULL || name == NULL) return;
  pa_threaded_mainloop_lock(p->loop);
  if (usable(p)) {
    const int source = kind == LAVA_PULSE_SOURCE;
    if (port && port[0]) {
      done(source ? pa_context_set_source_port_by_name(p->ctx, name, port, NULL, NULL)
                  : pa_context_set_sink_port_by_name(p->ctx, name, port, NULL, NULL));
    }
    done(source ? pa_context_set_default_source(p->ctx, name, NULL, NULL)
                : pa_context_set_default_sink(p->ctx, name, NULL, NULL));
    Move *m = calloc(1, sizeof *m);
    if (m) {
      m->p = p;
      m->target = dup(name);
      pa_operation *op =
          source ? pa_context_get_source_output_info_list(p->ctx, move_source_outputs_cb, m)
                 : pa_context_get_sink_input_info_list(p->ctx, move_sink_inputs_cb, m);
      if (op) {
        pa_operation_unref(op);
      } else {
        free(m->target);
        free(m);
      }
    }
  }
  pa_threaded_mainloop_unlock(p->loop);
}

void lava_pulse_set_stream_volume(LavaPulse *p, uint32_t index, int channels, float volume)
{
  if (p == NULL || p->loop == NULL) return;
  pa_threaded_mainloop_lock(p->loop);
  if (usable(p)) {
    pa_cvolume vol;
    flat_volume(&vol, channels, volume);
    done(pa_context_set_sink_input_volume(p->ctx, index, &vol, NULL, NULL));
  }
  pa_threaded_mainloop_unlock(p->loop);
}

void lava_pulse_set_stream_mute(LavaPulse *p, uint32_t index, int muted)
{
  if (p == NULL || p->loop == NULL) return;
  pa_threaded_mainloop_lock(p->loop);
  if (usable(p)) {
    done(pa_context_set_sink_input_mute(p->ctx, index, muted != 0, NULL, NULL));
  }
  pa_threaded_mainloop_unlock(p->loop);
}
