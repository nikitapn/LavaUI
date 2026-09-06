#include "lava_mpris.h"

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <time.h>
#include <unistd.h>

#include <systemd/sd-bus.h>
#include <systemd/sd-event.h>

#define MPRIS_PREFIX "org.mpris.MediaPlayer2."
#define MPRIS_PATH "/org/mpris/MediaPlayer2"
#define PLAYER_IFACE "org.mpris.MediaPlayer2.Player"
#define APP_IFACE "org.mpris.MediaPlayer2"
#define CONTROLS_PREFIX "rs.spotifyd."
#define CONTROLS_PATH "/rs/spotifyd/Controls"
#define CONTROLS_IFACE "rs.spotifyd.Controls"
#define MAX_PLAYERS 16
#define CMD_CAP 16

enum {
  CMD_NEXT = 1,
  CMD_PREV,
  CMD_PLAYPAUSE,
  CMD_PLAY,
  CMD_PAUSE,
  CMD_STOP,
  CMD_QUIT,
  CMD_OPEN_URI,
  CMD_SEEK,
  CMD_SET_POSITION,
  CMD_SET_VOLUME,
  CMD_TRANSFER
};

struct LavaMprisCmd {
  unsigned kind;
  int64_t i64;
  double dbl;
  char str[768];
};

struct LavaMpris {
  sd_bus *bus;
  sd_event *event;
  pthread_t thread;
  int thread_started;
  int cmd_fd;
  pthread_mutex_t lock;
  unsigned flags;

  struct LavaMprisCmd q[CMD_CAP];
  int q_head;
  int q_tail;

  LavaMprisUpdateFn cb;
  void *user;

  char names[MAX_PLAYERS][256];
  int n_names;
  char current[256];
  char controls[256];
  sd_bus_slot *prop_slot;
  sd_bus_slot *seeked_slot;
  sd_event_source *pos_src;

  char pending_uri[768];
  int pending_playpause;

  int present;
  int controls_present;
  char identity[128];
  char status[32];
  char title[256];
  char artist[256];
  char album[256];
  char art_url[512];
  char track_id[256];
  char track_uri[256];
  int64_t length_us;
  int64_t position_us;
  double volume;
  int can_go_next;
  int can_go_previous;
  int can_play;
  int can_pause;
  int can_seek;
  int can_control;
};

static void copy_str(char *dst, size_t n, const char *s)
{
  if (s == NULL) {
    dst[0] = 0;
    return;
  }
  snprintf(dst, n, "%s", s);
}

static void derive_track_uri(LavaMpris *p)
{
  p->track_uri[0] = 0;
  const char *id = p->track_id;
  if (strncmp(id, "/spotify/track/", 15) == 0)
    snprintf(p->track_uri, sizeof p->track_uri, "spotify:track:%s", id + 15);
  else if (strncmp(id, "/spotify/episode/", 17) == 0)
    snprintf(p->track_uri, sizeof p->track_uri, "spotify:episode:%s", id + 17);
}

static void publish(LavaMpris *p)
{
  if (p->cb == NULL) return;
  LavaMprisSnapshot snap = {
      .present = p->present,
      .controls_present = p->controls_present,
      .bus_name = p->current,
      .identity = p->identity,
      .status = p->status,
      .title = p->title,
      .artist = p->artist,
      .album = p->album,
      .art_url = p->art_url,
      .track_id = p->track_id,
      .track_uri = p->track_uri,
      .length_us = p->length_us,
      .position_us = p->position_us,
      .volume = p->volume,
      .can_go_next = p->can_go_next,
      .can_go_previous = p->can_go_previous,
      .can_play = p->can_play,
      .can_pause = p->can_pause,
      .can_seek = p->can_seek,
      .can_control = p->can_control,
  };
  p->cb(p->user, &snap);
}

static void clear_track(LavaMpris *p)
{
  p->present = 0;
  p->current[0] = 0;
  p->identity[0] = 0;
  snprintf(p->status, sizeof p->status, "Stopped");
  p->title[0] = 0;
  p->artist[0] = 0;
  p->album[0] = 0;
  p->art_url[0] = 0;
  p->track_id[0] = 0;
  p->track_uri[0] = 0;
  p->length_us = 0;
  p->position_us = 0;
  p->can_go_next = 0;
  p->can_go_previous = 0;
  p->can_play = 0;
  p->can_pause = 0;
  p->can_seek = 0;
  p->can_control = 0;
}

