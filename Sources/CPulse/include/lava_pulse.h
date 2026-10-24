// Thin C surface over libpulse for Lava's sound applet.
//
// Pulse's async C API is awkward to drive from Swift callbacks (threaded
// mainloop + context state). This keeps the subscription in C and posts one
// whole snapshot to Swift — outputs, inputs, playing streams — whenever any
// of them changes. A snapshot rather than deltas: the lists are a few dozen
// rows, and a delta protocol would be a second copy of Pulse's state to keep
// in step.

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LavaPulse LavaPulse;

/// Pulse's port availability: whether a jack has something in it.
enum {
  LAVA_PULSE_PORT_UNKNOWN = 0,
  LAVA_PULSE_PORT_NO = 1,
  LAVA_PULSE_PORT_YES = 2,
};

typedef struct {
  const char *name;
  const char *description;
  int available;
  /// `pa_device_port_type_t` — speaker, headphones, HDMI, …
  int type;
} LavaPulsePort;

/// A sink or a source. Monitor sources are left out: they are a sink's
/// output seen as an input, and nobody picks one as their microphone.
typedef struct {
  uint32_t index;
  const char *name;
  const char *description;
  /// The card's own description (`device.description`); "" if unset.
  const char *card;
  /// `device.icon_name`, `device.form_factor`, `device.bus`; "" if unset.
  const char *icon;
  const char *form_factor;
  const char *bus;
  /// 0…1.5 linear against PA_VOLUME_NORM (not dB), the channel average.
  float volume;
  int muted;
  int channels;
  const LavaPulsePort *ports;
  size_t port_count;
  /// "" when the device has no ports.
  const char *active_port;
} LavaPulseDevice;

/// A playing stream — a sink input.
typedef struct {
  uint32_t index;
  /// The sink it plays into.
  uint32_t sink;
  const char *app;
  const char *media;
  const char *icon;
  const char *binary;
  float volume;
  int muted;
  int channels;
  int corked;
} LavaPulseStream;

/// Valid only for the duration of the callback; copy what you keep.
typedef struct {
  int ready;
  const char *default_sink;
  const char *default_source;
  const LavaPulseDevice *sinks;
  size_t sink_count;
  const LavaPulseDevice *sources;
  size_t source_count;
  const LavaPulseStream *streams;
  size_t stream_count;
} LavaPulseSnapshot;

typedef void (*LavaPulseSnapshotFn)(void *user, const LavaPulseSnapshot *snapshot);

/// Connects to the default PulseAudio / PipeWire server on a private
/// threaded mainloop. `cb` is invoked from that loop's thread — the caller
/// must hop before touching UI state.
LavaPulse *lava_pulse_create(LavaPulseSnapshotFn cb, void *user);

void lava_pulse_destroy(LavaPulse *p);

enum { LAVA_PULSE_SINK = 0, LAVA_PULSE_SOURCE = 1 };

/// 0…1.5, clamped, every channel set to it. No-op until ready.
void lava_pulse_set_device_volume(LavaPulse *p, int kind, const char *name,
                                  int channels, float volume);

void lava_pulse_set_device_mute(LavaPulse *p, int kind, const char *name, int muted);

/// Makes `name` the default output or input, on `port` first when it is
/// not NULL, and moves what is playing (or recording) onto it — a default
/// that only applies to the next stream is not what "switch to headphones"
/// means.
void lava_pulse_set_default(LavaPulse *p, int kind, const char *name, const char *port);

void lava_pulse_set_stream_volume(LavaPulse *p, uint32_t index, int channels, float volume);

void lava_pulse_set_stream_mute(LavaPulse *p, uint32_t index, int muted);

#ifdef __cplusplus
}
#endif
