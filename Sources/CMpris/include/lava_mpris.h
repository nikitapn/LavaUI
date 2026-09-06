// Thin C surface over sd-bus for the panel's media applet and LavaSpotify.
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
//
// spotifyd also exposes `rs.spotifyd.Controls` before it is the active
// Connect device. `TransferPlayback` on that interface makes it the
// speaker; MPRIS appears afterwards. Transport (Next, OpenUri, Volume)
// goes through librespot, not api.spotify.com.

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LavaMpris LavaMpris;

enum {
  /// Ignore every MPRIS name that is not spotifyd. LavaSpotify uses this
  /// so a paused mpv window cannot steal OpenUri.
  LAVA_MPRIS_SPOTIFYD_ONLY = 1u
};

typedef struct LavaMprisSnapshot {
  /// 0 if nothing on the bus is a player we will talk to.
  int present;
  /// 1 if `rs.spotifyd.Controls` is on the bus (may be idle / not active).
  int controls_present;
  const char *bus_name;
  const char *identity;
  /// "Playing", "Paused", or "Stopped".
  const char *status;
  const char *title;
  const char *artist;
  const char *album;
  /// `mpris:artUrl`. May be https, file://, or empty.
  const char *art_url;
  /// MPRIS track object path (`/spotify/track/…` on spotifyd).
  const char *track_id;
  /// `spotify:track:…` derived from `track_id` when the path is well-formed.
  const char *track_uri;
  /// `mpris:length` in microseconds. 0 if unknown.
  int64_t length_us;
  /// `Position` in microseconds. 0 if unknown / stopped.
  int64_t position_us;
  /// 0…1. Connect mixer, not the Pulse sink.
  double volume;
  int can_go_next;
  int can_go_previous;
  int can_play;
  int can_pause;
  int can_seek;
  int can_control;
} LavaMprisSnapshot;

/// Invoked from the sd-event thread. Copy the strings before returning;
/// they alias internal buffers and will move on the next update.
typedef void (*LavaMprisUpdateFn)(void *user, const LavaMprisSnapshot *snap);

/// Opens the session bus on a private event loop. `cb` may run off the
/// UI thread — hop before touching observable state.
LavaMpris *lava_mpris_create(LavaMprisUpdateFn cb, void *user);

/// Same as `lava_mpris_create`, with `LAVA_MPRIS_*` flags.
LavaMpris *lava_mpris_create_with_flags(LavaMprisUpdateFn cb, void *user,
                                        unsigned flags);

void lava_mpris_destroy(LavaMpris *p);

void lava_mpris_next(LavaMpris *p);
void lava_mpris_previous(LavaMpris *p);
void lava_mpris_play_pause(LavaMpris *p);
void lava_mpris_play(LavaMpris *p);
void lava_mpris_pause(LavaMpris *p);
void lava_mpris_stop(LavaMpris *p);

/// `spotify:track:…` / `spotify:album:…`. If MPRIS is not up yet but
/// Controls is, this transfers playback first and opens the URI when the
/// player name appears.
void lava_mpris_open_uri(LavaMpris *p, const char *uri);

/// Relative seek, microseconds (MPRIS `Seek`).
void lava_mpris_seek(LavaMpris *p, int64_t offset_us);

/// Absolute position, microseconds (MPRIS `SetPosition` on the current track).
void lava_mpris_set_position(LavaMpris *p, int64_t position_us);

/// Connect mixer, clamped to 0…1.
void lava_mpris_set_volume(LavaMpris *p, double volume);

/// `rs.spotifyd.Controls.TransferPlayback` — make spotifyd the active device.
void lava_mpris_transfer_playback(LavaMpris *p);

#ifdef __cplusplus
}
#endif