/// Lower is better. -1 means skip (not a player, or playerctld).
static int rank_name(const LavaMpris *p, const char *name)
{
  if (strncmp(name, MPRIS_PREFIX, strlen(MPRIS_PREFIX)) != 0) return -1;
  const char *rest = name + strlen(MPRIS_PREFIX);
  if (rest[0] == '\0') return -1;
  if (strstr(rest, "playerctld") != NULL) return -1;
  const int is_spotifyd = strstr(rest, "spotifyd") != NULL;
  if (p->flags & LAVA_MPRIS_SPOTIFYD_ONLY)
    return is_spotifyd ? 0 : -1;
  if (is_spotifyd) return 0;
  if (strcmp(rest, "spotify") == 0) return 1;
  if (strncmp(rest, "spotify.", 8) == 0) return 1;
  return 10;
}

static int is_controls_name(const char *name)
{
  return name != NULL && strncmp(name, CONTROLS_PREFIX, strlen(CONTROLS_PREFIX)) == 0;
}

static int has_name(const LavaMpris *p, const char *name)
{
  for (int i = 0; i < p->n_names; i++) {
    if (strcmp(p->names[i], name) == 0) return 1;
  }
  return 0;
}

static void add_name(LavaMpris *p, const char *name)
{
  if (rank_name(p, name) < 0) return;
  if (has_name(p, name)) return;
  if (p->n_names >= MAX_PLAYERS) return;
  snprintf(p->names[p->n_names], sizeof p->names[0], "%s", name);
  p->n_names++;
}

static void remove_name(LavaMpris *p, const char *name)
{
  for (int i = 0; i < p->n_names; i++) {
    if (strcmp(p->names[i], name) != 0) continue;
    memmove(p->names[i], p->names[i + 1],
            (size_t)(p->n_names - i - 1) * sizeof p->names[0]);
    p->n_names--;
    return;
  }
}

static const char *best_name(const LavaMpris *p)
{
  const char *best = NULL;
  int best_rank = 1000;
  for (int i = 0; i < p->n_names; i++) {
    const int r = rank_name(p, p->names[i]);
    if (r < 0) continue;
    if (r < best_rank) {
      best_rank = r;
      best = p->names[i];
    }
  }
  return best;
}

static void skip_value(sd_bus_message *m)
{
  sd_bus_message_skip(m, NULL);
}

static int parse_metadata_array(LavaMpris *p, sd_bus_message *m)
{
  int r = sd_bus_message_enter_container(m, 'a', "{sv}");
  if (r < 0) return r;
  p->title[0] = 0;
  p->artist[0] = 0;
  p->album[0] = 0;
  p->art_url[0] = 0;
  p->track_id[0] = 0;
  p->track_uri[0] = 0;
  p->length_us = 0;
  while ((r = sd_bus_message_enter_container(m, 'e', "sv")) > 0) {
    const char *key = NULL;
    r = sd_bus_message_read(m, "s", &key);
    if (r < 0) break;
    char type = 0;
    const char *contents = NULL;
    r = sd_bus_message_peek_type(m, &type, &contents);
    if (r <= 0 || type != SD_BUS_TYPE_VARIANT) {
      skip_value(m);
      sd_bus_message_exit_container(m);
      continue;
    }
    r = sd_bus_message_enter_container(m, 'v', NULL);
    if (r < 0) {
      sd_bus_message_exit_container(m);
      continue;
    }
    sd_bus_message_peek_type(m, &type, &contents);
    if (key != NULL && type == 's' &&
        (strcmp(key, "xesam:title") == 0 || strcmp(key, "xesam:album") == 0 ||
         strcmp(key, "mpris:artUrl") == 0)) {
      const char *s = NULL;
      if (sd_bus_message_read(m, "s", &s) >= 0) {
        if (strcmp(key, "xesam:title") == 0)
          copy_str(p->title, sizeof p->title, s);
        else if (strcmp(key, "xesam:album") == 0)
          copy_str(p->album, sizeof p->album, s);
        else
          copy_str(p->art_url, sizeof p->art_url, s);
      }
    } else if (key != NULL && strcmp(key, "mpris:trackid") == 0 &&
               (type == 'o' || type == 's')) {
      const char *s = NULL;
      if (sd_bus_message_read(m, type == 'o' ? "o" : "s", &s) >= 0)
        copy_str(p->track_id, sizeof p->track_id, s);
    } else if (key != NULL && strcmp(key, "mpris:length") == 0 && type == 'x') {
      int64_t n = 0;
      if (sd_bus_message_read(m, "x", &n) >= 0) p->length_us = n;
    } else if (key != NULL && strcmp(key, "xesam:artist") == 0 && type == 's') {
      const char *s = NULL;
      if (sd_bus_message_read(m, "s", &s) >= 0)
        copy_str(p->artist, sizeof p->artist, s);
    } else if (key != NULL && strcmp(key, "xesam:artist") == 0 && type == 'a') {
      if (sd_bus_message_enter_container(m, 'a', "s") >= 0) {
        p->artist[0] = 0;
        const char *s = NULL;
        int first = 1;
        while (sd_bus_message_read(m, "s", &s) > 0 && s != NULL) {
          const size_t used = strlen(p->artist);
          const size_t room = sizeof p->artist - used;
          if (room <= 1) break;
          if (!first) {
            snprintf(p->artist + used, room, ", %s", s);
          } else {
            copy_str(p->artist, sizeof p->artist, s);
            first = 0;
          }
        }
        sd_bus_message_exit_container(m);
      } else {
        skip_value(m);
      }
    } else {
      skip_value(m);
    }
    sd_bus_message_exit_container(m);  // variant
    sd_bus_message_exit_container(m);  // dict entry
  }
  sd_bus_message_exit_container(m);
  derive_track_uri(p);
  return 0;
}

