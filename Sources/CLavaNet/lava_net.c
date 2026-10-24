#include "lava_net.h"

#include <NetworkManager.h>
#include <nm-secret-agent-old.h>
#include <nm-vpn-plugin-info.h>
#include <libsecret/secret.h>
#include <stdarg.h>
#include <sys/socket.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ─── State ──────────────────────────────────────────────────────────────────

typedef struct {
  char *key;
  char *label;
  char *value;
  int secret;
  int ask;
} Field;

// One GetSecrets NetworkManager is waiting on.
typedef struct {
  uint64_t id;
  NMSecretAgentOld *agent;
  NMConnection *connection;
  char *path;
  char *setting;
  char **hints;
  NMSecretAgentGetSecretsFlags flags;
  NMSecretAgentOldGetSecretsFunc callback;
  gpointer callback_data;
  GPtrArray *fields;
  GCancellable *cancel;
  GSubprocess *dialog;
  int prompted;
} Request;

struct LavaNet {
  LavaNetCallbacks cb;
  void *user;

  GMainContext *ctx;
  GMainLoop *loop;
  GThread *thread;
  GMutex start_lock;
  GCond started;
  int start_done;
  int want_agent;

  NMClient *client;
  NMSecretAgentOld *agent;
  GSList *vpn_plugins;

  // Changes arrive as a burst of `notify`s — a scan is one per access point
  // — and a snapshot per signal would be hundreds a second. One timer
  // collects them.
  GSource *pending;
  // A scan has no "running" property; this is when the last one we asked
  // for was started, and how long to keep saying so.
  gint64 scan_started_ms;
  gint64 scan_until_us;
  GSource *scan_timer;

  GList *requests;
  uint64_t next_request;
  // Connection uuid → when this agent last answered for it. Asked again
  // soon after, with REQUEST_NEW, is what a rejected password looks like.
  GHashTable *answered;
};

// ─── The agent type ─────────────────────────────────────────────────────────

typedef struct {
  NMSecretAgentOld parent;
  LavaNet *net;
} LavaAgent;

typedef struct {
  NMSecretAgentOldClass parent;
} LavaAgentClass;

static GType lava_agent_get_type(void);
G_DEFINE_TYPE(LavaAgent, lava_agent, NM_TYPE_SECRET_AGENT_OLD)

// ─── Small things ───────────────────────────────────────────────────────────

static const char *str(const char *s) { return s ? s : ""; }

static const char *path_of(gpointer object) {
  return object ? str(nm_object_get_path(NM_OBJECT(object))) : "";
}

static void report(LavaNet *n, const char *what, const GError *error) {
  if (error == NULL || n->cb.error == NULL) return;
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) return;
  n->cb.error(n->user, what, error->message);
}

static void schedule_snapshot(LavaNet *n);

static void on_notify(GObject *object, GParamSpec *pspec, gpointer data) {
  (void)object;
  (void)pspec;
  schedule_snapshot(data);
}

static void on_object_signal(gpointer instance, gpointer object, gpointer data) {
  (void)instance;
  (void)object;
  schedule_snapshot(data);
}

static void on_changed(gpointer instance, gpointer data) {
  (void)instance;
  schedule_snapshot(data);
}

// Listen to an object once. The mark lives on the object, so it goes when
// the object does and a recycled address starts unwatched.
static void watch(LavaNet *n, gpointer object) {
  if (object == NULL || g_object_get_data(object, "lava-net-watched")) return;
  g_object_set_data(object, "lava-net-watched", GINT_TO_POINTER(1));
  g_signal_connect(object, "notify", G_CALLBACK(on_notify), n);
  // A saved profile's settings are not properties: an edit, from here or
  // anywhere, arrives as the connection's own "changed".
  if (NM_IS_REMOTE_CONNECTION(object)) {
    g_signal_connect(object, "changed", G_CALLBACK(on_changed), n);
  }
  if (NM_IS_DEVICE_WIFI(object)) {
    g_signal_connect(object, "access-point-added", G_CALLBACK(on_object_signal), n);
    g_signal_connect(object, "access-point-removed", G_CALLBACK(on_object_signal), n);
  }
}

// ─── Snapshot ───────────────────────────────────────────────────────────────

static int security_of(NMAccessPoint *ap) {
  const guint32 flags = nm_access_point_get_flags(ap);
  const guint32 sec = nm_access_point_get_wpa_flags(ap) | nm_access_point_get_rsn_flags(ap);
  if (sec & (NM_802_11_AP_SEC_KEY_MGMT_802_1X | NM_802_11_AP_SEC_KEY_MGMT_EAP_SUITE_B_192))
    return LAVA_NET_SECURITY_ENTERPRISE;
  // A WPA2/WPA3 transition network offers both; a passphrase works on
  // either, and every client can do WPA2.
  if (sec & NM_802_11_AP_SEC_KEY_MGMT_PSK) return LAVA_NET_SECURITY_PSK;
  if (sec & NM_802_11_AP_SEC_KEY_MGMT_SAE) return LAVA_NET_SECURITY_SAE;
  if (sec & (NM_802_11_AP_SEC_KEY_MGMT_OWE | NM_802_11_AP_SEC_KEY_MGMT_OWE_TM))
    return LAVA_NET_SECURITY_OWE;
  if (flags & NM_802_11_AP_FLAGS_PRIVACY) return LAVA_NET_SECURITY_WEP;
  return LAVA_NET_SECURITY_OPEN;
}

static char *ssid_text(GBytes *ssid) {
  if (ssid == NULL) return NULL;
  gsize size = 0;
  const guint8 *data = g_bytes_get_data(ssid, &size);
  if (data == NULL || size == 0) return NULL;
  return nm_utils_ssid_to_utf8(data, size);
}

// Every string in one snapshot, freed together after the callback.
typedef struct {
  GPtrArray *strings;
} Arena;

static const char *keep(Arena *a, char *owned) {
  if (owned == NULL) return "";
  g_ptr_array_add(a->strings, owned);
  return owned;
}

static const char *copy(Arena *a, const char *s) { return keep(a, g_strdup(str(s))); }

static char *first_ip4(NMDevice *device) {
  NMIPConfig *config = nm_device_get_ip4_config(device);
  if (config == NULL) return NULL;
  GPtrArray *addresses = nm_ip_config_get_addresses(config);
  if (addresses == NULL || addresses->len == 0) return NULL;
  NMIPAddress *address = g_ptr_array_index(addresses, 0);
  return g_strdup_printf("%s/%u", nm_ip_address_get_address(address),
                         nm_ip_address_get_prefix(address));
}

static char *first_ip6(NMDevice *device) {
  NMIPConfig *config = nm_device_get_ip6_config(device);
  GPtrArray *addresses = config ? nm_ip_config_get_addresses(config) : NULL;
  for (guint i = 0; addresses && i < addresses->len; i++) {
    NMIPAddress *address = g_ptr_array_index(addresses, i);
    const char *text = nm_ip_address_get_address(address);
    // A link-local address is on every interface and says nothing.
    if (text == NULL || g_str_has_prefix(text, "fe80:")) continue;
    return g_strdup_printf("%s/%u", text, nm_ip_address_get_prefix(address));
  }
  return NULL;
}

static char *joined(const char *const *items) {
  return items ? g_strjoinv(", ", (char **)items) : NULL;
}

static char *ip_addresses(NMSettingIPConfig *ip) {
  GString *out = g_string_new(NULL);
  for (guint i = 0; i < nm_setting_ip_config_get_num_addresses(ip); i++) {
    NMIPAddress *address = nm_setting_ip_config_get_address(ip, i);
    if (out->len) g_string_append(out, ", ");
    g_string_append_printf(out, "%s/%u", nm_ip_address_get_address(address),
                           nm_ip_address_get_prefix(address));
  }
  return g_string_free(out, FALSE);
}

static char *ip_dns(NMSettingIPConfig *ip) {
  GString *out = g_string_new(NULL);
  for (guint i = 0; i < nm_setting_ip_config_get_num_dns(ip); i++) {
    if (out->len) g_string_append(out, ", ");
    g_string_append(out, nm_setting_ip_config_get_dns(ip, i));
  }
  return g_string_free(out, FALSE);
}

// The server a VPN profile connects to. Each plugin names it its own way;
// these are the keys of the ones people have.
static char *remote_of(NMConnection *conn) {
  NMSettingVpn *vpn = nm_connection_get_setting_vpn(conn);
  if (vpn) {
    const char *keys[] = {"remote", "gateway", "server", "host", "address"};
    for (size_t i = 0; i < G_N_ELEMENTS(keys); i++) {
      const char *value = nm_setting_vpn_get_data_item(vpn, keys[i]);
      if (value && value[0]) return g_strdup(value);
    }
    return NULL;
  }
  NMSettingWireGuard *wg = NM_SETTING_WIREGUARD(
      nm_connection_get_setting_by_name(conn, NM_SETTING_WIREGUARD_SETTING_NAME));
  if (wg && nm_setting_wireguard_get_peers_len(wg) > 0) {
    NMWireGuardPeer *peer = nm_setting_wireguard_get_peer(wg, 0);
    return g_strdup(nm_wireguard_peer_get_endpoint(peer));
  }
  return NULL;
}

static int scanning(LavaNet *n) {
  if (g_get_monotonic_time() >= n->scan_until_us) return 0;
  const GPtrArray *devices = nm_client_get_devices(n->client);
  for (guint i = 0; devices && i < devices->len; i++) {
    NMDevice *d = g_ptr_array_index(devices, i);
    if (!NM_IS_DEVICE_WIFI(d)) continue;
    // Finished once every radio has a scan newer than the request.
    if (nm_device_wifi_get_last_scan(NM_DEVICE_WIFI(d)) < n->scan_started_ms) return 1;
  }
  return 0;
}

