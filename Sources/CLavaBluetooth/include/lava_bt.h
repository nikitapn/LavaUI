// Thin C surface over BlueZ for the panel's Bluetooth applet.
//
// BlueZ has no client library; its API *is* D-Bus — adapters and devices as
// objects under /org/bluez, published through an ObjectManager. This runs a
// GDBusObjectManagerClient for org.bluez on a private GLib main context, on
// its own thread, and posts one whole snapshot to Swift whenever anything
// in that tree changes: the CLavaNet contract, for the CLavaNet reason. A
// desk has a handful of devices and a scan a few dozen.
//
// It is also a pairing agent (org.bluez.Agent1). Pairing a keyboard means
// showing the code to type on it; pairing a phone, confirming the number
// both screens show; a device that is not trusted asks before it may use a
// service. BlueZ asks the default agent for all of that, and an agent's
// requests are posted to Swift, which answers them with the user's choice.

#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LavaBt LavaBt;

typedef struct {
  /// D-Bus object path, "/org/bluez/hci0" — what every command names it by.
  const char *path;
  const char *address;
  /// The name other devices see (Alias).
  const char *name;
  int powered;
  /// "on", "off", "off-enabling", "on-disabling", or "off-blocked": the
  /// radio switch (rfkill) is holding it off. "" from a BlueZ too old to say.
  const char *power_state;
  int discovering;
  int discoverable;
  /// Seconds until a visible adapter hides itself again; 0 is never.
  uint32_t discoverable_timeout;
  int pairable;
} LavaBtAdapter;

/// What this process has asked of a device and not heard back about.
enum {
  LAVA_BT_IDLE = 0,
  LAVA_BT_CONNECTING = 1,
  LAVA_BT_DISCONNECTING = 2,
  LAVA_BT_PAIRING = 3,
};

typedef struct {
  const char *path;
  /// The adapter that sees it.
  const char *adapter;
  const char *address;
  /// What to call it: the Alias, which BlueZ fills from the device's own
  /// name and falls back to the address for one that sent none.
  const char *name;
  /// The device sent a name of its own. A scan in a city is mostly
  /// unnamed beacons, and a list of addresses helps nobody.
  int has_name;
  /// That name, which `name` returns to when a rename is cleared; "".
  const char *own_name;
  /// freedesktop icon name BlueZ derives from the class: "audio-headset",
  /// "input-mouse", "phone", …; "".
  const char *icon;
  /// Class of Device (classic), and GAP Appearance (LE); 0 when not sent.
  uint32_t device_class;
  uint32_t appearance;
  int paired;
  int trusted;
  int blocked;
  int connected;
  /// 0…100 from Battery1; -1 when the device reports none.
  int battery;
  /// dBm while the device is being seen by a scan; 0 otherwise.
  int rssi;
  /// `LAVA_BT_*`.
  int busy;
} LavaBtDevice;

/// Valid only for the duration of the callback; copy what you keep.
typedef struct {
  /// 0 while bluetoothd is not on the bus.
  int running;
  /// The pairing agent is registered and the default one.
  int agent;
  const LavaBtAdapter *adapters;
  size_t adapter_count;
  const LavaBtDevice *devices;
  size_t device_count;
} LavaBtSnapshot;

/// What an agent request wants of the user.
enum {
  /// Type a PIN (legacy pairing): answer with the text.
  LAVA_BT_ASK_PIN = 1,
  /// Type the 6-digit passkey the device shows: answer with the number.
  LAVA_BT_ASK_PASSKEY = 2,
  /// Show `pin` until pairing ends: type it on the device. No answer.
  LAVA_BT_SHOW_PIN = 3,
  /// Show `passkey`, `entered` digits of it typed so far. No answer.
  LAVA_BT_SHOW_PASSKEY = 4,
  /// Does the device show `passkey` too? Accept or decline.
  LAVA_BT_CONFIRM = 5,
  /// May the device pair at all (it asked, with nothing to compare)?
  LAVA_BT_AUTHORIZE = 6,
  /// May a device that is not trusted use `service`?
  LAVA_BT_AUTHORIZE_SERVICE = 7,
};