static int get_string_prop(LavaMpris *p, const char *iface, const char *name,
                           char *out, size_t n)
{
  sd_bus_error err = SD_BUS_ERROR_NULL;
  char *value = NULL;
  int r = sd_bus_get_property_string(p->bus, p->current, MPRIS_PATH, iface,
                                     name, &err, &value);
  if (r < 0) {
    out[0] = 0;
    sd_bus_error_free(&err);
    return r;
  }
  copy_str(out, n, value);
  free(value);
  sd_bus_error_free(&err);
  return 0;
}

static int get_bool_prop(LavaMpris *p, const char *name, int *out)
{
  sd_bus_error err = SD_BUS_ERROR_NULL;
  int v = 0;
  int r = sd_bus_get_property_trivial(p->bus, p->current, MPRIS_PATH,
                                      PLAYER_IFACE, name, &err, 'b', &v);
  if (r < 0) {
    *out = 0;
    sd_bus_error_free(&err);
    return r;
  }
  *out = v ? 1 : 0;
  sd_bus_error_free(&err);
  return 0;
}

static int get_int64_prop(LavaMpris *p, const char *name, int64_t *out)
{
  sd_bus_error err = SD_BUS_ERROR_NULL;
  int64_t v = 0;
  int r = sd_bus_get_property_trivial(p->bus, p->current, MPRIS_PATH,
                                      PLAYER_IFACE, name, &err, 'x', &v);
  if (r < 0) {
    sd_bus_error_free(&err);
    return r;
  }
  *out = v;
  sd_bus_error_free(&err);
  return 0;
}

static int get_double_prop(LavaMpris *p, const char *name, double *out)
{
  sd_bus_error err = SD_BUS_ERROR_NULL;
  double v = 0;
  int r = sd_bus_get_property_trivial(p->bus, p->current, MPRIS_PATH,
                                      PLAYER_IFACE, name, &err, 'd', &v);
  if (r < 0) {
    sd_bus_error_free(&err);
    return r;
  }
  *out = v;
  sd_bus_error_free(&err);
  return 0;
}

