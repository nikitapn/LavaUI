// Thin C surface over libnm for the panel's network applet.
//
// NetworkManager's object model is a tree of D-Bus objects — devices, access
// points, active and saved connections — that libnm mirrors and keeps
// current. This runs one NMClient on a private GLib main context, on its own
// thread, and posts one whole snapshot to Swift whenever anything in that
// tree changes: the same contract as CPulse, for the same reason. The lists
// are tens of rows, and a delta protocol would be a second copy of
// NetworkManager's state to keep in step.
//
// It is also a secret agent. NetworkManager asks an agent of the logged-in
// user for whatever secret it does not hold itself — a VPN password saved in
// the keyring, the password for a new Wi-Fi network, a one-time code. nm-applet
// is one; this is the panel's. Saved secrets come from the keyring, under the
// schema nm-applet and GNOME Shell file them with, and what is missing becomes
// a request posted to Swift, which answers it with the user's input.

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LavaNet LavaNet;

/// What an access point asks of a client before it will associate.
enum {
  LAVA_NET_SECURITY_OPEN = 0,
  LAVA_NET_SECURITY_WEP = 1,
  /// WPA/WPA2 personal: a passphrase.
  LAVA_NET_SECURITY_PSK = 2,
  /// WPA3 personal.
  LAVA_NET_SECURITY_SAE = 3,
  /// WPA enterprise (802.1X): certificates and an identity. Listed, not
  /// joined from the panel.
  LAVA_NET_SECURITY_ENTERPRISE = 4,
  /// Opportunistic wireless encryption: encrypted, no passphrase.
  LAVA_NET_SECURITY_OWE = 5,
};

enum {
  LAVA_NET_DEVICE_OTHER = 0,
  LAVA_NET_DEVICE_ETHERNET = 1,
  LAVA_NET_DEVICE_WIFI = 2,
};

/// `NMActiveConnectionState`, by value.
enum {
  LAVA_NET_ACTIVE_UNKNOWN = 0,
  LAVA_NET_ACTIVE_ACTIVATING = 1,
  LAVA_NET_ACTIVE_ACTIVATED = 2,
  LAVA_NET_ACTIVE_DEACTIVATING = 3,
  LAVA_NET_ACTIVE_DEACTIVATED = 4,
};

typedef struct {
  /// D-Bus object path — what every command names a thing by.
  const char *path;
  const char *iface;
  int type;
  /// `NMDeviceState`, by value: 100 is activated, 30 disconnected, 20
  /// unavailable (unplugged, or radio off).
  int state;
  /// "" when nothing is active on it.
  const char *active_connection;
  /// Wi-Fi only; "" otherwise or when not associated.
  const char *active_access_point;
  int managed;
  /// The first IPv4 address with its prefix, "192.168.1.20/24"; "" if none.
  const char *ip4;
  /// What DHCP or the profile gave the running link: the default gateway,
  /// and the name servers comma-separated. "" when there are none.
  const char *ip4_gateway;
  const char *ip4_dns;
  /// The first global IPv6 address with its prefix; "" if none.
  const char *ip6;
  /// "AA:BB:CC:DD:EE:FF"; "" for a device that has none.
  const char *hw_address;
  /// Link speed in Mb/s, Ethernet only; 0 when unknown.
  uint32_t speed;
} LavaNetDevice;

typedef struct {
  const char *path;
  /// The Wi-Fi device that sees it.
  const char *device;
  /// UTF-8; a name that is not valid UTF-8 comes escaped, as nmcli shows it.
  const char *ssid;
  const char *bssid;
  /// 0…100.
  int strength;
  int security;
  /// MHz.
  uint32_t frequency;
} LavaNetAccessPoint;