static void publish(LavaNet *n) {
  if (n->cb.snapshot == NULL || n->client == NULL) return;
  NMClient *c = n->client;
  Arena a = {g_ptr_array_new_with_free_func(g_free)};
  GArray *devices = g_array_new(FALSE, TRUE, sizeof(LavaNetDevice));
  GArray *aps = g_array_new(FALSE, TRUE, sizeof(LavaNetAccessPoint));
  GArray *active = g_array_new(FALSE, TRUE, sizeof(LavaNetActive));
  GArray *saved = g_array_new(FALSE, TRUE, sizeof(LavaNetConnection));

  LavaNetSnapshot snap = {0};
  snap.running = nm_client_get_nm_running(c);
  if (snap.running) {
    snap.networking_enabled = nm_client_networking_get_enabled(c);
    snap.wireless_enabled = nm_client_wireless_get_enabled(c);
    snap.wireless_hardware_enabled = nm_client_wireless_hardware_get_enabled(c);
    snap.state = nm_client_get_state(c);
    snap.connectivity = nm_client_get_connectivity(c);
    snap.primary = copy(&a, path_of(nm_client_get_primary_connection(c)));
    snap.scanning = scanning(n);

    const GPtrArray *list = nm_client_get_devices(c);
    for (guint i = 0; list && i < list->len; i++) {
      NMDevice *d = g_ptr_array_index(list, i);
      watch(n, d);
      if (nm_device_get_ip4_config(d)) watch(n, nm_device_get_ip4_config(d));
      if (nm_device_get_ip6_config(d)) watch(n, nm_device_get_ip6_config(d));
      LavaNetDevice dev = {0};
      dev.path = copy(&a, path_of(d));
      dev.iface = copy(&a, nm_device_get_iface(d));
      const NMDeviceType type = nm_device_get_device_type(d);
      dev.type = type == NM_DEVICE_TYPE_WIFI       ? LAVA_NET_DEVICE_WIFI
                 : type == NM_DEVICE_TYPE_ETHERNET ? LAVA_NET_DEVICE_ETHERNET
                                                   : LAVA_NET_DEVICE_OTHER;
      dev.state = nm_device_get_state(d);
      dev.active_connection = copy(&a, path_of(nm_device_get_active_connection(d)));
      dev.managed = nm_device_get_managed(d);
      dev.ip4 = keep(&a, first_ip4(d));
      NMIPConfig *ip4 = nm_device_get_ip4_config(d);
      dev.ip4_gateway = copy(&a, ip4 ? nm_ip_config_get_gateway(ip4) : "");
      dev.ip4_dns = keep(&a, ip4 ? joined(nm_ip_config_get_nameservers(ip4)) : NULL);
      dev.ip6 = keep(&a, first_ip6(d));
      dev.hw_address = copy(&a, nm_device_get_hw_address(d));
      dev.speed = NM_IS_DEVICE_ETHERNET(d) ? nm_device_ethernet_get_speed(NM_DEVICE_ETHERNET(d)) : 0;
      dev.active_access_point = "";
      if (NM_IS_DEVICE_WIFI(d)) {
        NMDeviceWifi *w = NM_DEVICE_WIFI(d);
        dev.active_access_point = copy(&a, path_of(nm_device_wifi_get_active_access_point(w)));
        const GPtrArray *points = nm_device_wifi_get_access_points(w);
        for (guint k = 0; points && k < points->len; k++) {
          NMAccessPoint *ap = g_ptr_array_index(points, k);
          watch(n, ap);
          char *ssid = ssid_text(nm_access_point_get_ssid(ap));
          // A hidden network has no name to show; joining one is typing
          // its name, which is a settings page, not a list row.
          if (ssid == NULL) continue;
          LavaNetAccessPoint row = {0};
          row.path = copy(&a, path_of(ap));
          row.device = dev.path;
          row.ssid = keep(&a, ssid);
          row.bssid = copy(&a, nm_access_point_get_bssid(ap));
          row.strength = nm_access_point_get_strength(ap);
          row.security = security_of(ap);
          row.frequency = nm_access_point_get_frequency(ap);
          g_array_append_val(aps, row);
        }
      }
      g_array_append_val(devices, dev);
    }

    list = nm_client_get_active_connections(c);
    for (guint i = 0; list && i < list->len; i++) {
      NMActiveConnection *ac = g_ptr_array_index(list, i);
      watch(n, ac);
      LavaNetActive row = {0};
      row.path = copy(&a, path_of(ac));
      row.id = copy(&a, nm_active_connection_get_id(ac));
      row.uuid = copy(&a, nm_active_connection_get_uuid(ac));
      row.type = copy(&a, nm_active_connection_get_connection_type(ac));
      row.state = nm_active_connection_get_state(ac);
      row.vpn = nm_active_connection_get_vpn(ac);
      row.connection = copy(&a, path_of(nm_active_connection_get_connection(ac)));
      row.specific_object = copy(&a, nm_active_connection_get_specific_object_path(ac));
      const GPtrArray *on = nm_active_connection_get_devices(ac);
      row.device = copy(&a, on && on->len > 0 ? path_of(g_ptr_array_index(on, 0)) : "");
      row.is_default = nm_active_connection_get_default(ac);
      NMIPConfig *ip4 = nm_active_connection_get_ip4_config(ac);
      if (ip4) watch(n, ip4);
      GPtrArray *addresses = ip4 ? nm_ip_config_get_addresses(ip4) : NULL;
      row.ip4 = "";
      if (addresses && addresses->len > 0) {
        NMIPAddress *address = g_ptr_array_index(addresses, 0);
        row.ip4 = keep(&a, g_strdup_printf("%s/%u", nm_ip_address_get_address(address),
                                           nm_ip_address_get_prefix(address)));
      }
      g_array_append_val(active, row);
    }

    list = nm_client_get_connections(c);
    for (guint i = 0; list && i < list->len; i++) {
      NMRemoteConnection *rc = g_ptr_array_index(list, i);
      NMConnection *conn = NM_CONNECTION(rc);
      watch(n, rc);
      LavaNetConnection row = {0};
      row.path = copy(&a, path_of(rc));
      row.id = copy(&a, nm_connection_get_id(conn));
      row.uuid = copy(&a, nm_connection_get_uuid(conn));
      row.type = copy(&a, nm_connection_get_connection_type(conn));
      NMSettingWireless *s_wifi = nm_connection_get_setting_wireless(conn);
      row.ssid = s_wifi ? keep(&a, ssid_text(nm_setting_wireless_get_ssid(s_wifi))) : "";
      NMSettingVpn *s_vpn = nm_connection_get_setting_vpn(conn);
      row.vpn_service = copy(&a, s_vpn ? nm_setting_vpn_get_service_type(s_vpn) : "");
      NMSettingConnection *s_con = nm_connection_get_setting_connection(conn);
      row.autoconnect = s_con ? nm_setting_connection_get_autoconnect(s_con) : 0;
      row.timestamp = s_con ? nm_setting_connection_get_timestamp(s_con) : 0;
      NMSettingIPConfig *ip4 = nm_connection_get_setting_ip4_config(conn);
      row.ip4_method = copy(&a, ip4 ? nm_setting_ip_config_get_method(ip4) : "");
      row.ip4_addresses = ip4 ? keep(&a, ip_addresses(ip4)) : "";
      row.ip4_gateway = copy(&a, ip4 ? nm_setting_ip_config_get_gateway(ip4) : "");
      row.ip4_dns = ip4 ? keep(&a, ip_dns(ip4)) : "";
      row.ip4_ignore_auto_dns = ip4 ? nm_setting_ip_config_get_ignore_auto_dns(ip4) : 0;
      row.ip4_never_default = ip4 ? nm_setting_ip_config_get_never_default(ip4) : 0;
      row.remote = keep(&a, remote_of(conn));
      g_array_append_val(saved, row);
    }
  } else {
    snap.primary = "";
  }

  snap.devices = (const LavaNetDevice *)devices->data;
  snap.device_count = devices->len;
  snap.access_points = (const LavaNetAccessPoint *)aps->data;
  snap.access_point_count = aps->len;
  snap.active = (const LavaNetActive *)active->data;
  snap.active_count = active->len;
  snap.connections = (const LavaNetConnection *)saved->data;
  snap.connection_count = saved->len;
  n->cb.snapshot(n->user, &snap);

  g_array_free(devices, TRUE);
  g_array_free(aps, TRUE);
  g_array_free(active, TRUE);
  g_array_free(saved, TRUE);
  g_ptr_array_free(a.strings, TRUE);
}

static gboolean fire_snapshot(gpointer data) {
  LavaNet *n = data;
  g_source_unref(n->pending);
  n->pending = NULL;
  publish(n);
  return G_SOURCE_REMOVE;
}

static void schedule_snapshot(LavaNet *n) {
  if (n->pending != NULL) return;
  n->pending = g_timeout_source_new(60);
  g_source_set_callback(n->pending, fire_snapshot, n, NULL);
  g_source_attach(n->pending, n->ctx);
}

// ─── Commands ───────────────────────────────────────────────────────────────

typedef struct {
  LavaNet *net;
  char *a, *b, *c;
  int flag;
  // `lava_net_update`: the edit, its strings owned here.
  LavaNetEdit edit;
  char *edit_strings[5];
  uint64_t id;
  char **keys;
  char **values;
  size_t count;
} Command;