static void refresh_player(LavaMpris *p)
{
  if (p->current[0] == '\0') {
    clear_track(p);
    publish(p);
    return;
  }
  p->present = 1;
  get_string_prop(p, APP_IFACE, "Identity", p->identity, sizeof p->identity);
  if (get_string_prop(p, PLAYER_IFACE, "PlaybackStatus", p->status,
                      sizeof p->status) < 0) {
    snprintf(p->status, sizeof p->status, "Stopped");
  }
  get_bool_prop(p, "CanGoNext", &p->can_go_next);
  get_bool_prop(p, "CanGoPrevious", &p->can_go_previous);
  get_bool_prop(p, "CanPlay", &p->can_play);
  get_bool_prop(p, "CanPause", &p->can_pause);
  get_bool_prop(p, "CanSeek", &p->can_seek);
  get_bool_prop(p, "CanControl", &p->can_control);
  if (get_int64_prop(p, "Position", &p->position_us) < 0) {
    // Stopped players often refuse Position.
  }
  if (get_double_prop(p, "Volume", &p->volume) < 0) {
    // Leave the last known mixer value.
  }

  sd_bus_error err = SD_BUS_ERROR_NULL;
  sd_bus_message *reply = NULL;
  int r = sd_bus_get_property(p->bus, p->current, MPRIS_PATH, PLAYER_IFACE,
                              "Metadata", &err, &reply, "a{sv}");
  if (r >= 0 && reply != NULL) {
    parse_metadata_array(p, reply);
  }
  if (reply) sd_bus_message_unref(reply);
  sd_bus_error_free(&err);
  publish(p);
}

static void detach_player(LavaMpris *p)
{
  if (p->prop_slot) {
    sd_bus_slot_unref(p->prop_slot);
    p->prop_slot = NULL;
  }
  if (p->seeked_slot) {
    sd_bus_slot_unref(p->seeked_slot);
    p->seeked_slot = NULL;
  }
  p->current[0] = 0;
}

static int on_properties(sd_bus_message *m, void *userdata, sd_bus_error *ret)
{
  (void)ret;
  LavaMpris *p = userdata;
  const char *iface = NULL;
  if (sd_bus_message_read(m, "s", &iface) < 0) return 0;
  if (iface == NULL) return 0;

  int metadata_changed = 0;
  int status_changed = 0;
  int volume_changed = 0;
  if (strcmp(iface, PLAYER_IFACE) == 0) {
    if (sd_bus_message_enter_container(m, 'a', "{sv}") >= 0) {
      while (sd_bus_message_enter_container(m, 'e', "sv") > 0) {
        const char *key = NULL;
        sd_bus_message_read(m, "s", &key);
        char type = 0;
        const char *contents = NULL;
        sd_bus_message_peek_type(m, &type, &contents);
        if (type != SD_BUS_TYPE_VARIANT) {
          skip_value(m);
          sd_bus_message_exit_container(m);
          continue;
        }
        sd_bus_message_enter_container(m, 'v', NULL);
        sd_bus_message_peek_type(m, &type, &contents);
        if (key && strcmp(key, "PlaybackStatus") == 0 && type == 's') {
          const char *s = NULL;
          if (sd_bus_message_read(m, "s", &s) >= 0) {
            copy_str(p->status, sizeof p->status, s);
            status_changed = 1;
          }
        } else if (key && strcmp(key, "Metadata") == 0 && type == 'a') {
          parse_metadata_array(p, m);
          metadata_changed = 1;
        } else if (key && strcmp(key, "Volume") == 0 && type == 'd') {
          double v = 0;
          if (sd_bus_message_read(m, "d", &v) >= 0) {
            p->volume = v;
            volume_changed = 1;
          }
        } else {
          skip_value(m);
        }
        sd_bus_message_exit_container(m);
        sd_bus_message_exit_container(m);
      }
      sd_bus_message_exit_container(m);
    }
  }

  if (metadata_changed || status_changed || volume_changed) {
    p->present = 1;
    if (status_changed && strcmp(p->status, "Playing") == 0)
      get_int64_prop(p, "Position", &p->position_us);
    publish(p);
  } else {
    // Invalidated properties, or a field we do not special-case — reload.
    refresh_player(p);
  }
  return 0;
}

static int on_seeked(sd_bus_message *m, void *userdata, sd_bus_error *ret)
{
  (void)ret;
  LavaMpris *p = userdata;
  int64_t pos = 0;
  if (sd_bus_message_read(m, "x", &pos) >= 0) {
    p->position_us = pos;
    p->present = 1;
    publish(p);
  }
  return 0;
}

static void call_player(LavaMpris *p, const char *method)
{
  if (p->current[0] == '\0') return;
  sd_bus_error err = SD_BUS_ERROR_NULL;
  int r = sd_bus_call_method(p->bus, p->current, MPRIS_PATH, PLAYER_IFACE,
                             method, &err, NULL, NULL);
  if (r < 0) {
    fprintf(stderr, "lava_mpris: %s failed: %s\n", method,
            err.message ? err.message : strerror(-r));
  }
  sd_bus_error_free(&err);
}