typedef struct {
  const char *path;
  const char *id;
  const char *uuid;
  /// The setting type: "802-11-wireless", "802-3-ethernet", "vpn",
  /// "wireguard", …
  const char *type;
  int state;
  int vpn;
  /// The saved connection it was started from.
  const char *connection;
  /// The access point, for Wi-Fi.
  const char *specific_object;
  /// The device it runs on, the first one if several; "" for a VPN.
  const char *device;
  /// NetworkManager's choice for the default route.
  int is_default;
  /// The address the connection got — for a VPN, the tunnel's own; "".
  const char *ip4;
} LavaNetActive;

typedef struct {
  const char *path;
  const char *id;
  const char *uuid;
  const char *type;
  /// Wi-Fi only; "".
  const char *ssid;
  /// VPN only: the plugin's D-Bus service; "".
  const char *vpn_service;
  int autoconnect;
  /// Seconds since the epoch it last connected; 0 if never.
  uint64_t timestamp;
  /// IPv4 as saved: "auto", "manual", "disabled", "link-local", "shared";
  /// "" when the profile has no IPv4 setting at all (a WireGuard tunnel can
  /// lack one until edited).
  const char *ip4_method;
  /// Static addresses, "a.b.c.d/prefix", comma-separated.
  const char *ip4_addresses;
  const char *ip4_gateway;
  /// Name servers, comma-separated.
  const char *ip4_dns;
  /// Only the servers above, not the ones DHCP or the VPN offers.
  int ip4_ignore_auto_dns;
  /// Never the default route: only traffic for the connection's own
  /// networks goes through it. Mostly asked of a VPN.
  int ip4_never_default;
  /// VPN and WireGuard: the server it connects to, as the profile names
  /// it; "".
  const char *remote;
} LavaNetConnection;

/// Valid only for the duration of the callback; copy what you keep.
typedef struct {
  /// 0 while NetworkManager is not on the bus.
  int running;
  int networking_enabled;
  int wireless_enabled;
  /// The radio switch — rfkill, an airplane-mode key.
  int wireless_hardware_enabled;
  /// `NMState`: 70 connected globally, 60 site, 50 local, 40 connecting,
  /// 20 disconnected, 10 asleep.
  int state;
  /// `NMConnectivityState`: 4 full, 3 limited, 2 portal, 1 none.
  int connectivity;
  /// The active connection with the default route; "".
  const char *primary;
  /// A scan is running on some Wi-Fi device.
  int scanning;
  const LavaNetDevice *devices;
  size_t device_count;
  const LavaNetAccessPoint *access_points;
  size_t access_point_count;
  const LavaNetActive *active;
  size_t active_count;
  const LavaNetConnection *connections;
  size_t connection_count;
} LavaNetSnapshot;

/// One thing to ask the user for. `value` is a prefill — a user name the
/// plugin already knows — and `ask` says whether to show it at all: a field
/// the plugin does not need asked is still part of the reply.
typedef struct {
  const char *key;
  const char *label;
  const char *value;
  int secret;
  int ask;
} LavaNetSecretField;

typedef struct {
  uint64_t id;
  /// The connection's name, "zodiac-2022" or the SSID.
  const char *connection;
  const char *title;
  const char *message;
  const LavaNetSecretField *fields;
  size_t field_count;
} LavaNetSecretRequest;

typedef struct {
  void (*snapshot)(void *user, const LavaNetSnapshot *snapshot);
  /// NetworkManager needs secrets only the user can give. Answer with
  /// `lava_net_secret_reply` or `lava_net_secret_cancel`.
  void (*secret_request)(void *user, const LavaNetSecretRequest *request);
  /// NetworkManager no longer needs request `id`: the connection was
  /// cancelled, or another agent answered. Take the prompt down.
  void (*secret_cancelled)(void *user, uint64_t id);
  /// A command failed. `what` says which ("Connect", "Disconnect", …).
  void (*error)(void *user, const char *what, const char *message);
  /// A command that changes a profile went through: `what` as for `error`,
  /// `path` the profile it changed or made. May be NULL.
  void (*done)(void *user, const char *what, const char *path);
} LavaNetCallbacks;

