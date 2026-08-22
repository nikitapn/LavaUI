// Thin C surface over sd-bus for the panel's media applet.
//
// MPRIS (`org.mpris.MediaPlayer2.*`) is how a desktop talks to a player
// without knowing whether it is spotifyd, the official client, or mpv.
// Pulse's async C API is awkward from Swift; so is sd-bus's message
// iterator. This keeps name watching and metadata parsing in C and posts
// a snapshot whenever the current player changes.
//
// Prefers a bus name containing "spotifyd", then "spotify", then any
// other MPRIS player. `playerctld` is skipped — it is a mux, not a
// player, and claiming it would hide the daemon behind it.

#pragma once

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LavaMpris LavaMpris;

typedef struct LavaMprisSnapshot {
  /// 0 if nothing on the bus is a player we will talk to.
  int present;
  const char *bus_name;
  const char *identity;
  /// "Playing", "Paused", or "Stopped".
  const char *status;
  const char *title;
  const char *artist;
  const char *album;
  /// `mpris:artUrl`. May be https, file://, or empty.
  const char *art_url;
  int can_go_next;
  int can_go_previous;
  int can_play;
  int can_pause;
} LavaMprisSnapshot;

/// Invoked from the sd-event thread. Copy the strings before returning;
/// they alias internal buffers and will move on the next update.
typedef void (*LavaMprisUpdateFn)(void *user, const LavaMprisSnapshot *snap);

/// Opens the session bus on a private event loop. `cb` may run off the
/// UI thread — hop before touching observable state.
LavaMpris *lava_mpris_create(LavaMprisUpdateFn cb, void *user);

void lava_mpris_destroy(LavaMpris *p);

void lava_mpris_next(LavaMpris *p);
void lava_mpris_previous(LavaMpris *p);
void lava_mpris_play_pause(LavaMpris *p);

#ifdef __cplusplus
}
#endif