static void call_transfer(LavaMpris *p)
{
  if (p->controls[0] == '\0') {
    fprintf(stderr, "lava_mpris: TransferPlayback: no rs.spotifyd.Controls\n");
    return;
  }
  sd_bus_error err = SD_BUS_ERROR_NULL;
  int r = sd_bus_call_method(p->bus, p->controls, CONTROLS_PATH, CONTROLS_IFACE,
                             "TransferPlayback", &err, NULL, NULL);
  if (r < 0) {
    fprintf(stderr, "lava_mpris: TransferPlayback failed: %s\n",
            err.message ? err.message : strerror(-r));
  }
  sd_bus_error_free(&err);
}

static void call_open_uri(LavaMpris *p, const char *uri)
{
  if (uri == NULL || uri[0] == '\0') return;
  if (p->current[0] == '\0') {
    copy_str(p->pending_uri, sizeof p->pending_uri, uri);
    p->pending_playpause = 0;
    call_transfer(p);
    return;
  }
  sd_bus_error err = SD_BUS_ERROR_NULL;
  int r = sd_bus_call_method(p->bus, p->current, MPRIS_PATH, PLAYER_IFACE,
                             "OpenUri", &err, NULL, "s", uri);
  if (r < 0) {
    fprintf(stderr, "lava_mpris: OpenUri failed: %s\n",
            err.message ? err.message : strerror(-r));
  }
  sd_bus_error_free(&err);
}

static void call_play_method(LavaMpris *p, const char *method)
{
  if (p->current[0] == '\0') {
    p->pending_playpause = 1;
    call_transfer(p);
    return;
  }
  call_player(p, method);
}

static void call_seek(LavaMpris *p, int64_t offset_us)
{
  if (p->current[0] == '\0') return;
  sd_bus_error err = SD_BUS_ERROR_NULL;
  int r = sd_bus_call_method(p->bus, p->current, MPRIS_PATH, PLAYER_IFACE,
                             "Seek", &err, NULL, "x", offset_us);
  if (r < 0) {
    fprintf(stderr, "lava_mpris: Seek failed: %s\n",
            err.message ? err.message : strerror(-r));
  }
  sd_bus_error_free(&err);
}

static void call_set_position(LavaMpris *p, int64_t position_us)
{
  if (p->current[0] == '\0' || p->track_id[0] == '\0') return;
  if (strstr(p->track_id, "NoTrack") != NULL) return;
  sd_bus_error err = SD_BUS_ERROR_NULL;
  int r = sd_bus_call_method(p->bus, p->current, MPRIS_PATH, PLAYER_IFACE,
                             "SetPosition", &err, NULL, "ox", p->track_id,
                             position_us);
  if (r < 0) {
    fprintf(stderr, "lava_mpris: SetPosition failed: %s\n",
            err.message ? err.message : strerror(-r));
  }
  sd_bus_error_free(&err);
}

static void call_set_volume(LavaMpris *p, double volume)
{
  if (p->current[0] == '\0') return;
  if (volume < 0) volume = 0;
  if (volume > 1) volume = 1;
  sd_bus_error err = SD_BUS_ERROR_NULL;
  int r = sd_bus_set_property(p->bus, p->current, MPRIS_PATH, PLAYER_IFACE,
                              "Volume", &err, "d", volume);
  if (r < 0) {
    fprintf(stderr, "lava_mpris: set Volume failed: %s\n",
            err.message ? err.message : strerror(-r));
  } else {
    p->volume = volume;
  }
  sd_bus_error_free(&err);
}

static void attach_player(LavaMpris *p, const char *name)
{
  if (name == NULL) {
    detach_player(p);
    clear_track(p);
    publish(p);
    return;
  }
  if (strcmp(p->current, name) == 0) {
    refresh_player(p);
    return;
  }
  detach_player(p);
  copy_str(p->current, sizeof p->current, name);
  int r = sd_bus_match_signal(p->bus, &p->prop_slot, p->current, MPRIS_PATH,
                              "org.freedesktop.DBus.Properties",
                              "PropertiesChanged", on_properties, p);
  if (r < 0) {
    fprintf(stderr, "lava_mpris: PropertiesChanged match failed: %s\n",
            strerror(-r));
  }
  r = sd_bus_match_signal(p->bus, &p->seeked_slot, p->current, MPRIS_PATH,
                          PLAYER_IFACE, "Seeked", on_seeked, p);
  if (r < 0) {
    fprintf(stderr, "lava_mpris: Seeked match failed: %s\n", strerror(-r));
  }
  refresh_player(p);
  if (p->pending_uri[0]) {
    char uri[768];
    copy_str(uri, sizeof uri, p->pending_uri);
    p->pending_uri[0] = 0;
    call_open_uri(p, uri);
  } else if (p->pending_playpause) {
    p->pending_playpause = 0;
    call_player(p, "PlayPause");
  }
}