/// Connects to NetworkManager on the system bus, and with `agent` nonzero
/// registers the secret agent too. One agent per user is the rule — a
/// second one under the same identifier takes over from the first — so
/// only the panel asks for it; Settings does not. Callbacks run on the
/// library's own thread — hop before touching UI state. NetworkManager not
/// running is not a failure: the snapshot says `running = 0`, and a later
/// start is picked up.
LavaNet *lava_net_create(const LavaNetCallbacks *callbacks, void *user, int agent);

void lava_net_destroy(LavaNet *net);

void lava_net_set_wireless_enabled(LavaNet *net, int enabled);

/// Every Wi-Fi device. NetworkManager rate-limits scans itself.
void lava_net_request_scan(LavaNet *net);

/// Starts a saved connection. `device` and `specific_object` may be NULL —
/// NetworkManager picks — or name the device and access point, for a Wi-Fi
/// network seen by more than one radio.
void lava_net_activate(LavaNet *net, const char *connection, const char *device,
                       const char *specific_object);

/// Joins an access point there is no saved connection for. `password` NULL
/// leaves the secret to the agent, which asks for it; an open network needs
/// none. The connection is saved, as nmcli and nm-applet save it.
void lava_net_connect_access_point(LavaNet *net, const char *device,
                                   const char *access_point,
                                   const char *password);

void lava_net_deactivate(LavaNet *net, const char *active);

/// Deletes a saved connection.
void lava_net_forget(LavaNet *net, const char *connection);

/// A change to a saved profile. NULL strings and -1 flags leave a field as
/// it is; `ip4_method` NULL leaves all of IPv4 alone, and given, replaces
/// the addresses, gateway and name servers with the ones here (comma- or
/// space-separated; an address without a prefix is a /24).
typedef struct {
  const char *id;
  int autoconnect;
  const char *ip4_method;
  const char *ip4_addresses;
  const char *ip4_gateway;
  const char *ip4_dns;
  int ip4_ignore_auto_dns;
  int ip4_never_default;
} LavaNetEdit;

/// Saves `edit` into `connection`, to disk. Secrets are not sent, and
/// NetworkManager keeps the ones it has. A connection that is up keeps
/// running as it was until it is next started. `error` ("Save") or `done`.
void lava_net_update(LavaNet *net, const char *connection, const LavaNetEdit *edit);

/// Adds a profile read from `file`: a WireGuard `.conf`, or anything an
/// installed VPN plugin can import (`.ovpn`, …). `error` ("Import") or
/// `done` with the new profile's path.
void lava_net_import(LavaNet *net, const char *file);

/// Answers request `id` with `values[i]` for `keys[i]`. Keys not answered
/// keep the plugin's own value.
void lava_net_secret_reply(LavaNet *net, uint64_t id, const char *const *keys,
                           const char *const *values, size_t count);

/// The user said no. NetworkManager gives up on the connection.
void lava_net_secret_cancel(LavaNet *net, uint64_t id);

/// For tests: runs the agent's GetSecrets on `connection`, a connection in
/// GVariant text form (`{'connection': {'id': <'x'>, …}, …}`), as if
/// NetworkManager had asked. `done` gets the secrets in the same text form,
/// or "error <D-Bus error name>: <message>". libnm will not register an agent
/// with a NetworkManager root does not own, so a mock on a private bus can
/// never ask the real way.
typedef void (*LavaNetTestDone)(void *user, const char *result);
void lava_net_test_get_secrets(LavaNet *net, const char *connection, const char *setting,
                               uint32_t flags, LavaNetTestDone done, void *user);

/// For tests: NetworkManager's CancelGetSecrets for what
/// `lava_net_test_get_secrets` asked.
void lava_net_test_cancel_secrets(LavaNet *net, const char *setting);

#ifdef __cplusplus
}
#endif