static void command_free(gpointer data) {
  Command *cmd = data;
  g_free(cmd->a);
  g_free(cmd->b);
  g_free(cmd->c);
  for (size_t i = 0; i < G_N_ELEMENTS(cmd->edit_strings); i++) g_free(cmd->edit_strings[i]);
  if (cmd->values) {
    // A typed password: no copy of it outlives the reply.
    for (size_t i = 0; i < cmd->count; i++) {
      if (cmd->values[i]) memset(cmd->values[i], 0, strlen(cmd->values[i]));
    }
  }
  g_strfreev(cmd->keys);
  g_strfreev(cmd->values);
  g_free(cmd);
}

static Command *command(LavaNet *n, const char *a, const char *b, const char *c) {
  Command *cmd = g_new0(Command, 1);
  cmd->net = n;
  cmd->a = g_strdup(a);
  cmd->b = g_strdup(b);
  cmd->c = g_strdup(c);
  return cmd;
}

static void run(LavaNet *n, GSourceFunc fn, Command *cmd) {
  if (n == NULL || n->ctx == NULL) {
    command_free(cmd);
    return;
  }
  g_main_context_invoke_full(n->ctx, G_PRIORITY_DEFAULT, fn, cmd, command_free);
}

static gpointer object_at(LavaNet *n, const char *path) {
  if (n->client == NULL || path == NULL || path[0] == '\0') return NULL;
  return nm_client_get_object_by_path(n->client, path);
}

static void on_set_property(GObject *source, GAsyncResult *result, gpointer data) {
  GError *error = NULL;
  if (!nm_client_dbus_set_property_finish(NM_CLIENT(source), result, &error)) {
    report(data, "Wi-Fi", error);
    g_error_free(error);
  }
}

static gboolean do_set_wireless(gpointer data) {
  Command *cmd = data;
  LavaNet *n = cmd->net;
  if (n->client == NULL) return G_SOURCE_REMOVE;
  nm_client_dbus_set_property(n->client, NM_DBUS_PATH, NM_DBUS_INTERFACE,
                              "WirelessEnabled", g_variant_new_boolean(cmd->flag != 0),
                              -1, NULL, on_set_property, n);
  return G_SOURCE_REMOVE;
}

static gboolean scan_expired(gpointer data) {
  LavaNet *n = data;
  g_source_unref(n->scan_timer);
  n->scan_timer = NULL;
  schedule_snapshot(n);
  return G_SOURCE_REMOVE;
}

static void on_scan(GObject *source, GAsyncResult *result, gpointer data) {
  (void)data;
  // "Scanning not allowed while already scanning" and the rate limit are
  // NetworkManager agreeing to scan anyway, soon. Nothing to report.
  GError *error = NULL;
  if (!nm_device_wifi_request_scan_finish(NM_DEVICE_WIFI(source), result, &error)) {
    g_error_free(error);
  }
}

static gboolean do_scan(gpointer data) {
  Command *cmd = data;
  LavaNet *n = cmd->net;
  if (n->client == NULL) return G_SOURCE_REMOVE;
  n->scan_started_ms = nm_utils_get_timestamp_msec();
  // Long enough for a dual-band scan; a radio that finishes early clears it.
  n->scan_until_us = g_get_monotonic_time() + 8 * G_USEC_PER_SEC;
  const GPtrArray *devices = nm_client_get_devices(n->client);
  for (guint i = 0; devices && i < devices->len; i++) {
    NMDevice *d = g_ptr_array_index(devices, i);
    if (NM_IS_DEVICE_WIFI(d)) {
      nm_device_wifi_request_scan_async(NM_DEVICE_WIFI(d), NULL, on_scan, n);
    }
  }
  if (n->scan_timer) {
    g_source_destroy(n->scan_timer);
    g_source_unref(n->scan_timer);
  }
  n->scan_timer = g_timeout_source_new(8100);
  g_source_set_callback(n->scan_timer, scan_expired, n, NULL);
  g_source_attach(n->scan_timer, n->ctx);
  schedule_snapshot(n);
  return G_SOURCE_REMOVE;
}

static void on_activated(GObject *source, GAsyncResult *result, gpointer data) {
  GError *error = NULL;
  NMActiveConnection *ac = nm_client_activate_connection_finish(NM_CLIENT(source), result, &error);
  if (ac) g_object_unref(ac);
  if (error) {
    report(data, "Connect", error);
    g_error_free(error);
  }
}

static gboolean do_activate(gpointer data) {
  Command *cmd = data;
  LavaNet *n = cmd->net;
  NMConnection *conn = object_at(n, cmd->a);
  NMDevice *device = object_at(n, cmd->b);
  if (n->client == NULL || !NM_IS_REMOTE_CONNECTION(conn)) return G_SOURCE_REMOVE;
  nm_client_activate_connection_async(
      n->client, conn, NM_IS_DEVICE(device) ? device : NULL,
      cmd->c && cmd->c[0] ? cmd->c : NULL, NULL, on_activated, n);
  return G_SOURCE_REMOVE;
}

static void on_added(GObject *source, GAsyncResult *result, gpointer data) {
  GError *error = NULL;
  NMActiveConnection *ac =
      nm_client_add_and_activate_connection_finish(NM_CLIENT(source), result, &error);
  if (ac) g_object_unref(ac);
  if (error) {
    report(data, "Connect", error);
    g_error_free(error);
  }
}

static gboolean do_connect_ap(gpointer data) {
  Command *cmd = data;
  LavaNet *n = cmd->net;
  NMDevice *device = object_at(n, cmd->a);
  NMAccessPoint *ap = object_at(n, cmd->b);
  if (n->client == NULL || !NM_IS_DEVICE_WIFI(device) || !NM_IS_ACCESS_POINT(ap)) {
    return G_SOURCE_REMOVE;
  }
  const int security = security_of(ap);
  if (security == LAVA_NET_SECURITY_ENTERPRISE) {
    if (n->cb.error) {
      n->cb.error(n->user, "Connect",
                  "This network signs in with an enterprise account, which the "
                  "panel cannot set up yet. nmcli or nm-connection-editor can.");
    }
    return G_SOURCE_REMOVE;
  }
  // Only what the access point cannot tell NetworkManager: which kind of
  // key, and the key when the caller has it. The SSID, the mode and the
  // band are completed from the access point itself.
  NMConnection *partial = NULL;
  if (security != LAVA_NET_SECURITY_OPEN) {
    partial = nm_simple_connection_new();
    NMSetting *s = nm_setting_wireless_security_new();
    const char *km = security == LAVA_NET_SECURITY_SAE   ? "sae"
                     : security == LAVA_NET_SECURITY_OWE ? "owe"
                     : security == LAVA_NET_SECURITY_WEP ? "none"
                                                         : "wpa-psk";
    g_object_set(s, NM_SETTING_WIRELESS_SECURITY_KEY_MGMT, km, NULL);
    if (cmd->c && cmd->c[0]) {
      if (security == LAVA_NET_SECURITY_WEP) {
        g_object_set(s, NM_SETTING_WIRELESS_SECURITY_WEP_KEY0, cmd->c,
                     NM_SETTING_WIRELESS_SECURITY_WEP_KEY_TYPE, NM_WEP_KEY_TYPE_PASSPHRASE,
                     NULL);
      } else if (security != LAVA_NET_SECURITY_OWE) {
        g_object_set(s, NM_SETTING_WIRELESS_SECURITY_PSK, cmd->c, NULL);
      }
    }
    nm_connection_add_setting(partial, s);
  }
  nm_client_add_and_activate_connection_async(n->client, partial, device, path_of(ap),
                                              NULL, on_added, n);
  if (partial) g_object_unref(partial);
  return G_SOURCE_REMOVE;
}

static void on_deactivated(GObject *source, GAsyncResult *result, gpointer data) {
  GError *error = NULL;
  if (!nm_client_deactivate_connection_finish(NM_CLIENT(source), result, &error)) {
    report(data, "Disconnect", error);
    g_error_free(error);
  }
}

static gboolean do_deactivate(gpointer data) {
  Command *cmd = data;
  LavaNet *n = cmd->net;
  NMActiveConnection *ac = object_at(n, cmd->a);
  if (n->client == NULL || !NM_IS_ACTIVE_CONNECTION(ac)) return G_SOURCE_REMOVE;
  nm_client_deactivate_connection_async(n->client, ac, NULL, on_deactivated, n);
  return G_SOURCE_REMOVE;
}

static void on_deleted(GObject *source, GAsyncResult *result, gpointer data) {
  GError *error = NULL;
  if (!nm_remote_connection_delete_finish(NM_REMOTE_CONNECTION(source), result, &error)) {
    report(data, "Forget", error);
    g_error_free(error);
  }
}

static gboolean do_forget(gpointer data) {
  Command *cmd = data;
  LavaNet *n = cmd->net;
  NMRemoteConnection *rc = object_at(n, cmd->a);
  if (!NM_IS_REMOTE_CONNECTION(rc)) return G_SOURCE_REMOVE;
  nm_remote_connection_delete_async(rc, NULL, on_deleted, n);
  return G_SOURCE_REMOVE;
}

// ─── Editing profiles ───────────────────────────────────────────────────────

static void done(LavaNet *n, const char *what, const char *path) {
  if (n->cb.done) n->cb.done(n->user, what, path);
}

static void fail_with(LavaNet *n, const char *what, const char *fmt, ...) G_GNUC_PRINTF(3, 4);
static void fail_with(LavaNet *n, const char *what, const char *fmt, ...) {
  if (n->cb.error == NULL) return;
  va_list args;
  va_start(args, fmt);
  char *message = g_strdup_vprintf(fmt, args);
  va_end(args);
  n->cb.error(n->user, what, message);
  g_free(message);
}