static void pick_player(LavaMpris *p)
{
  attach_player(p, best_name(p));
}

static void set_controls(LavaMpris *p, const char *name, int present)
{
  if (present) {
    copy_str(p->controls, sizeof p->controls, name);
    p->controls_present = 1;
  } else if (p->controls[0] == '\0' || strcmp(p->controls, name) == 0) {
    p->controls[0] = 0;
    p->controls_present = 0;
  } else {
    return;
  }
  publish(p);
}

static int on_name_owner(sd_bus_message *m, void *userdata, sd_bus_error *ret)
{
  (void)ret;
  LavaMpris *p = userdata;
  const char *name = NULL, *old_owner = NULL, *new_owner = NULL;
  if (sd_bus_message_read(m, "sss", &name, &old_owner, &new_owner) < 0)
    return 0;
  if (name == NULL) return 0;
  const int gone = new_owner == NULL || new_owner[0] == '\0';
  if (is_controls_name(name)) {
    set_controls(p, name, !gone);
    return 0;
  }
  if (rank_name(p, name) < 0) return 0;
  if (gone)
    remove_name(p, name);
  else
    add_name(p, name);
  pick_player(p);
  return 0;
}

static void list_names(LavaMpris *p)
{
  sd_bus_error err = SD_BUS_ERROR_NULL;
  sd_bus_message *reply = NULL;
  int r = sd_bus_call_method(p->bus, "org.freedesktop.DBus",
                             "/org/freedesktop/DBus", "org.freedesktop.DBus",
                             "ListNames", &err, &reply, NULL);
  if (r < 0) {
    fprintf(stderr, "lava_mpris: ListNames failed: %s\n",
            err.message ? err.message : strerror(-r));
    sd_bus_error_free(&err);
    return;
  }
  r = sd_bus_message_enter_container(reply, 'a', "s");
  if (r >= 0) {
    const char *n = NULL;
    while (sd_bus_message_read(reply, "s", &n) > 0) {
      if (is_controls_name(n))
        set_controls(p, n, 1);
      else
        add_name(p, n);
    }
    sd_bus_message_exit_container(reply);
  }
  sd_bus_message_unref(reply);
  sd_bus_error_free(&err);
}

static int on_pos_timer(sd_event_source *s, uint64_t usec, void *userdata)
{
  (void)usec;
  LavaMpris *p = userdata;
  if (p->present && p->current[0] && strcmp(p->status, "Playing") == 0) {
    int64_t pos = 0;
    if (get_int64_prop(p, "Position", &pos) >= 0 && pos != p->position_us) {
      p->position_us = pos;
      publish(p);
    }
  }
  uint64_t now = 0;
  if (sd_event_now(p->event, CLOCK_MONOTONIC, &now) >= 0) {
    sd_event_source_set_time(s, now + 1000000);
    sd_event_source_set_enabled(s, SD_EVENT_ON);
  }
  return 0;
}

static int on_cmd(sd_event_source *s, int fd, uint32_t revents, void *userdata)
{
  (void)s;
  (void)revents;
  LavaMpris *p = userdata;
  uint64_t n = 0;
  if (read(fd, &n, sizeof n) < 0 && errno != EAGAIN) return 0;

  for (;;) {
    pthread_mutex_lock(&p->lock);
    if (p->q_head == p->q_tail) {
      pthread_mutex_unlock(&p->lock);
      break;
    }
    struct LavaMprisCmd cmd = p->q[p->q_head];
    p->q_head = (p->q_head + 1) % CMD_CAP;
    pthread_mutex_unlock(&p->lock);

    switch (cmd.kind) {
      case CMD_QUIT:
        sd_event_exit(p->event, 0);
        return 0;
      case CMD_NEXT:
        call_player(p, "Next");
        break;
      case CMD_PREV:
        call_player(p, "Previous");
        break;
      case CMD_PLAYPAUSE:
        call_play_method(p, "PlayPause");
        break;
      case CMD_PLAY:
        call_play_method(p, "Play");
        break;
      case CMD_PAUSE:
        call_player(p, "Pause");
        break;
      case CMD_STOP:
        call_player(p, "Stop");
        break;
      case CMD_OPEN_URI:
        call_open_uri(p, cmd.str);
        break;
      case CMD_SEEK:
        call_seek(p, cmd.i64);
        break;
      case CMD_SET_POSITION:
        call_set_position(p, cmd.i64);
        break;
      case CMD_SET_VOLUME:
        call_set_volume(p, cmd.dbl);
        break;
      case CMD_TRANSFER:
        call_transfer(p);
        break;
      default:
        break;
    }
  }
  return 0;
}

