// Thin C surface over libpulse for Lava's volume applet.
//
// Pulse's async C API is awkward to drive from Swift callbacks (threaded
// mainloop + context state). This keeps the subscription / volume math in C
// and posts a single snapshot to Swift whenever the default sink changes.

#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LavaPulse LavaPulse;

/// `volume` is 0…1 linear against PA_VOLUME_NORM (not dB).
/// `sink_name` is the human description when available, else the sink name.
typedef void (*LavaPulseUpdateFn)(
    void *user, float volume, int muted, const char *sink_name, int ready);

/// Connects to the default PulseAudio / PipeWire server on a private
/// threaded mainloop. `cb` may be invoked from a non-main thread — the
/// caller must hop before touching UI state.
LavaPulse *lava_pulse_create(LavaPulseUpdateFn cb, void *user);

void lava_pulse_destroy(LavaPulse *p);

/// 0…1. Clamped. No-op until the context is ready.
void lava_pulse_set_volume(LavaPulse *p, float volume);

void lava_pulse_set_mute(LavaPulse *p, int muted);

void lava_pulse_toggle_mute(LavaPulse *p);

/// Relative adjust in the same 0…1 space (e.g. +0.05 for one notch).
void lava_pulse_adjust_volume(LavaPulse *p, float delta);

#ifdef __cplusplus
}
#endif