// "a, b c" → {"a", "b", "c"}: what a person types into one field.
static char **words(const char *text) {
  GPtrArray *out = g_ptr_array_new();
  char **parts = g_strsplit_set(str(text), ", \t\n", -1);
  for (char **p = parts; *p; p++) {
    if (**p) g_ptr_array_add(out, g_strdup(*p));
  }
  g_strfreev(parts);
  g_ptr_array_add(out, NULL);
  return (char **)g_ptr_array_free(out, FALSE);
}

// Applies the IPv4 half of an edit. 0 and a message on input NetworkManager
// would refuse anyway, said in words that name the field.
static int apply_ip4(NMConnection *conn, const LavaNetEdit *e, char **message) {
  NMSettingIPConfig *ip = nm_connection_get_setting_ip4_config(conn);
  if (ip == NULL) {
    ip = NM_SETTING_IP_CONFIG(nm_setting_ip4_config_new());
    nm_connection_add_setting(conn, NM_SETTING(ip));
  }
  const int manual = strcmp(e->ip4_method, NM_SETTING_IP4_CONFIG_METHOD_MANUAL) == 0;
  const int disabled = strcmp(e->ip4_method, NM_SETTING_IP4_CONFIG_METHOD_DISABLED) == 0;
  g_object_set(ip, NM_SETTING_IP_CONFIG_METHOD, e->ip4_method, NULL);

  nm_setting_ip_config_clear_addresses(ip);
  if (manual) {
    char **list = words(e->ip4_addresses);
    for (char **p = list; *p; p++) {
      char *slash = strchr(*p, '/');
      guint prefix = 24;
      if (slash) {
        *slash = '\0';
        char *end = NULL;
        const guint64 parsed = g_ascii_strtoull(slash + 1, &end, 10);
        if (end == slash + 1 || *end || parsed < 1 || parsed > 32) {
          *message = g_strdup_printf("“%s/%s” has no valid prefix length (1–32).", *p, slash + 1);
          g_strfreev(list);
          return 0;
        }
        prefix = (guint)parsed;
      }
      GError *error = NULL;
      NMIPAddress *address = nm_ip_address_new(AF_INET, *p, prefix, &error);
      if (address == NULL) {
        *message = g_strdup_printf("“%s” is not an IPv4 address.", *p);
        g_error_free(error);
        g_strfreev(list);
        return 0;
      }
      nm_setting_ip_config_add_address(ip, address);
      nm_ip_address_unref(address);
    }
    g_strfreev(list);
  }

  // A gateway with no address of its own to reach it by is refused, so it
  // goes with the addresses.
  const char *gateway = manual && e->ip4_gateway && e->ip4_gateway[0] ? e->ip4_gateway : NULL;
  if (gateway && !nm_utils_ipaddr_valid(AF_INET, gateway)) {
    *message = g_strdup_printf("The gateway “%s” is not an IPv4 address.", gateway);
    return 0;
  }
  g_object_set(ip, NM_SETTING_IP_CONFIG_GATEWAY, gateway, NULL);

  nm_setting_ip_config_clear_dns(ip);
  if (!disabled) {
    char **list = words(e->ip4_dns);
    for (char **p = list; *p; p++) {
      if (!nm_utils_ipaddr_valid(AF_INET, *p)) {
        *message = g_strdup_printf("The name server “%s” is not an IPv4 address.", *p);
        g_strfreev(list);
        return 0;
      }
      nm_setting_ip_config_add_dns(ip, *p);
    }
    g_strfreev(list);
  }
  if (e->ip4_ignore_auto_dns >= 0) {
    g_object_set(ip, NM_SETTING_IP_CONFIG_IGNORE_AUTO_DNS, e->ip4_ignore_auto_dns != 0, NULL);
  }
  return 1;
}

typedef struct {
  LavaNet *net;
  char *path;
} Pending;

static void on_updated(GObject *source, GAsyncResult *result, gpointer data) {
  Pending *p = data;
  GError *error = NULL;
  GVariant *reply = nm_client_dbus_call_finish(NM_CLIENT(source), result, &error);
  if (reply) {
    g_variant_unref(reply);
    done(p->net, "Save", p->path);
  } else {
    report(p->net, "Save", error);
    g_error_free(error);
  }
  g_free(p->path);
  g_free(p);
}

static gboolean do_update(gpointer data) {
  Command *cmd = data;
  LavaNet *n = cmd->net;
  NMRemoteConnection *rc = object_at(n, cmd->a);
  if (!NM_IS_REMOTE_CONNECTION(rc)) {
    fail_with(n, "Save", "That profile no longer exists.");
    return G_SOURCE_REMOVE;
  }
  const LavaNetEdit *e = &cmd->edit;
  // A copy to change: the remote object is libnm's mirror of what
  // NetworkManager has, and is replaced when the update comes back.
  NMConnection *conn = nm_simple_connection_new_clone(NM_CONNECTION(rc));
  NMSettingConnection *s_con = nm_connection_get_setting_connection(conn);
  if (e->id) {
    char *id = g_strstrip(g_strdup(e->id));
    if (id[0] == '\0') {
      g_free(id);
      g_object_unref(conn);
      fail_with(n, "Save", "A profile needs a name.");
      return G_SOURCE_REMOVE;
    }
    g_object_set(s_con, NM_SETTING_CONNECTION_ID, id, NULL);
    g_free(id);
  }
  if (e->autoconnect >= 0) {
    g_object_set(s_con, NM_SETTING_CONNECTION_AUTOCONNECT, e->autoconnect != 0, NULL);
  }
  char *message = NULL;
  if (e->ip4_method && !apply_ip4(conn, e, &message)) {
    fail_with(n, "Save", "%s", message);
    g_free(message);
    g_object_unref(conn);
    return G_SOURCE_REMOVE;
  }
  if (e->ip4_never_default >= 0) {
    NMSettingIPConfig *ip = nm_connection_get_setting_ip4_config(conn);
    if (ip == NULL) {
      ip = NM_SETTING_IP_CONFIG(nm_setting_ip4_config_new());
      nm_connection_add_setting(conn, NM_SETTING(ip));
    }
    g_object_set(ip, NM_SETTING_IP_CONFIG_NEVER_DEFAULT, e->ip4_never_default != 0, NULL);
  }
  GError *error = NULL;
  if (!nm_connection_verify(conn, &error)) {
    report(n, "Save", error);
    g_error_free(error);
    g_object_unref(conn);
    return G_SOURCE_REMOVE;
  }
  // `Update` rather than libnm's commit, which is `Update2`: the same call
  // with flags this does not need, and the one every NetworkManager and the
  // test mock answer. No secrets go: an update without any keeps the ones
  // NetworkManager holds, and the agent's are in the keyring regardless.
  GVariant *settings = nm_connection_to_dbus(conn, NM_CONNECTION_SERIALIZE_NO_SECRETS);
  Pending *p = g_new0(Pending, 1);
  p->net = n;
  p->path = g_strdup(cmd->a);
  nm_client_dbus_call(n->client, cmd->a, NM_DBUS_INTERFACE_SETTINGS_CONNECTION, "Update",
                      g_variant_new("(@a{sa{sv}})", settings), G_VARIANT_TYPE("()"), 10000,
                      NULL, on_updated, p);
  g_object_unref(conn);
  return G_SOURCE_REMOVE;
}

static void on_imported(GObject *source, GAsyncResult *result, gpointer data) {
  LavaNet *n = data;
  GError *error = NULL;
  NMRemoteConnection *rc = nm_client_add_connection_finish(NM_CLIENT(source), result, &error);
  if (rc) {
    done(n, "Import", path_of(rc));
    g_object_unref(rc);
  } else {
    report(n, "Import", error);
    g_error_free(error);
  }
}

// What `nmcli connection import` does, without being told the type: a
// WireGuard file by its own reader, anything else by whichever installed
// VPN plugin will take it.
static NMConnection *import_file(LavaNet *n, const char *file, char **message) {
  GError *error = NULL;
  NMConnection *conn = NULL;
  char *lower = g_ascii_strdown(file, -1);
  const int wireguard = g_str_has_suffix(lower, ".conf");
  g_free(lower);
  if (wireguard) {
    conn = nm_conn_wireguard_import(file, &error);
    if (conn) return conn;
    *message = g_strdup(error->message);
    g_clear_error(&error);
  }
  if (n->vpn_plugins == NULL) n->vpn_plugins = nm_vpn_plugin_info_list_load();
  // Every plugin that refused, and why: a broken .ovpn should say what is
  // wrong with it, and which plugin is the one that read it is not known
  // until one succeeds.
  GString *why = g_string_new(NULL);
  for (GSList *l = n->vpn_plugins; l && conn == NULL; l = l->next) {
    NMVpnEditorPlugin *editor = nm_vpn_plugin_info_load_editor_plugin(l->data, NULL);
    if (editor == NULL) continue;
    if (!(nm_vpn_editor_plugin_get_capabilities(editor) & NM_VPN_EDITOR_PLUGIN_CAPABILITY_IMPORT))
      continue;
    conn = nm_vpn_editor_plugin_import(editor, file, &error);
    if (conn == NULL && error) {
      g_string_append_printf(why, "%s%s: %s", why->len ? "; " : "",
                             nm_vpn_plugin_info_get_name(l->data), error->message);
    }
    g_clear_error(&error);
  }
  if (conn) {
    g_free(*message);
    *message = NULL;
  } else if (*message == NULL) {
    *message = why->len ? g_strdup(why->str)
                        : g_strdup("No installed VPN plugin can import files. WireGuard files "
                                   "end in .conf; OpenVPN needs networkmanager-openvpn.");
  }
  g_string_free(why, TRUE);
  return conn;
}