static void queue_push(LavaMpris *p, struct LavaMprisCmd cmd)
{
  if (p == NULL || p->cmd_fd < 0) return;
  pthread_mutex_lock(&p->lock);
  if (p->q_head != p->q_tail) {
    const int last = (p->q_tail + CMD_CAP - 1) % CMD_CAP;
    if ((cmd.kind == CMD_SET_VOLUME && p->q[last].kind == CMD_SET_VOLUME) ||
        (cmd.kind == CMD_SET_POSITION && p->q[last].kind == CMD_SET_POSITION) ||
        (cmd.kind == CMD_OPEN_URI && p->q[last].kind == CMD_OPEN_URI)) {
      p->q[last] = cmd;
      pthread_mutex_unlock(&p->lock);
      uint64_t one = 1;
      if (write(p->cmd_fd, &one, sizeof one) < 0) {
        // EAGAIN: a previous poke is still queued.
      }
      return;
    }
  }
  const int next = (p->q_tail + 1) % CMD_CAP;
  if (next == p->q_head) {
    pthread_mutex_unlock(&p->lock);
    if (cmd.kind != CMD_QUIT) {
      fprintf(stderr, "lava_mpris: command queue full, dropping %u\n", cmd.kind);
      return;
    }
    // QUIT still has to get through: overwrite the oldest.
    pthread_mutex_lock(&p->lock);
    p->q[p->q_head] = cmd;
    pthread_mutex_unlock(&p->lock);
  } else {
    p->q[p->q_tail] = cmd;
    p->q_tail = next;
    pthread_mutex_unlock(&p->lock);
  }
  uint64_t one = 1;
  if (write(p->cmd_fd, &one, sizeof one) < 0) {
    // EAGAIN is fine: a previous poke is still queued.
  }
}

static void queue_kind(LavaMpris *p, unsigned kind)
{
  struct LavaMprisCmd cmd = {.kind = kind};
  queue_push(p, cmd);
}

static void *loop_thread(void *arg)
{
  LavaMpris *p = arg;
  sd_event_loop(p->event);
  return NULL;
}

static void fail_create(LavaMpris *p)
{
  if (p->pos_src) sd_event_source_unref(p->pos_src);
  if (p->cmd_fd >= 0) close(p->cmd_fd);
  if (p->event) sd_event_unref(p->event);
  if (p->bus) sd_bus_flush_close_unref(p->bus);
  pthread_mutex_destroy(&p->lock);
  free(p);
}

LavaMpris *lava_mpris_create(LavaMprisUpdateFn cb, void *user)
{
  return lava_mpris_create_with_flags(cb, user, 0);
}