typedef struct {
  uint64_t id;
  int kind;
  /// The device's object path, and its name as the snapshot has it.
  const char *device;
  const char *name;
  uint32_t passkey;
  const char *pin;
  /// The service UUID, for `LAVA_BT_AUTHORIZE_SERVICE`; "".
  const char *service;
  /// For `LAVA_BT_SHOW_PASSKEY`. The same request is posted again, same
  /// `id`, each time the user types a digit on the device.
  uint16_t entered;
} LavaBtRequest;

typedef struct {
  void (*snapshot)(void *user, const LavaBtSnapshot *snapshot);
  /// The agent wants the user. Answer the asking kinds with
  /// `lava_bt_agent_reply`; the showing kinds go away on their own.
  void (*request)(void *user, const LavaBtRequest *request);
  /// Request `id` is over: answered elsewhere, cancelled by BlueZ, or the
  /// pairing it was for ended. Take the prompt down.
  void (*request_gone)(void *user, uint64_t id);
  /// A command failed. `what` says which ("Connect", "Pair", …), `name` is
  /// the device or adapter's own, and `error` is BlueZ's error name
  /// ("org.bluez.Error.Failed") when it sent one, "" otherwise.
  void (*error)(void *user, const char *what, const char *name, const char *error,
                const char *message);
} LavaBtCallbacks;

/// Connects to BlueZ on the system bus, and with `agent` nonzero registers
/// the pairing agent and asks to be the default one. Callbacks run on the
/// library's own thread — hop before touching UI state. bluetoothd not
/// running is not a failure: the snapshot says `running = 0`, and a later
/// start is picked up, the agent registered again.
LavaBt *lava_bt_create(const LavaBtCallbacks *callbacks, void *user, int agent);

void lava_bt_destroy(LavaBt *bt);

void lava_bt_set_powered(LavaBt *bt, const char *adapter, int on);

/// Starts or stops looking for devices. BlueZ counts discovery per client
/// and stops ours when this process goes, so a crash cannot leave the radio
/// scanning.
void lava_bt_set_discovering(LavaBt *bt, const char *adapter, int on);

/// Pairs, then trusts and connects, as every desktop applet does: a device
/// somebody chose to pair is one they mean to use.
void lava_bt_pair(LavaBt *bt, const char *device);

void lava_bt_connect(LavaBt *bt, const char *device);
void lava_bt_disconnect(LavaBt *bt, const char *device);

/// Removes the pairing and the device's entry.
void lava_bt_forget(LavaBt *bt, const char *device);

void lava_bt_set_trusted(LavaBt *bt, const char *device, int on);

/// A blocked device is refused every connection, and its existing ones
/// are dropped.
void lava_bt_set_blocked(LavaBt *bt, const char *device, int on);

/// What other devices see this adapter as. The adapter only answers a
/// search while visible, and hides again after its timeout.
void lava_bt_set_discoverable(LavaBt *bt, const char *adapter, int on);

/// Renames a device or the adapter, for this machine only (Alias). "" goes
/// back to the name it gave itself.
void lava_bt_set_alias(LavaBt *bt, const char *path, const char *alias);

/// Answers request `id`: `accept` zero is a no. `text` is the PIN, or the
/// passkey in decimal; NULL for a yes-or-no.
void lava_bt_agent_reply(LavaBt *bt, uint64_t id, int accept, const char *text);

/// For tests: calls `method` on this process's own agent through the bus,
/// as bluetoothd would — the same D-Bus dispatch, the same reply. `number`
/// is the passkey for the methods that take one, `text` the PIN or service
/// UUID. `done` gets "ok", "ok <value>" or "error <D-Bus error name>".
typedef void (*LavaBtTestDone)(void *user, const char *result);
void lava_bt_test_call_agent(LavaBt *bt, const char *method, const char *device,
                             uint32_t number, const char *text, LavaBtTestDone done,
                             void *user);

#ifdef __cplusplus
}
#endif