static gboolean do_import(gpointer data) {
  Command *cmd = data;
  LavaNet *n = cmd->net;
  if (n->client == NULL) return G_SOURCE_REMOVE;
  char *message = NULL;
  NMConnection *conn = import_file(n, cmd->a, &message);
  if (conn == NULL) {
    fail_with(n, "Import", "%s", message);
    g_free(message);
    return G_SOURCE_REMOVE;
  }
  g_free(message);
  // A plugin's import leaves the name and identity to the caller, as nmcli
  // fills them: the file's name, and a fresh uuid.
  NMSettingConnection *s_con = nm_connection_get_setting_connection(conn);
  if (s_con == NULL) {
    s_con = NM_SETTING_CONNECTION(nm_setting_connection_new());
    nm_connection_add_setting(conn, NM_SETTING(s_con));
  }
  if (nm_setting_connection_get_uuid(s_con) == NULL) {
    char *uuid = nm_utils_uuid_generate();
    g_object_set(s_con, NM_SETTING_CONNECTION_UUID, uuid, NULL);
    g_free(uuid);
  }
  if (nm_setting_connection_get_id(s_con) == NULL) {
    char *base = g_path_get_basename(cmd->a);
    char *dot = strrchr(base, '.');
    if (dot && dot != base) *dot = '\0';
    g_object_set(s_con, NM_SETTING_CONNECTION_ID, base, NULL);
    g_free(base);
  }
  GError *error = NULL;
  if (!nm_connection_normalize(conn, NULL, NULL, &error)) {
    report(n, "Import", error);
    g_error_free(error);
    g_object_unref(conn);
    return G_SOURCE_REMOVE;
  }
  nm_client_add_connection_async(n->client, conn, TRUE, NULL, on_imported, n);
  g_object_unref(conn);
  return G_SOURCE_REMOVE;
}

// ─── Keyring ────────────────────────────────────────────────────────────────

// The schema nm-applet and GNOME Shell file connection secrets under, so a
// password either of them saved is one this finds — and the other way round.
static const SecretSchema *nm_schema(void) {
  static const SecretSchema schema = {
      "org.freedesktop.NetworkManager.Connection",
      SECRET_SCHEMA_DONT_MATCH_NAME,
      {
          {"connection-uuid", SECRET_SCHEMA_ATTRIBUTE_STRING},
          {"setting-name", SECRET_SCHEMA_ATTRIBUTE_STRING},
          {"setting-key", SECRET_SCHEMA_ATTRIBUTE_STRING},
          {NULL, 0},
      },
  };
  return &schema;
}

static char *keyring_lookup(const char *uuid, const char *setting, const char *key) {
  GError *error = NULL;
  char *secret = secret_password_lookup_sync(nm_schema(), NULL, &error, "connection-uuid",
                                             uuid, "setting-name", setting, "setting-key",
                                             key, NULL);
  if (error) {
    fprintf(stderr, "lava_net: keyring lookup failed: %s\n", error->message);
    g_error_free(error);
  }
  if (secret == NULL) return NULL;
  char *out = g_strdup(secret);
  secret_password_free(secret);
  return out;
}

static void keyring_store(NMConnection *conn, const char *setting, const char *key,
                          const char *value) {
  if (value == NULL || value[0] == '\0') return;
  const char *uuid = nm_connection_get_uuid(conn);
  NMSettingVpn *s_vpn = nm_connection_get_setting_vpn(conn);
  // nm-applet's wording, so the two look alike in Seahorse.
  char *label = s_vpn ? g_strdup_printf("VPN %s secret for %s/%s/%s", key,
                                        nm_connection_get_id(conn),
                                        nm_setting_vpn_get_service_type(s_vpn), setting)
                      : g_strdup_printf("Network secret for %s/%s/%s",
                                        nm_connection_get_id(conn), setting, key);
  GError *error = NULL;
  secret_password_store_sync(nm_schema(), SECRET_COLLECTION_DEFAULT, label, value, NULL,
                             &error, "connection-uuid", uuid, "setting-name", setting,
                             "setting-key", key, NULL);
  if (error) {
    fprintf(stderr, "lava_net: keyring store failed: %s\n", error->message);
    g_error_free(error);
  }
  g_free(label);
}

static int agent_owned(NMSetting *setting, const char *key) {
  NMSettingSecretFlags flags = NM_SETTING_SECRET_FLAG_NONE;
  if (setting == NULL || !nm_setting_get_secret_flags(setting, key, &flags, NULL)) return 0;
  return (flags & NM_SETTING_SECRET_FLAG_AGENT_OWNED) != 0;
}

// ─── Requests ───────────────────────────────────────────────────────────────

static void field_free(gpointer data) {
  Field *f = data;
  if (f->value) memset(f->value, 0, strlen(f->value));
  g_free(f->key);
  g_free(f->label);
  g_free(f->value);
  g_free(f);
}

static void add_field(Request *r, const char *key, const char *label, const char *value,
                      int secret, int ask) {
  Field *f = g_new0(Field, 1);
  f->key = g_strdup(key);
  f->label = g_strdup(label && label[0] ? label : key);
  f->value = g_strdup(str(value));
  f->secret = secret;
  f->ask = ask;
  g_ptr_array_add(r->fields, f);
}

static void request_free(Request *r) {
  if (r->cancel) {
    g_cancellable_cancel(r->cancel);
    g_object_unref(r->cancel);
  }
  if (r->dialog) {
    g_subprocess_force_exit(r->dialog);
    g_object_unref(r->dialog);
  }
  g_ptr_array_free(r->fields, TRUE);
  g_object_unref(r->connection);
  g_free(r->path);
  g_free(r->setting);
  g_strfreev(r->hints);
  g_free(r);
}

static LavaNet *net_of(Request *r) { return ((LavaAgent *)r->agent)->net; }

static Request *find_request(LavaNet *n, uint64_t id) {
  for (GList *l = n->requests; l; l = l->next) {
    Request *r = l->data;
    if (r->id == id) return r;
  }
  return NULL;
}

static void take_down(Request *r) {
  LavaNet *n = net_of(r);
  n->requests = g_list_remove(n->requests, r);
  if (r->prompted && n->cb.secret_cancelled) n->cb.secret_cancelled(n->user, r->id);
  request_free(r);
}

static void finish(Request *r, GVariant *secrets) {
  LavaNet *n = net_of(r);
  n->requests = g_list_remove(n->requests, r);
  r->callback(r->agent, r->connection, secrets, NULL, r->callback_data);
  request_free(r);
}

static void fail(Request *r, NMSecretAgentError code, const char *fmt, ...) {
  va_list args;
  va_start(args, fmt);
  char *message = g_strdup_vprintf(fmt, args);
  va_end(args);
  GError *error = g_error_new_literal(NM_SECRET_AGENT_ERROR, code, message);
  g_free(message);
  LavaNet *n = net_of(r);
  n->requests = g_list_remove(n->requests, r);
  if (r->prompted && n->cb.secret_cancelled) n->cb.secret_cancelled(n->user, r->id);
  r->callback(r->agent, r->connection, NULL, error, r->callback_data);
  g_error_free(error);
  request_free(r);
}

// `{setting: {key: value}}`, or for a VPN `{"vpn": {"secrets": {key: value}}}`.
static GVariant *secrets_variant(Request *r) {
  GVariantBuilder inner;
  g_variant_builder_init(&inner, G_VARIANT_TYPE("a{sv}"));
  if (strcmp(r->setting, NM_SETTING_VPN_SETTING_NAME) == 0) {
    GVariantBuilder map;
    g_variant_builder_init(&map, G_VARIANT_TYPE("a{ss}"));
    for (guint i = 0; i < r->fields->len; i++) {
      Field *f = g_ptr_array_index(r->fields, i);
      if (f->value && f->value[0]) g_variant_builder_add(&map, "{ss}", f->key, f->value);
    }
    g_variant_builder_add(&inner, "{sv}", NM_SETTING_VPN_SECRETS,
                          g_variant_builder_end(&map));
  } else {
    for (guint i = 0; i < r->fields->len; i++) {
      Field *f = g_ptr_array_index(r->fields, i);
      if (f->value && f->value[0]) {
        g_variant_builder_add(&inner, "{sv}", f->key, g_variant_new_string(f->value));
      }
    }
  }
  GVariantBuilder outer;
  g_variant_builder_init(&outer, NM_VARIANT_TYPE_CONNECTION);
  g_variant_builder_add(&outer, "{sa{sv}}", r->setting, &inner);
  return g_variant_builder_end(&outer);
}

// What the user typed, kept in the keyring when the connection says the
// agent owns it — "saved for this user only", nm-applet's default.
// NetworkManager does not ask for that save; the agent that asked is the
// one that keeps it, as GNOME Shell's does.
static void keep_owned(Request *r) {
  NMSetting *setting = nm_connection_get_setting_by_name(r->connection, r->setting);
  for (guint i = 0; i < r->fields->len; i++) {
    Field *f = g_ptr_array_index(r->fields, i);
    if (f->ask && f->secret && agent_owned(setting, f->key)) {
      keyring_store(r->connection, r->setting, f->key, f->value);
    }
  }
}

static void answer(Request *r) {
  keep_owned(r);
  g_hash_table_insert(net_of(r)->answered,
                      g_strdup_printf("%s@", nm_connection_get_uuid(r->connection)),
                      GSIZE_TO_POINTER((gsize)(g_get_monotonic_time() / G_USEC_PER_SEC)));
  GVariant *secrets = g_variant_ref_sink(secrets_variant(r));
  finish(r, secrets);
  g_variant_unref(secrets);
}