LavaMpris *lava_mpris_create_with_flags(LavaMprisUpdateFn cb, void *user,
                                        unsigned flags)
{
  LavaMpris *p = calloc(1, sizeof *p);
  if (p == NULL) return NULL;
  p->cb = cb;
  p->user = user;
  p->cmd_fd = -1;
  p->flags = flags;
  p->volume = 1.0;
  pthread_mutex_init(&p->lock, NULL);
  clear_track(p);

  int r = sd_bus_open_user(&p->bus);
  if (r < 0) {
    fprintf(stderr, "lava_mpris: open session bus failed: %s\n", strerror(-r));
    pthread_mutex_destroy(&p->lock);
    free(p);
    return NULL;
  }
  r = sd_event_new(&p->event);
  if (r < 0) {
    sd_bus_flush_close_unref(p->bus);
    pthread_mutex_destroy(&p->lock);
    free(p);
    return NULL;
  }
  r = sd_bus_attach_event(p->bus, p->event, 0);
  if (r < 0) {
    fail_create(p);
    return NULL;
  }

  p->cmd_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
  if (p->cmd_fd < 0) {
    fail_create(p);
    return NULL;
  }
  r = sd_event_add_io(p->event, NULL, p->cmd_fd, EPOLLIN, on_cmd, p);
  if (r < 0) {
    fail_create(p);
    return NULL;
  }

  uint64_t now = 0;
  if (sd_event_now(p->event, CLOCK_MONOTONIC, &now) >= 0) {
    r = sd_event_add_time(p->event, &p->pos_src, CLOCK_MONOTONIC, now + 1000000,
                          250000, on_pos_timer, p);
    if (r < 0) {
      fprintf(stderr, "lava_mpris: position timer failed: %s\n", strerror(-r));
    }
  }

  r = sd_bus_add_match(
      p->bus, NULL,
      "type='signal',sender='org.freedesktop.DBus',"
      "interface='org.freedesktop.DBus',member='NameOwnerChanged',"
      "arg0namespace='org.mpris.MediaPlayer2'",
      on_name_owner, p);
  if (r < 0) {
    fprintf(stderr, "lava_mpris: NameOwnerChanged match failed: %s\n",
            strerror(-r));
  }
  r = sd_bus_add_match(
      p->bus, NULL,
      "type='signal',sender='org.freedesktop.DBus',"
      "interface='org.freedesktop.DBus',member='NameOwnerChanged',"
      "arg0namespace='rs.spotifyd'",
      on_name_owner, p);
  if (r < 0) {
    fprintf(stderr, "lava_mpris: Controls NameOwnerChanged match failed: %s\n",
            strerror(-r));
  }

  list_names(p);
  pick_player(p);

  if (pthread_create(&p->thread, NULL, loop_thread, p) != 0) {
    fprintf(stderr, "lava_mpris: event thread failed\n");
    fail_create(p);
    return NULL;
  }
  p->thread_started = 1;
  fprintf(stderr, "lava_mpris: session bus connected%s\n",
          (flags & LAVA_MPRIS_SPOTIFYD_ONLY) ? " (spotifyd only)" : "");
  return p;
}

void lava_mpris_destroy(LavaMpris *p)
{
  if (p == NULL) return;
  queue_kind(p, CMD_QUIT);
  if (p->thread_started) pthread_join(p->thread, NULL);
  detach_player(p);
  if (p->pos_src) sd_event_source_unref(p->pos_src);
  if (p->cmd_fd >= 0) close(p->cmd_fd);
  if (p->event) sd_event_unref(p->event);
  if (p->bus) sd_bus_flush_close_unref(p->bus);
  pthread_mutex_destroy(&p->lock);
  free(p);
}

void lava_mpris_next(LavaMpris *p) { queue_kind(p, CMD_NEXT); }
void lava_mpris_previous(LavaMpris *p) { queue_kind(p, CMD_PREV); }
void lava_mpris_play_pause(LavaMpris *p) { queue_kind(p, CMD_PLAYPAUSE); }
void lava_mpris_play(LavaMpris *p) { queue_kind(p, CMD_PLAY); }
void lava_mpris_pause(LavaMpris *p) { queue_kind(p, CMD_PAUSE); }
void lava_mpris_stop(LavaMpris *p) { queue_kind(p, CMD_STOP); }
void lava_mpris_transfer_playback(LavaMpris *p) { queue_kind(p, CMD_TRANSFER); }

void lava_mpris_open_uri(LavaMpris *p, const char *uri)
{
  struct LavaMprisCmd cmd = {.kind = CMD_OPEN_URI};
  copy_str(cmd.str, sizeof cmd.str, uri);
  queue_push(p, cmd);
}

void lava_mpris_seek(LavaMpris *p, int64_t offset_us)
{
  struct LavaMprisCmd cmd = {.kind = CMD_SEEK, .i64 = offset_us};
  queue_push(p, cmd);
}

void lava_mpris_set_position(LavaMpris *p, int64_t position_us)
{
  struct LavaMprisCmd cmd = {.kind = CMD_SET_POSITION, .i64 = position_us};
  queue_push(p, cmd);
}

void lava_mpris_set_volume(LavaMpris *p, double volume)
{
  struct LavaMprisCmd cmd = {.kind = CMD_SET_VOLUME, .dbl = volume};
  queue_push(p, cmd);
}