static void prompt(Request *r, const char *title, const char *message) {
  LavaNet *n = net_of(r);
  if (n->cb.secret_request == NULL) {
    fail(r, NM_SECRET_AGENT_ERROR_NO_SECRETS, "Nothing to ask the user with");
    return;
  }
  LavaNetSecretField *fields = g_new0(LavaNetSecretField, r->fields->len ? r->fields->len : 1);
  for (guint i = 0; i < r->fields->len; i++) {
    Field *f = g_ptr_array_index(r->fields, i);
    fields[i] = (LavaNetSecretField){f->key, f->label, f->value, f->secret, f->ask};
  }
  LavaNetSecretRequest request = {
      .id = r->id,
      .connection = str(nm_connection_get_id(r->connection)),
      .title = title,
      .message = message,
      .fields = fields,
      .field_count = r->fields->len,
  };
  r->prompted = 1;
  n->cb.secret_request(n->user, &request);
  g_free(fields);
}

// ─── Wi-Fi secrets ──────────────────────────────────────────────────────────

static int recently_answered(LavaNet *n, const char *uuid) {
  char *key = g_strdup_printf("%s@", str(uuid));
  gpointer at = g_hash_table_lookup(n->answered, key);
  g_free(key);
  const gsize now = (gsize)(g_get_monotonic_time() / G_USEC_PER_SEC);
  return at != NULL && now - GPOINTER_TO_SIZE(at) < 60;
}

static void wifi_secrets(Request *r) {
  NMSettingWirelessSecurity *s = nm_connection_get_setting_wireless_security(r->connection);
  const char *km = s ? nm_setting_wireless_security_get_key_mgmt(s) : NULL;
  char key[16] = "psk";
  if (km && (strcmp(km, "wpa-psk") == 0 || strcmp(km, "sae") == 0)) {
    // "psk" already.
  } else if (km && strcmp(km, "none") == 0) {
    snprintf(key, sizeof key, "wep-key%u", nm_setting_wireless_security_get_wep_tx_keyidx(s));
  } else {
    fail(r, NM_SECRET_AGENT_ERROR_NO_SECRETS,
         "This network needs an enterprise login, which the panel cannot ask for yet");
    return;
  }

  const int fresh = (r->flags & NM_SECRET_AGENT_GET_SECRETS_FLAG_REQUEST_NEW) != 0;
  if (!fresh && agent_owned(NM_SETTING(s), key)) {
    char *saved = keyring_lookup(nm_connection_get_uuid(r->connection), r->setting, key);
    if (saved) {
      add_field(r, key, "Password", saved, 1, 0);
      memset(saved, 0, strlen(saved));
      g_free(saved);
      answer(r);
      return;
    }
  }
  if (!(r->flags & NM_SECRET_AGENT_GET_SECRETS_FLAG_ALLOW_INTERACTION)) {
    fail(r, NM_SECRET_AGENT_ERROR_NO_SECRETS, "No saved password, and no asking allowed");
    return;
  }

  NMSettingWireless *s_wifi = nm_connection_get_setting_wireless(r->connection);
  char *ssid = s_wifi ? ssid_text(nm_setting_wireless_get_ssid(s_wifi)) : NULL;
  const char *name = ssid ? ssid : str(nm_connection_get_id(r->connection));
  add_field(r, key, "Password", "", 1, 1);
  // Asked again with REQUEST_NEW, soon after this agent answered, is what a
  // wrong password looks like from here: the association failed and
  // NetworkManager wants another.
  char *message = fresh && recently_answered(net_of(r), nm_connection_get_uuid(r->connection))
                      ? g_strdup_printf("The password for “%s” was not accepted. Try again.", name)
                      : g_strdup_printf("Type the password for “%s”.", name);
  prompt(r, "Wi-Fi network", message);
  g_free(message);
  g_free(ssid);
}

// ─── VPN secrets ────────────────────────────────────────────────────────────

static void add_data(const char *key, const char *value, gpointer data) {
  g_string_append_printf(data, "DATA_KEY=%s\nDATA_VAL=%s\n\n", key, value);
}

// `password-flags=1`: a `<key>-flags` item with the agent-owned bit.
static void note_owned(const char *key, const char *value, gpointer data) {
  if (!g_str_has_suffix(key, "-flags")) return;
  const guint64 flags = g_ascii_strtoull(value, NULL, 10);
  if (flags & NM_SETTING_SECRET_FLAG_AGENT_OWNED) *(int *)data = 1;
}

static void add_secret(const char *key, const char *value, gpointer data) {
  g_string_append_printf(data, "SECRET_KEY=%s\nSECRET_VAL=%s\n\n", key, value);
}

typedef struct {
  LavaNet *net;
  uint64_t id;
} DialogTicket;

// The plugin's auth dialog, run with --external-ui-mode, describes the form
// as a key file: a `[VPN Plugin UI]` group with a title and a description,
// and a group per secret with its label and whether it must be asked.
// Drawing the form is then ours — the same split GNOME Shell makes, and the
// reason a GTK dialog never appears from the panel.
static void on_dialog(GObject *source, GAsyncResult *result, gpointer data) {
  DialogTicket *ticket = data;
  LavaNet *n = ticket->net;
  Request *r = find_request(n, ticket->id);
  g_free(ticket);
  char *out = NULL;
  GError *error = NULL;
  const gboolean ok =
      g_subprocess_communicate_utf8_finish(G_SUBPROCESS(source), result, &out, NULL, &error);
  if (r == NULL) {
    // Cancelled while the dialog ran.
    g_free(out);
    if (error) g_error_free(error);
    return;
  }
  if (!ok) {
    fail(r, NM_SECRET_AGENT_ERROR_FAILED, "The VPN plugin's dialog failed: %s",
         error ? error->message : "no output");
    g_error_free(error);
    return;
  }

  GKeyFile *kf = g_key_file_new();
  if (out == NULL || !g_key_file_load_from_data(kf, out, (gsize)-1, G_KEY_FILE_NONE, &error)) {
    fail(r, NM_SECRET_AGENT_ERROR_FAILED, "The VPN plugin's dialog said nothing usable%s%s",
         error ? ": " : "", error ? error->message : "");
    if (error) g_error_free(error);
    g_key_file_unref(kf);
    if (out) memset(out, 0, strlen(out));
    g_free(out);
    return;
  }
  if (out) memset(out, 0, strlen(out));
  g_free(out);

  const char *ui = "VPN Plugin UI";
  char *title = g_key_file_get_string(kf, ui, "Title", NULL);
  char *message = g_key_file_get_string(kf, ui, "Description", NULL);
  gsize count = 0;
  char **groups = g_key_file_get_groups(kf, &count);
  int asks = 0;
  for (gsize i = 0; i < count; i++) {
    if (strcmp(groups[i], ui) == 0) continue;
    char *label = g_key_file_get_string(kf, groups[i], "Label", NULL);
    char *value = g_key_file_get_string(kf, groups[i], "Value", NULL);
    const int secret = g_key_file_get_boolean(kf, groups[i], "IsSecret", NULL);
    const int ask = g_key_file_get_boolean(kf, groups[i], "ShouldAsk", NULL);
    add_field(r, groups[i], label, value, secret, ask);
    asks += ask;
    g_free(label);
    if (value) memset(value, 0, strlen(value));
    g_free(value);
  }
  g_strfreev(groups);
  g_key_file_unref(kf);

  if (asks == 0) {
    answer(r);
  } else if (!(r->flags & NM_SECRET_AGENT_GET_SECRETS_FLAG_ALLOW_INTERACTION)) {
    fail(r, NM_SECRET_AGENT_ERROR_NO_SECRETS, "The VPN needs input, and no asking allowed");
  } else {
    prompt(r, title ? title : "VPN", message ? message : "");
  }
  g_free(title);
  g_free(message);
}

static void vpn_secrets(Request *r) {
  LavaNet *n = net_of(r);
  NMSettingVpn *s = nm_connection_get_setting_vpn(r->connection);
  const char *service = s ? nm_setting_vpn_get_service_type(s) : NULL;
  if (n->vpn_plugins == NULL) n->vpn_plugins = nm_vpn_plugin_info_list_load();
  NMVpnPluginInfo *info =
      service ? nm_vpn_plugin_info_list_find_by_service(n->vpn_plugins, service) : NULL;
  const char *dialog = info ? nm_vpn_plugin_info_lookup_property(info, "GNOME", "auth-dialog") : NULL;
  const char *external =
      info ? nm_vpn_plugin_info_lookup_property(info, "GNOME", "supports-external-ui-mode") : NULL;
  if (dialog == NULL || external == NULL || g_ascii_strcasecmp(external, "true") != 0) {
    fail(r, NM_SECRET_AGENT_ERROR_NO_SECRETS,
         "The VPN plugin %s cannot ask through the panel", str(service));
    return;
  }
  const char *hinting = nm_vpn_plugin_info_lookup_property(info, "GNOME", "supports-hints");
  const int hints_ok = hinting && g_ascii_strcasecmp(hinting, "true") == 0;

  GPtrArray *argv = g_ptr_array_new();
  g_ptr_array_add(argv, (char *)dialog);
  g_ptr_array_add(argv, "-u");
  g_ptr_array_add(argv, (char *)nm_connection_get_uuid(r->connection));
  g_ptr_array_add(argv, "-n");
  g_ptr_array_add(argv, (char *)nm_connection_get_id(r->connection));
  g_ptr_array_add(argv, "-s");
  g_ptr_array_add(argv, (char *)service);
  g_ptr_array_add(argv, "--external-ui-mode");
  if (r->flags & NM_SECRET_AGENT_GET_SECRETS_FLAG_ALLOW_INTERACTION) g_ptr_array_add(argv, "-i");
  if (r->flags & NM_SECRET_AGENT_GET_SECRETS_FLAG_REQUEST_NEW) g_ptr_array_add(argv, "-r");
  for (char **h = r->hints; hints_ok && h && *h; h++) {
    g_ptr_array_add(argv, "-t");
    g_ptr_array_add(argv, *h);
  }
  g_ptr_array_add(argv, NULL);

  // The connection's data and every secret already known — NetworkManager's
  // own, then the keyring's — so the dialog asks only for what is missing.
  GString *input = g_string_new(NULL);
  nm_setting_vpn_foreach_data_item(s, add_data, input);
  nm_setting_vpn_foreach_secret(s, add_secret, input);
  // Only a VPN with a secret this user owns has anything in the keyring;
  // the rest are NetworkManager's own or asked every time.
  int owns = 0;
  nm_setting_vpn_foreach_data_item(s, note_owned, &owns);
  if (owns && !(r->flags & NM_SECRET_AGENT_GET_SECRETS_FLAG_REQUEST_NEW)) {
    GError *error = NULL;
    GList *items = secret_password_search_sync(
        nm_schema(), SECRET_SEARCH_ALL | SECRET_SEARCH_UNLOCK | SECRET_SEARCH_LOAD_SECRETS, NULL,
        &error, "connection-uuid", nm_connection_get_uuid(r->connection), "setting-name",
        NM_SETTING_VPN_SETTING_NAME, NULL);
    if (error) {
      fprintf(stderr, "lava_net: keyring search failed: %s\n", error->message);
      g_error_free(error);
    }
    for (GList *l = items; l; l = l->next) {
      SecretRetrievable *item = l->data;
      GHashTable *attrs = secret_retrievable_get_attributes(item);
      const char *key = attrs ? g_hash_table_lookup(attrs, "setting-key") : NULL;
      SecretValue *value = secret_retrievable_retrieve_secret_sync(item, NULL, NULL);
      const char *text = value ? secret_value_get_text(value) : NULL;
      if (key && text) add_secret(key, text, input);
      if (value) secret_value_unref(value);
      if (attrs) g_hash_table_unref(attrs);
    }
    g_list_free_full(items, g_object_unref);
  }
  g_string_append(input, "DONE\n\n");

  GError *error = NULL;
  r->dialog = g_subprocess_newv((const char *const *)argv->pdata,
                                G_SUBPROCESS_FLAGS_STDIN_PIPE | G_SUBPROCESS_FLAGS_STDOUT_PIPE,
                                &error);
  g_ptr_array_free(argv, TRUE);
  if (r->dialog == NULL) {
    memset(input->str, 0, input->len);
    g_string_free(input, TRUE);
    fail(r, NM_SECRET_AGENT_ERROR_FAILED, "Could not start the VPN plugin's dialog: %s",
         error->message);
    g_error_free(error);
    return;
  }
  DialogTicket *ticket = g_new0(DialogTicket, 1);
  ticket->net = n;
  ticket->id = r->id;
  g_subprocess_communicate_utf8_async(r->dialog, input->str, r->cancel, on_dialog, ticket);
  memset(input->str, 0, input->len);
  g_string_free(input, TRUE);
}

// ─── Agent vfuncs ───────────────────────────────────────────────────────────

static void agent_get_secrets(NMSecretAgentOld *agent, NMConnection *connection,
                              const char *path, const char *setting, const char **hints,
                              NMSecretAgentGetSecretsFlags flags,
                              NMSecretAgentOldGetSecretsFunc callback, gpointer data) {
  LavaNet *n = ((LavaAgent *)agent)->net;
  Request *r = g_new0(Request, 1);
  r->id = ++n->next_request;
  r->agent = agent;
  r->connection = g_object_ref(connection);
  r->path = g_strdup(path);
  r->setting = g_strdup(setting);
  r->hints = g_strdupv((char **)hints);
  r->flags = flags;
  r->callback = callback;
  r->callback_data = data;
  r->fields = g_ptr_array_new_with_free_func(field_free);
  r->cancel = g_cancellable_new();
  n->requests = g_list_append(n->requests, r);

  if (strcmp(setting, NM_SETTING_WIRELESS_SECURITY_SETTING_NAME) == 0) {
    wifi_secrets(r);
  } else if (strcmp(setting, NM_SETTING_VPN_SETTING_NAME) == 0) {
    vpn_secrets(r);
  } else {
    fail(r, NM_SECRET_AGENT_ERROR_NO_SECRETS, "The panel cannot ask for %s secrets", setting);
  }
}

static void agent_cancel_get_secrets(NMSecretAgentOld *agent, const char *path,
                                     const char *setting) {
  LavaNet *n = ((LavaAgent *)agent)->net;
  for (GList *l = n->requests; l;) {
    Request *r = l->data;
    l = l->next;
    // Since libnm 1.24 a cancelled request's callback may be left uncalled.
    if (g_strcmp0(r->path, path) == 0 && g_strcmp0(r->setting, setting) == 0) take_down(r);
  }
}

static void save_owned_vpn(const char *key, const char *value, gpointer data) {
  NMConnection *conn = data;
  if (agent_owned(NM_SETTING(nm_connection_get_setting_vpn(conn)), key)) {
    keyring_store(conn, NM_SETTING_VPN_SETTING_NAME, key, value);
  }
}

// An editor saved the connection with secrets this user owns: keep them.
static void agent_save_secrets(NMSecretAgentOld *agent, NMConnection *connection,
                               const char *path, NMSecretAgentOldSaveSecretsFunc callback,
                               gpointer data) {
  (void)path;
  NMSettingWirelessSecurity *s_wsec = nm_connection_get_setting_wireless_security(connection);
  if (s_wsec && agent_owned(NM_SETTING(s_wsec), NM_SETTING_WIRELESS_SECURITY_PSK)) {
    keyring_store(connection, NM_SETTING_WIRELESS_SECURITY_SETTING_NAME,
                  NM_SETTING_WIRELESS_SECURITY_PSK, nm_setting_wireless_security_get_psk(s_wsec));
  }
  NMSettingVpn *s_vpn = nm_connection_get_setting_vpn(connection);
  if (s_vpn) nm_setting_vpn_foreach_secret(s_vpn, save_owned_vpn, connection);
  callback(agent, connection, NULL, data);
}

static void agent_delete_secrets(NMSecretAgentOld *agent, NMConnection *connection,
                                 const char *path, NMSecretAgentOldDeleteSecretsFunc callback,
                                 gpointer data) {
  (void)path;
  GError *error = NULL;
  secret_password_clear_sync(nm_schema(), NULL, &error, "connection-uuid",
                             nm_connection_get_uuid(connection), NULL);
  if (error) {
    fprintf(stderr, "lava_net: keyring clear failed: %s\n", error->message);
    g_error_free(error);
  }
  callback(agent, connection, NULL, data);
}

static void lava_agent_init(LavaAgent *self) { (void)self; }

static void lava_agent_class_init(LavaAgentClass *klass) {
  NMSecretAgentOldClass *agent = NM_SECRET_AGENT_OLD_CLASS(klass);
  agent->get_secrets = agent_get_secrets;
  agent->cancel_get_secrets = agent_cancel_get_secrets;
  agent->save_secrets = agent_save_secrets;
  agent->delete_secrets = agent_delete_secrets;
}

// ─── Replies from the user ──────────────────────────────────────────────────

static gboolean do_reply(gpointer data) {
  Command *cmd = data;
  Request *r = find_request(cmd->net, cmd->id);
  if (r == NULL) return G_SOURCE_REMOVE;  // NetworkManager gave up meanwhile.
  for (size_t i = 0; i < cmd->count; i++) {
    for (guint k = 0; k < r->fields->len; k++) {
      Field *f = g_ptr_array_index(r->fields, k);
      if (strcmp(f->key, cmd->keys[i]) != 0) continue;
      if (f->value) memset(f->value, 0, strlen(f->value));
      g_free(f->value);
      f->value = g_strdup(cmd->values[i]);
    }
  }
  // The prompt is already down: the user's own click took it.
  r->prompted = 0;
  answer(r);
  return G_SOURCE_REMOVE;
}

static gboolean do_cancel(gpointer data) {
  Command *cmd = data;
  Request *r = find_request(cmd->net, cmd->id);
  if (r == NULL) return G_SOURCE_REMOVE;
  r->prompted = 0;
  fail(r, NM_SECRET_AGENT_ERROR_USER_CANCELED, "Cancelled");
  return G_SOURCE_REMOVE;
}

// ─── Lifetime ───────────────────────────────────────────────────────────────

static void on_client_signal(NMClient *client, gpointer object, gpointer data) {
  (void)client;
  (void)object;
  schedule_snapshot(data);
}

static void on_agent_ready(GObject *source, GAsyncResult *result, gpointer data) {
  (void)data;
  GError *error = NULL;
  if (!g_async_initable_init_finish(G_ASYNC_INITABLE(source), result, &error)) {
    // Not fatal: auto-register goes on trying whenever NetworkManager
    // comes back. Without an agent, saved and system secrets still work.
    fprintf(stderr, "lava_net: secret agent: %s\n", error->message);
    g_error_free(error);
  }
}

static gpointer thread_main(gpointer data) {
  LavaNet *n = data;
  g_main_context_push_thread_default(n->ctx);

  GError *error = NULL;
  n->client = nm_client_new(NULL, &error);
  if (n->client == NULL) {
    fprintf(stderr, "lava_net: no NetworkManager client: %s\n", error->message);
    g_clear_error(&error);
  } else {
    g_signal_connect(n->client, "notify", G_CALLBACK(on_notify), n);
    const char *signals[] = {"device-added", "device-removed", "active-connection-added",
                             "active-connection-removed", "connection-added",
                             "connection-removed"};
    for (size_t i = 0; i < G_N_ELEMENTS(signals); i++) {
      g_signal_connect(n->client, signals[i], G_CALLBACK(on_client_signal), n);
    }
    // `LAVA_NET_AGENT=0` for a second panel beside a running one: an
    // identifier is one agent per user, and the newer would take over.
    const char *agent_env = g_getenv("LAVA_NET_AGENT");
    if (n->want_agent && (agent_env == NULL || strcmp(agent_env, "0") != 0)) {
      // Initialised asynchronously, on this loop. The synchronous init
      // waits on a context of its own that nothing here iterates, and never
      // returns; and the back-pointer has to be there before NetworkManager
      // can ask anything, which constructing first and initialising after
      // guarantees.
      n->agent = g_object_new(lava_agent_get_type(), NM_SECRET_AGENT_OLD_IDENTIFIER,
                              "org.lava.panel", NM_SECRET_AGENT_OLD_CAPABILITIES,
                              NM_SECRET_AGENT_CAPABILITY_VPN_HINTS,
                              NM_SECRET_AGENT_OLD_AUTO_REGISTER, TRUE, NULL);
      ((LavaAgent *)n->agent)->net = n;
      g_async_initable_init_async(G_ASYNC_INITABLE(n->agent), G_PRIORITY_DEFAULT, NULL,
                                  on_agent_ready, n);
    }
    schedule_snapshot(n);
  }

  g_mutex_lock(&n->start_lock);
  n->start_done = 1;
  g_cond_signal(&n->started);
  g_mutex_unlock(&n->start_lock);

  g_main_loop_run(n->loop);

  while (n->requests) take_down(n->requests->data);
  if (n->pending) {
    g_source_destroy(n->pending);
    g_source_unref(n->pending);
    n->pending = NULL;
  }
  if (n->scan_timer) {
    g_source_destroy(n->scan_timer);
    g_source_unref(n->scan_timer);
    n->scan_timer = NULL;
  }
  if (n->agent) {
    nm_secret_agent_old_destroy(n->agent);
    g_object_unref(n->agent);
    n->agent = NULL;
  }
  if (n->client) {
    g_signal_handlers_disconnect_by_data(n->client, n);
    g_object_unref(n->client);
    n->client = NULL;
  }
  // Let libnm's own teardown run on the context it was created on.
  while (g_main_context_iteration(n->ctx, FALSE)) {
  }
  g_main_context_pop_thread_default(n->ctx);
  return NULL;
}

LavaNet *lava_net_create(const LavaNetCallbacks *callbacks, void *user, int agent) {
  LavaNet *n = g_new0(LavaNet, 1);
  if (callbacks) n->cb = *callbacks;
  n->user = user;
  n->answered = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  n->ctx = g_main_context_new();
  n->loop = g_main_loop_new(n->ctx, FALSE);
  g_mutex_init(&n->start_lock);
  g_cond_init(&n->started);
  n->want_agent = agent != 0;
  n->thread = g_thread_new("lava-net", thread_main, n);
  // Until the client exists a command has nothing to act on.
  g_mutex_lock(&n->start_lock);
  while (!n->start_done) g_cond_wait(&n->started, &n->start_lock);
  g_mutex_unlock(&n->start_lock);
  return n;
}

static gboolean do_quit(gpointer data) {
  g_main_loop_quit(data);
  return G_SOURCE_REMOVE;
}

void lava_net_destroy(LavaNet *n) {
  if (n == NULL) return;
  g_main_context_invoke(n->ctx, do_quit, n->loop);
  g_thread_join(n->thread);
  g_slist_free_full(n->vpn_plugins, g_object_unref);
  g_hash_table_unref(n->answered);
  g_main_loop_unref(n->loop);
  g_main_context_unref(n->ctx);
  g_mutex_clear(&n->start_lock);
  g_cond_clear(&n->started);
  g_free(n);
}

void lava_net_set_wireless_enabled(LavaNet *n, int enabled) {
  Command *cmd = command(n, NULL, NULL, NULL);
  cmd->flag = enabled;
  run(n, do_set_wireless, cmd);
}

void lava_net_request_scan(LavaNet *n) { run(n, do_scan, command(n, NULL, NULL, NULL)); }

void lava_net_activate(LavaNet *n, const char *connection, const char *device,
                       const char *specific_object) {
  run(n, do_activate, command(n, connection, device, specific_object));
}

void lava_net_connect_access_point(LavaNet *n, const char *device, const char *access_point,
                                   const char *password) {
  run(n, do_connect_ap, command(n, device, access_point, password));
}

void lava_net_deactivate(LavaNet *n, const char *active) {
  run(n, do_deactivate, command(n, active, NULL, NULL));
}

void lava_net_forget(LavaNet *n, const char *connection) {
  run(n, do_forget, command(n, connection, NULL, NULL));
}

void lava_net_update(LavaNet *n, const char *connection, const LavaNetEdit *edit) {
  Command *cmd = command(n, connection, NULL, NULL);
  if (edit) {
    cmd->edit = *edit;
    const char **fields[] = {&cmd->edit.id, &cmd->edit.ip4_method, &cmd->edit.ip4_addresses,
                             &cmd->edit.ip4_gateway, &cmd->edit.ip4_dns};
    for (size_t i = 0; i < G_N_ELEMENTS(fields); i++) {
      cmd->edit_strings[i] = g_strdup(*fields[i]);
      *fields[i] = cmd->edit_strings[i];
    }
  } else {
    cmd->edit.autoconnect = cmd->edit.ip4_ignore_auto_dns = cmd->edit.ip4_never_default = -1;
  }
  run(n, do_update, cmd);
}

void lava_net_import(LavaNet *n, const char *file) {
  run(n, do_import, command(n, file, NULL, NULL));
}

void lava_net_secret_reply(LavaNet *n, uint64_t id, const char *const *keys,
                           const char *const *values, size_t count) {
  Command *cmd = command(n, NULL, NULL, NULL);
  cmd->id = id;
  cmd->count = count;
  cmd->keys = g_new0(char *, count + 1);
  cmd->values = g_new0(char *, count + 1);
  for (size_t i = 0; i < count; i++) {
    cmd->keys[i] = g_strdup(keys[i]);
    cmd->values[i] = g_strdup(values[i]);
  }
  run(n, do_reply, cmd);
}

void lava_net_secret_cancel(LavaNet *n, uint64_t id) {
  Command *cmd = command(n, NULL, NULL, NULL);
  cmd->id = id;
  run(n, do_cancel, cmd);
}

// ─── Test entry ─────────────────────────────────────────────────────────────

typedef struct {
  LavaNetTestDone done;
  void *user;
} TestTicket;

static void test_answered(NMSecretAgentOld *agent, NMConnection *connection, GVariant *secrets,
                          GError *error, gpointer data) {
  (void)agent;
  (void)connection;
  TestTicket *ticket = data;
  char *out;
  if (error) {
    char *name = g_dbus_error_encode_gerror(error);
    out = g_strdup_printf("error %s: %s", name, error->message);
    g_free(name);
  } else {
    out = g_variant_print(secrets, FALSE);
  }
  ticket->done(ticket->user, out);
  g_free(out);
  g_free(ticket);
}

static gboolean do_test_get(gpointer data) {
  Command *cmd = data;
  LavaNet *n = cmd->net;
  TestTicket *ticket = (TestTicket *)(gsize)cmd->id;
  GError *error = NULL;
  GVariant *v = n->agent ? g_variant_parse(NM_VARIANT_TYPE_CONNECTION, cmd->a, NULL, NULL, &error)
                         : NULL;
  NMConnection *conn = v ? nm_simple_connection_new_from_dbus(v, &error) : NULL;
  if (conn == NULL) {
    char *out = g_strdup_printf("error parse: %s", error ? error->message : "no agent");
    ticket->done(ticket->user, out);
    g_free(out);
    g_free(ticket);
  } else {
    agent_get_secrets(n->agent, conn, "/org/freedesktop/NetworkManager/Settings/Test", cmd->b,
                      NULL, (NMSecretAgentGetSecretsFlags)cmd->flag, test_answered, ticket);
    g_object_unref(conn);
  }
  if (v) g_variant_unref(v);
  g_clear_error(&error);
  return G_SOURCE_REMOVE;
}

void lava_net_test_get_secrets(LavaNet *n, const char *connection, const char *setting,
                               uint32_t flags, LavaNetTestDone done, void *user) {
  TestTicket *ticket = g_new0(TestTicket, 1);
  ticket->done = done;
  ticket->user = user;
  Command *cmd = command(n, connection, setting, NULL);
  cmd->flag = (int)flags;
  cmd->id = (uint64_t)(gsize)ticket;
  run(n, do_test_get, cmd);
}

static gboolean do_test_cancel(gpointer data) {
  Command *cmd = data;
  if (cmd->net->agent) {
    agent_cancel_get_secrets(cmd->net->agent, "/org/freedesktop/NetworkManager/Settings/Test",
                             cmd->a);
  }
  return G_SOURCE_REMOVE;
}

void lava_net_test_cancel_secrets(LavaNet *n, const char *setting) {
  run(n, do_test_cancel, command(n, setting, NULL, NULL));
}
