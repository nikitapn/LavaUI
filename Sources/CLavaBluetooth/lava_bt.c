#include "lava_bt.h"

#include <gio/gio.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define BLUEZ "org.bluez"
#define ADAPTER_IFACE "org.bluez.Adapter1"
#define DEVICE_IFACE "org.bluez.Device1"
#define BATTERY_IFACE "org.bluez.Battery1"
#define AGENT_IFACE "org.bluez.Agent1"
#define AGENT_MANAGER_IFACE "org.bluez.AgentManager1"
#define AGENT_PATH "/org/lava/bluetooth/agent"

// Pairing waits on a person typing a code on a keyboard, and BlueZ's own
// limit is longer than D-Bus's default 25 s.
#define PAIR_TIMEOUT_MS 90000
// A headset that is off answers a page after about 5 s with "page timeout";
// one that is on but busy can take most of this.
#define CONNECT_TIMEOUT_MS 30000

// ─── State ──────────────────────────────────────────────────────────────────

// One thing the agent is waiting on the user for.
typedef struct {
  uint64_t id;
  int kind;
  char *device;
  uint32_t passkey;
  char *pin;
  char *service;
  uint16_t entered;
  // The call to answer; NULL for the showing kinds, which BlueZ does not
  // wait on.
  GDBusMethodInvocation *invocation;
} Request;

struct LavaBt {
  LavaBtCallbacks cb;
  void *user;

  GMainContext *ctx;
  GMainLoop *loop;
  GThread *thread;
  GMutex start_lock;
  GCond started;
  int start_done;
  int want_agent;

  GDBusConnection *bus;
  GDBusObjectManager *manager;
  GDBusNodeInfo *agent_info;
  guint agent_object;
  int agent_registered;

  // A discovery is a burst of PropertiesChanged — RSSI on every
  // advertisement — and a snapshot per signal would be dozens a second.
  GSource *pending;

  // Device path → LAVA_BT_*, for what we asked and have not heard back.
  GHashTable *busy;
  // Adapters this process started discovery on: Stop is only ours to send
  // for those, and they are stopped on the way out.
  GHashTable *discovering;
  // Devices whose agent request the user turned down. Their Pair then
  // fails with AuthenticationRejected, which is not news to the person who
  // pressed the button.
  GHashTable *declined;

  GList *requests;
  uint64_t next_request;
};

// ─── Small things ───────────────────────────────────────────────────────────

static const char *str(const char *s) { return s ? s : ""; }

static void schedule_snapshot(LavaBt *bt);

static GDBusProxy *proxy_of(LavaBt *bt, const char *path, const char *iface) {
  if (bt->manager == NULL || path == NULL || path[0] == '\0') return NULL;
  GDBusInterface *i = g_dbus_object_manager_get_interface(bt->manager, path, iface);
  return i ? G_DBUS_PROXY(i) : NULL;
}

static GVariant *prop(GDBusProxy *p, const char *name) {
  return p ? g_dbus_proxy_get_cached_property(p, name) : NULL;
}

static char *prop_string(GDBusProxy *p, const char *name) {
  GVariant *v = prop(p, name);
  char *out = NULL;
  if (v && (g_variant_is_of_type(v, G_VARIANT_TYPE_STRING) ||
            g_variant_is_of_type(v, G_VARIANT_TYPE_OBJECT_PATH))) {
    out = g_variant_dup_string(v, NULL);
  }
  if (v) g_variant_unref(v);
  return out ? out : g_strdup("");
}

static int prop_bool(GDBusProxy *p, const char *name) {
  GVariant *v = prop(p, name);
  int out = v && g_variant_is_of_type(v, G_VARIANT_TYPE_BOOLEAN) ? g_variant_get_boolean(v) : 0;
  if (v) g_variant_unref(v);
  return out;
}

// Any integer type, as a long; `fallback` when absent.
static long prop_int(GDBusProxy *p, const char *name, long fallback) {
  GVariant *v = prop(p, name);
  long out = fallback;
  if (v) {
    if (g_variant_is_of_type(v, G_VARIANT_TYPE_BYTE)) out = g_variant_get_byte(v);
    else if (g_variant_is_of_type(v, G_VARIANT_TYPE_INT16)) out = g_variant_get_int16(v);
    else if (g_variant_is_of_type(v, G_VARIANT_TYPE_UINT16)) out = g_variant_get_uint16(v);
    else if (g_variant_is_of_type(v, G_VARIANT_TYPE_INT32)) out = g_variant_get_int32(v);
    else if (g_variant_is_of_type(v, G_VARIANT_TYPE_UINT32)) out = (long)g_variant_get_uint32(v);
    g_variant_unref(v);
  }
  return out;
}

static int has_prop(GDBusProxy *p, const char *name) {
  GVariant *v = prop(p, name);
  if (v) g_variant_unref(v);
  return v != NULL;
}

// What to call the thing at `path` in an error or a prompt.
static char *name_of(LavaBt *bt, const char *path) {
  GDBusProxy *p = proxy_of(bt, path, DEVICE_IFACE);
  if (p == NULL) p = proxy_of(bt, path, ADAPTER_IFACE);
  char *name = p ? prop_string(p, "Alias") : g_strdup("");
  if (p) g_object_unref(p);
  if (name[0] == '\0') {
    g_free(name);
    return g_strdup(str(path));
  }
  return name;
}

static void report(LavaBt *bt, const char *what, const char *path, GError *error) {
  if (error == NULL || bt->cb.error == NULL) return;
  if (g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) return;
  char *remote = g_dbus_error_get_remote_error(error);
  g_dbus_error_strip_remote_error(error);
  char *name = name_of(bt, path);
  bt->cb.error(bt->user, what, name, str(remote), error->message);
  g_free(name);
  g_free(remote);
}

static int is_error(GError *error, const char *name) {
  if (error == NULL) return 0;
  char *remote = g_dbus_error_get_remote_error(error);
  const int same = remote && strcmp(remote, name) == 0;
  g_free(remote);
  return same;
}

static void set_busy(LavaBt *bt, const char *path, int kind) {
  if (kind == LAVA_BT_IDLE) g_hash_table_remove(bt->busy, path);
  else g_hash_table_insert(bt->busy, g_strdup(path), GINT_TO_POINTER(kind));
  schedule_snapshot(bt);
}

// ─── Snapshot ───────────────────────────────────────────────────────────────

typedef struct {
  GPtrArray *strings;
} Arena;

static const char *keep(Arena *a, char *s) {
  g_ptr_array_add(a->strings, s);
  return s;
}

static int running(LavaBt *bt) {
  if (bt->manager == NULL) return 0;
  char *owner =
      g_dbus_object_manager_client_get_name_owner(G_DBUS_OBJECT_MANAGER_CLIENT(bt->manager));
  const int up = owner != NULL;
  g_free(owner);
  return up;
}

static void publish(LavaBt *bt) {
  if (bt->cb.snapshot == NULL) return;
  Arena a = {g_ptr_array_new_with_free_func(g_free)};
  GArray *adapters = g_array_new(FALSE, TRUE, sizeof(LavaBtAdapter));
  GArray *devices = g_array_new(FALSE, TRUE, sizeof(LavaBtDevice));

  LavaBtSnapshot snap = {0};
  snap.running = running(bt);
  snap.agent = bt->agent_registered;
  GList *objects = snap.running ? g_dbus_object_manager_get_objects(bt->manager) : NULL;
  for (GList *l = objects; l; l = l->next) {
    GDBusObject *object = l->data;
    const char *path = g_dbus_object_get_object_path(object);

    GDBusInterface *ai = g_dbus_object_get_interface(object, ADAPTER_IFACE);
    if (ai) {
      GDBusProxy *p = G_DBUS_PROXY(ai);
      LavaBtAdapter row = {0};
      row.path = keep(&a, g_strdup(path));
      row.address = keep(&a, prop_string(p, "Address"));
      row.name = keep(&a, prop_string(p, "Alias"));
      row.powered = prop_bool(p, "Powered");
      row.power_state = keep(&a, prop_string(p, "PowerState"));
      row.discovering = prop_bool(p, "Discovering");
      row.discoverable = prop_bool(p, "Discoverable");
      row.discoverable_timeout = (uint32_t)prop_int(p, "DiscoverableTimeout", 0);
      row.pairable = prop_bool(p, "Pairable");
      g_array_append_val(adapters, row);
      g_object_unref(ai);
    }

    GDBusInterface *di = g_dbus_object_get_interface(object, DEVICE_IFACE);
    if (di) {
      GDBusProxy *p = G_DBUS_PROXY(di);
      LavaBtDevice row = {0};
      row.path = keep(&a, g_strdup(path));
      row.adapter = keep(&a, prop_string(p, "Adapter"));
      row.address = keep(&a, prop_string(p, "Address"));
      row.name = keep(&a, prop_string(p, "Alias"));
      row.has_name = has_prop(p, "Name");
      row.own_name = keep(&a, prop_string(p, "Name"));
      row.icon = keep(&a, prop_string(p, "Icon"));
      row.device_class = (uint32_t)prop_int(p, "Class", 0);
      row.appearance = (uint32_t)prop_int(p, "Appearance", 0);
      row.paired = prop_bool(p, "Paired");
      row.trusted = prop_bool(p, "Trusted");
      row.blocked = prop_bool(p, "Blocked");
      row.connected = prop_bool(p, "Connected");
      // RSSI is only there while a scan is hearing the device; BlueZ
      // drops it when the device goes quiet.
      row.rssi = (int)prop_int(p, "RSSI", 0);
      row.battery = -1;
      GDBusInterface *bi = g_dbus_object_get_interface(object, BATTERY_IFACE);
      if (bi) {
        row.battery = (int)prop_int(G_DBUS_PROXY(bi), "Percentage", -1);
        g_object_unref(bi);
      }
      row.busy = GPOINTER_TO_INT(g_hash_table_lookup(bt->busy, path));
      g_array_append_val(devices, row);
      g_object_unref(di);
    }
  }
  g_list_free_full(objects, g_object_unref);

  snap.adapters = (const LavaBtAdapter *)adapters->data;
  snap.adapter_count = adapters->len;
  snap.devices = (const LavaBtDevice *)devices->data;
  snap.device_count = devices->len;
  bt->cb.snapshot(bt->user, &snap);

  g_array_free(adapters, TRUE);
  g_array_free(devices, TRUE);
  g_ptr_array_free(a.strings, TRUE);
}

static gboolean on_pending(gpointer data) {
  LavaBt *bt = data;
  g_source_unref(bt->pending);
  bt->pending = NULL;
  publish(bt);
  return G_SOURCE_REMOVE;
}

static void schedule_snapshot(LavaBt *bt) {
  if (bt->pending) return;
  bt->pending = g_timeout_source_new(50);
  g_source_set_callback(bt->pending, on_pending, bt, NULL);
  g_source_attach(bt->pending, bt->ctx);
}

// ─── Agent ──────────────────────────────────────────────────────────────────

static const char agent_xml[] =
    "<node><interface name='" AGENT_IFACE "'>"
    "<method name='Release'/>"
    "<method name='RequestPinCode'><arg type='o' direction='in'/>"
    "<arg type='s' direction='out'/></method>"
    "<method name='DisplayPinCode'><arg type='o' direction='in'/>"
    "<arg type='s' direction='in'/></method>"
    "<method name='RequestPasskey'><arg type='o' direction='in'/>"
    "<arg type='u' direction='out'/></method>"
    "<method name='DisplayPasskey'><arg type='o' direction='in'/>"
    "<arg type='u' direction='in'/><arg type='q' direction='in'/></method>"
    "<method name='RequestConfirmation'><arg type='o' direction='in'/>"
    "<arg type='u' direction='in'/></method>"
    "<method name='RequestAuthorization'><arg type='o' direction='in'/></method>"
    "<method name='AuthorizeService'><arg type='o' direction='in'/>"
    "<arg type='s' direction='in'/></method>"
    "<method name='Cancel'/>"
    "</interface></node>";

static void request_free(Request *r) {
  g_free(r->device);
  if (r->pin) memset(r->pin, 0, strlen(r->pin));
  g_free(r->pin);
  g_free(r->service);
  g_free(r);
}

static void post(LavaBt *bt, Request *r) {
  if (bt->cb.request == NULL) return;
  char *name = name_of(bt, r->device);
  LavaBtRequest out = {0};
  out.id = r->id;
  out.kind = r->kind;
  out.device = str(r->device);
  out.name = name;
  out.passkey = r->passkey;
  out.pin = str(r->pin);
  out.service = str(r->service);
  out.entered = r->entered;
  bt->cb.request(bt->user, &out);
  g_free(name);
}

// Ends `r`: BlueZ hears `error` if it is still waiting, Swift hears that the
// prompt is gone when `tell`.
static void take_down(LavaBt *bt, Request *r, const char *error, int tell) {
  bt->requests = g_list_remove(bt->requests, r);
  if (r->invocation) {
    g_dbus_method_invocation_return_dbus_error(r->invocation, error, "Cancelled");
    r->invocation = NULL;
  }
  if (tell && bt->cb.request_gone) bt->cb.request_gone(bt->user, r->id);
  request_free(r);
}

static void take_down_all(LavaBt *bt, const char *error) {
  while (bt->requests) take_down(bt, bt->requests->data, error, 1);
}

// The showing prompts for `device`: what to type on a keyboard means
// nothing once its pairing is over, however it ended.
static void take_down_shown(LavaBt *bt, const char *device) {
  for (GList *l = bt->requests; l;) {
    Request *r = l->data;
    l = l->next;
    if (r->invocation == NULL && g_strcmp0(r->device, device) == 0) take_down(bt, r, NULL, 1);
  }
}

static Request *find_request(LavaBt *bt, uint64_t id) {
  for (GList *l = bt->requests; l; l = l->next) {
    Request *r = l->data;
    if (r->id == id) return r;
  }
  return NULL;
}

static Request *new_request(LavaBt *bt, int kind, const char *device) {
  Request *r = g_new0(Request, 1);
  r->id = ++bt->next_request;
  r->kind = kind;
  r->device = g_strdup(device);
  bt->requests = g_list_append(bt->requests, r);
  return r;
}

// Only bluetoothd may ask: the system bus lets anyone call an exported
// object, and a prompt is something a stranger should not be able to put
// on the screen. Our own name is the test hook's.
static int trusted_caller(LavaBt *bt, const char *sender) {
  if (sender == NULL) return 0;
  if (g_strcmp0(sender, g_dbus_connection_get_unique_name(bt->bus)) == 0) return 1;
  char *owner =
      bt->manager ? g_dbus_object_manager_client_get_name_owner(
                        G_DBUS_OBJECT_MANAGER_CLIENT(bt->manager))
                  : NULL;
  const int ok = owner && strcmp(owner, sender) == 0;
  g_free(owner);
  return ok;
}

static void on_agent_call(GDBusConnection *connection, const char *sender, const char *path,
                          const char *iface, const char *method, GVariant *params,
                          GDBusMethodInvocation *invocation, gpointer data) {
  (void)connection;
  (void)path;
  (void)iface;
  LavaBt *bt = data;
  if (!trusted_caller(bt, sender)) {
    g_dbus_method_invocation_return_dbus_error(invocation, "org.bluez.Error.Rejected",
                                               "Not bluetoothd");
    return;
  }
  if (strcmp(method, "Release") == 0) {
    // Unregistered from the other side: bluetoothd is stopping, or another
    // agent took over. Registered again when it next appears.
    bt->agent_registered = 0;
    take_down_all(bt, "org.bluez.Error.Canceled");
    g_dbus_method_invocation_return_value(invocation, NULL);
    schedule_snapshot(bt);
    return;
  }
  if (strcmp(method, "Cancel") == 0) {
    take_down_all(bt, "org.bluez.Error.Canceled");
    g_dbus_method_invocation_return_value(invocation, NULL);
    return;
  }

  const char *device = NULL;
  if (strcmp(method, "DisplayPinCode") == 0) {
    const char *pin = NULL;
    g_variant_get(params, "(&o&s)", &device, &pin);
    Request *r = new_request(bt, LAVA_BT_SHOW_PIN, device);
    r->pin = g_strdup(pin);
    g_dbus_method_invocation_return_value(invocation, NULL);
    post(bt, r);
    return;
  }
  if (strcmp(method, "DisplayPasskey") == 0) {
    guint32 passkey = 0;
    guint16 entered = 0;
    g_variant_get(params, "(&ouq)", &device, &passkey, &entered);
    g_dbus_method_invocation_return_value(invocation, NULL);
    // Called again for every digit typed on the device: the same prompt,
    // one more digit filled in.
    for (GList *l = bt->requests; l; l = l->next) {
      Request *r = l->data;
      if (r->kind == LAVA_BT_SHOW_PASSKEY && g_strcmp0(r->device, device) == 0) {
        r->passkey = passkey;
        r->entered = entered;
        post(bt, r);
        return;
      }
    }
    Request *r = new_request(bt, LAVA_BT_SHOW_PASSKEY, device);
    r->passkey = passkey;
    r->entered = entered;
    post(bt, r);
    return;
  }

  Request *r = NULL;
  if (strcmp(method, "RequestPinCode") == 0) {
    g_variant_get(params, "(&o)", &device);
    r = new_request(bt, LAVA_BT_ASK_PIN, device);
  } else if (strcmp(method, "RequestPasskey") == 0) {
    g_variant_get(params, "(&o)", &device);
    r = new_request(bt, LAVA_BT_ASK_PASSKEY, device);
  } else if (strcmp(method, "RequestConfirmation") == 0) {
    guint32 passkey = 0;
    g_variant_get(params, "(&ou)", &device, &passkey);
    r = new_request(bt, LAVA_BT_CONFIRM, device);
    r->passkey = passkey;
  } else if (strcmp(method, "RequestAuthorization") == 0) {
    g_variant_get(params, "(&o)", &device);
    r = new_request(bt, LAVA_BT_AUTHORIZE, device);
  } else if (strcmp(method, "AuthorizeService") == 0) {
    const char *uuid = NULL;
    g_variant_get(params, "(&o&s)", &device, &uuid);
    r = new_request(bt, LAVA_BT_AUTHORIZE_SERVICE, device);
    r->service = g_strdup(uuid);
  } else {
    g_dbus_method_invocation_return_dbus_error(invocation, "org.freedesktop.DBus.Error.UnknownMethod",
                                               method);
    return;
  }
  r->invocation = invocation;
  post(bt, r);
}

static const GDBusInterfaceVTable agent_vtable = {on_agent_call, NULL, NULL, {0}};

static void on_default_agent(GObject *source, GAsyncResult *result, gpointer data) {
  LavaBt *bt = data;
  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (reply) {
    g_variant_unref(reply);
    bt->agent_registered = 1;
    schedule_snapshot(bt);
  } else {
    fprintf(stderr, "lava_bt: RequestDefaultAgent: %s\n", error->message);
    g_error_free(error);
  }
}

static void on_agent_registered(GObject *source, GAsyncResult *result, gpointer data) {
  LavaBt *bt = data;
  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (reply) g_variant_unref(reply);
  // AlreadyExists is a second registration of ours racing the first.
  if (error && !is_error(error, "org.bluez.Error.AlreadyExists")) {
    fprintf(stderr, "lava_bt: RegisterAgent: %s\n", error->message);
    g_error_free(error);
    return;
  }
  g_clear_error(&error);
  // Default, or BlueZ asks whoever registered first — blueman, if it is
  // still running. The newest default wins, which is the panel starting.
  g_dbus_connection_call(bt->bus, BLUEZ, "/org/bluez", AGENT_MANAGER_IFACE,
                         "RequestDefaultAgent", g_variant_new("(o)", AGENT_PATH), NULL,
                         G_DBUS_CALL_FLAGS_NONE, -1, NULL, on_default_agent, bt);
}

static void register_agent(LavaBt *bt) {
  if (bt->agent_object == 0 || !running(bt)) return;
  g_dbus_connection_call(bt->bus, BLUEZ, "/org/bluez", AGENT_MANAGER_IFACE, "RegisterAgent",
                         g_variant_new("(os)", AGENT_PATH, "KeyboardDisplay"), NULL,
                         G_DBUS_CALL_FLAGS_NONE, -1, NULL, on_agent_registered, bt);
}

static void on_name_owner(GObject *object, GParamSpec *pspec, gpointer data) {
  (void)object;
  (void)pspec;
  LavaBt *bt = data;
  if (running(bt)) {
    register_agent(bt);
  } else {
    // bluetoothd went: nothing we asked of it will be answered, and its
    // agent registrations went with it.
    bt->agent_registered = 0;
    g_hash_table_remove_all(bt->busy);
    g_hash_table_remove_all(bt->discovering);
    take_down_all(bt, "org.bluez.Error.Canceled");
  }
  schedule_snapshot(bt);
}

// ─── Commands ───────────────────────────────────────────────────────────────

typedef struct {
  LavaBt *bt;
  char *path;
  char *text;
  char *method;
  int flag;
  uint64_t id;
  uint32_t number;
  LavaBtTestDone done;
  void *done_user;
} Command;

static void command_free(gpointer data) {
  Command *cmd = data;
  g_free(cmd->path);
  // A PIN: no copy of it outlives the reply.
  if (cmd->text) memset(cmd->text, 0, strlen(cmd->text));
  g_free(cmd->text);
  g_free(cmd->method);
  g_free(cmd);
}

static Command *command(LavaBt *bt, const char *path) {
  Command *cmd = g_new0(Command, 1);
  cmd->bt = bt;
  cmd->path = g_strdup(path);
  return cmd;
}

static void run(LavaBt *bt, GSourceFunc fn, Command *cmd) {
  if (bt == NULL || bt->ctx == NULL) {
    command_free(cmd);
    return;
  }
  g_main_context_invoke_full(bt->ctx, G_PRIORITY_DEFAULT, fn, cmd, command_free);
}

// One call in flight: what it was, on what, and what to do after.
typedef struct {
  LavaBt *bt;
  char *what;
  char *path;
} Op;

static Op *op(LavaBt *bt, const char *what, const char *path) {
  Op *o = g_new0(Op, 1);
  o->bt = bt;
  o->what = g_strdup(what);
  o->path = g_strdup(path);
  return o;
}

static void op_free(Op *o) {
  g_free(o->what);
  g_free(o->path);
  g_free(o);
}

static void call(LavaBt *bt, const char *path, const char *iface, const char *method,
                 GVariant *params, int timeout, GAsyncReadyCallback done, Op *o) {
  g_dbus_connection_call(bt->bus, BLUEZ, path, iface, method, params, NULL,
                         G_DBUS_CALL_FLAGS_NONE, timeout, NULL, done, o);
}

static void set_property(LavaBt *bt, const char *path, const char *iface, const char *name,
                         GVariant *value, GAsyncReadyCallback done, Op *o) {
  call(bt, path, "org.freedesktop.DBus.Properties", "Set",
       g_variant_new("(ssv)", iface, name, value), -1, done, o);
}

// Reports a failure, and that is all.
static void on_plain(GObject *source, GAsyncResult *result, gpointer data) {
  Op *o = data;
  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (reply) g_variant_unref(reply);
  if (error) {
    report(o->bt, o->what, o->path, error);
    g_error_free(error);
  }
  op_free(o);
}

// Ignores a failure: what was asked is not worth a word if it did not take.
static void on_quiet(GObject *source, GAsyncResult *result, gpointer data) {
  GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, NULL);
  if (reply) g_variant_unref(reply);
  op_free(data);
}

static gboolean do_set_powered(gpointer data) {
  Command *cmd = data;
  LavaBt *bt = cmd->bt;
  if (bt->bus == NULL) return G_SOURCE_REMOVE;
  set_property(bt, cmd->path, ADAPTER_IFACE, "Powered", g_variant_new_boolean(cmd->flag),
               on_plain, op(bt, "Bluetooth", cmd->path));
  return G_SOURCE_REMOVE;
}

static void on_discovery(GObject *source, GAsyncResult *result, gpointer data) {
  Op *o = data;
  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (reply) g_variant_unref(reply);
  // InProgress: somebody else's scan is already running, and ours rides it.
  if (error && !is_error(error, "org.bluez.Error.InProgress")) {
    g_hash_table_remove(o->bt->discovering, o->path);
    report(o->bt, o->what, o->path, error);
  }
  g_clear_error(&error);
  op_free(o);
}

static gboolean do_set_discovering(gpointer data) {
  Command *cmd = data;
  LavaBt *bt = cmd->bt;
  if (bt->bus == NULL) return G_SOURCE_REMOVE;
  const int ours = g_hash_table_contains(bt->discovering, cmd->path);
  // Ours, but not running: the radio was switched off under it, which ends
  // a discovery without a word to the client that started it.
  GDBusProxy *p = proxy_of(bt, cmd->path, ADAPTER_IFACE);
  const int running_now = prop_bool(p, "Discovering");
  if (p) g_object_unref(p);
  if (cmd->flag && (!ours || !running_now)) {
    g_hash_table_add(bt->discovering, g_strdup(cmd->path));
    call(bt, cmd->path, ADAPTER_IFACE, "StartDiscovery", NULL, -1, on_discovery,
         op(bt, "Search", cmd->path));
  } else if (!cmd->flag && ours) {
    g_hash_table_remove(bt->discovering, cmd->path);
    call(bt, cmd->path, ADAPTER_IFACE, "StopDiscovery", NULL, -1, on_quiet,
         op(bt, "Search", cmd->path));
  }
  return G_SOURCE_REMOVE;
}

static void on_connected(GObject *source, GAsyncResult *result, gpointer data) {
  Op *o = data;
  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (reply) g_variant_unref(reply);
  set_busy(o->bt, o->path, LAVA_BT_IDLE);
  if (error && !is_error(error, "org.bluez.Error.AlreadyConnected") &&
      !is_error(error, "org.bluez.Error.NotConnected")) {
    report(o->bt, o->what, o->path, error);
  }
  g_clear_error(&error);
  op_free(o);
}

static void connect_device(LavaBt *bt, const char *path) {
  set_busy(bt, path, LAVA_BT_CONNECTING);
  call(bt, path, DEVICE_IFACE, "Connect", NULL, CONNECT_TIMEOUT_MS, on_connected,
       op(bt, "Connect", path));
}

static gboolean do_connect(gpointer data) {
  Command *cmd = data;
  if (cmd->bt->bus) connect_device(cmd->bt, cmd->path);
  return G_SOURCE_REMOVE;
}

static gboolean do_disconnect(gpointer data) {
  Command *cmd = data;
  LavaBt *bt = cmd->bt;
  if (bt->bus == NULL) return G_SOURCE_REMOVE;
  set_busy(bt, cmd->path, LAVA_BT_DISCONNECTING);
  call(bt, cmd->path, DEVICE_IFACE, "Disconnect", NULL, CONNECT_TIMEOUT_MS, on_connected,
       op(bt, "Disconnect", cmd->path));
  return G_SOURCE_REMOVE;
}

static void on_paired(GObject *source, GAsyncResult *result, gpointer data) {
  Op *o = data;
  LavaBt *bt = o->bt;
  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  if (reply) g_variant_unref(reply);
  take_down_shown(bt, o->path);
  const int declined = g_hash_table_remove(bt->declined, o->path);
  if (error && !is_error(error, "org.bluez.Error.AlreadyExists")) {
    set_busy(bt, o->path, LAVA_BT_IDLE);
    if (!declined && !is_error(error, "org.bluez.Error.AuthenticationCanceled")) {
      report(bt, o->what, o->path, error);
    }
    g_error_free(error);
    op_free(o);
    return;
  }
  g_clear_error(&error);
  // Trusted, so it may reconnect by itself — a headset switched on, a
  // mouse woken — without the agent asking each time.
  set_property(bt, o->path, DEVICE_IFACE, "Trusted", g_variant_new_boolean(TRUE), on_quiet,
               op(bt, "Trust", o->path));
  connect_device(bt, o->path);
  op_free(o);
}

static gboolean do_pair(gpointer data) {
  Command *cmd = data;
  LavaBt *bt = cmd->bt;
  if (bt->bus == NULL) return G_SOURCE_REMOVE;
  g_hash_table_remove(bt->declined, cmd->path);
  set_busy(bt, cmd->path, LAVA_BT_PAIRING);
  call(bt, cmd->path, DEVICE_IFACE, "Pair", NULL, PAIR_TIMEOUT_MS, on_paired,
       op(bt, "Pair", cmd->path));
  return G_SOURCE_REMOVE;
}

static gboolean do_forget(gpointer data) {
  Command *cmd = data;
  LavaBt *bt = cmd->bt;
  if (bt->bus == NULL) return G_SOURCE_REMOVE;
  GDBusProxy *p = proxy_of(bt, cmd->path, DEVICE_IFACE);
  char *adapter = p ? prop_string(p, "Adapter") : g_strdup("");
  if (p) g_object_unref(p);
  if (adapter[0]) {
    call(bt, adapter, ADAPTER_IFACE, "RemoveDevice", g_variant_new("(o)", cmd->path), -1,
         on_plain, op(bt, "Forget", cmd->path));
  }
  g_free(adapter);
  return G_SOURCE_REMOVE;
}

static gboolean do_set_trusted(gpointer data) {
  Command *cmd = data;
  LavaBt *bt = cmd->bt;
  if (bt->bus == NULL) return G_SOURCE_REMOVE;
  set_property(bt, cmd->path, DEVICE_IFACE, "Trusted", g_variant_new_boolean(cmd->flag),
               on_plain, op(bt, "Trust", cmd->path));
  return G_SOURCE_REMOVE;
}

static gboolean do_set_blocked(gpointer data) {
  Command *cmd = data;
  LavaBt *bt = cmd->bt;
  if (bt->bus == NULL) return G_SOURCE_REMOVE;
  set_property(bt, cmd->path, DEVICE_IFACE, "Blocked", g_variant_new_boolean(cmd->flag),
               on_plain, op(bt, cmd->flag ? "Block" : "Unblock", cmd->path));
  return G_SOURCE_REMOVE;
}

static gboolean do_set_discoverable(gpointer data) {
  Command *cmd = data;
  LavaBt *bt = cmd->bt;
  if (bt->bus == NULL) return G_SOURCE_REMOVE;
  set_property(bt, cmd->path, ADAPTER_IFACE, "Discoverable", g_variant_new_boolean(cmd->flag),
               on_plain, op(bt, "Visibility", cmd->path));
  return G_SOURCE_REMOVE;
}

static gboolean do_set_alias(gpointer data) {
  Command *cmd = data;
  LavaBt *bt = cmd->bt;
  if (bt->bus == NULL) return G_SOURCE_REMOVE;
  // One property name on two interfaces; the object says which it is.
  GDBusProxy *p = proxy_of(bt, cmd->path, DEVICE_IFACE);
  const char *iface = p ? DEVICE_IFACE : ADAPTER_IFACE;
  if (p) g_object_unref(p);
  set_property(bt, cmd->path, iface, "Alias", g_variant_new_string(str(cmd->text)), on_plain,
               op(bt, "Rename", cmd->path));
  return G_SOURCE_REMOVE;
}

static gboolean do_reply(gpointer data) {
  Command *cmd = data;
  LavaBt *bt = cmd->bt;
  Request *r = find_request(bt, cmd->id);
  if (r == NULL) return G_SOURCE_REMOVE;
  bt->requests = g_list_remove(bt->requests, r);
  if (r->invocation == NULL) {
    // A code being shown. "Cancel" on it means stop pairing.
    if (!cmd->flag) {
      g_hash_table_add(bt->declined, g_strdup(r->device));
      call(bt, r->device, DEVICE_IFACE, "CancelPairing", NULL, -1, on_quiet,
           op(bt, "Pair", r->device));
    }
  } else if (!cmd->flag) {
    g_hash_table_add(bt->declined, g_strdup(r->device));
    g_dbus_method_invocation_return_dbus_error(r->invocation, "org.bluez.Error.Rejected",
                                               "Declined");
  } else if (r->kind == LAVA_BT_ASK_PIN) {
    g_dbus_method_invocation_return_value(r->invocation, g_variant_new("(s)", str(cmd->text)));
  } else if (r->kind == LAVA_BT_ASK_PASSKEY) {
    char *end = NULL;
    const unsigned long passkey = strtoul(str(cmd->text), &end, 10);
    if (cmd->text == NULL || end == cmd->text || *end != '\0' || passkey > 999999) {
      g_dbus_method_invocation_return_dbus_error(r->invocation, "org.bluez.Error.Rejected",
                                                 "Not a passkey");
    } else {
      g_dbus_method_invocation_return_value(r->invocation,
                                            g_variant_new("(u)", (guint32)passkey));
    }
  } else {
    g_dbus_method_invocation_return_value(r->invocation, NULL);
  }
  r->invocation = NULL;
  request_free(r);
  return G_SOURCE_REMOVE;
}

static void on_test_reply(GObject *source, GAsyncResult *result, gpointer data) {
  Command *cmd = data;
  GError *error = NULL;
  GVariant *reply = g_dbus_connection_call_finish(G_DBUS_CONNECTION(source), result, &error);
  char *text;
  if (error) {
    char *remote = g_dbus_error_get_remote_error(error);
    text = g_strdup_printf("error %s", remote ? remote : error->message);
    g_free(remote);
    g_error_free(error);
  } else if (g_variant_is_of_type(reply, G_VARIANT_TYPE("(s)"))) {
    const char *s = NULL;
    g_variant_get(reply, "(&s)", &s);
    text = g_strdup_printf("ok %s", s);
  } else if (g_variant_is_of_type(reply, G_VARIANT_TYPE("(u)"))) {
    guint32 u = 0;
    g_variant_get(reply, "(u)", &u);
    text = g_strdup_printf("ok %u", u);
  } else {
    text = g_strdup("ok");
  }
  if (reply) g_variant_unref(reply);
  if (cmd->done) cmd->done(cmd->done_user, text);
  g_free(text);
  command_free(cmd);
}

static gboolean do_test_call(gpointer data) {
  Command *src = data;
  LavaBt *bt = src->bt;
  // The invoke frees `src`; the reply needs a copy that lives until then.
  Command *cmd = command(bt, src->path);
  cmd->method = g_strdup(src->method);
  cmd->text = g_strdup(src->text);
  cmd->number = src->number;
  cmd->done = src->done;
  cmd->done_user = src->done_user;
  if (bt->bus == NULL || bt->agent_object == 0) {
    if (cmd->done) cmd->done(cmd->done_user, "error no agent");
    command_free(cmd);
    return G_SOURCE_REMOVE;
  }
  const char *m = cmd->method;
  const char *device = str(cmd->path);
  GVariant *params = NULL;
  if (!strcmp(m, "RequestPinCode") || !strcmp(m, "RequestPasskey") ||
      !strcmp(m, "RequestAuthorization")) {
    params = g_variant_new("(o)", device);
  } else if (!strcmp(m, "DisplayPinCode") || !strcmp(m, "AuthorizeService")) {
    params = g_variant_new("(os)", device, str(cmd->text));
  } else if (!strcmp(m, "DisplayPasskey")) {
    params = g_variant_new("(ouq)", device, cmd->number, (guint16)atoi(str(cmd->text)));
  } else if (!strcmp(m, "RequestConfirmation")) {
    params = g_variant_new("(ou)", device, cmd->number);
  }
  g_dbus_connection_call(bt->bus, g_dbus_connection_get_unique_name(bt->bus), AGENT_PATH,
                         AGENT_IFACE, m, params, NULL, G_DBUS_CALL_FLAGS_NONE, 120000, NULL,
                         on_test_reply, cmd);
  return G_SOURCE_REMOVE;
}

// ─── Lifetime ───────────────────────────────────────────────────────────────

static void on_tree_changed(gpointer data) { schedule_snapshot(data); }

static void stop_discovery(gpointer key, gpointer value, gpointer data) {
  (void)value;
  LavaBt *bt = data;
  GVariant *reply = g_dbus_connection_call_sync(bt->bus, BLUEZ, key, ADAPTER_IFACE,
                                                "StopDiscovery", NULL, NULL,
                                                G_DBUS_CALL_FLAGS_NONE, 500, NULL, NULL);
  if (reply) g_variant_unref(reply);
}

static gpointer thread_main(gpointer data) {
  LavaBt *bt = data;
  g_main_context_push_thread_default(bt->ctx);

  GError *error = NULL;
  bt->bus = g_bus_get_sync(G_BUS_TYPE_SYSTEM, NULL, &error);
  if (bt->bus == NULL) {
    fprintf(stderr, "lava_bt: no system bus: %s\n", error->message);
    g_clear_error(&error);
  } else {
    // Not auto-started: a machine with no Bluetooth has no business
    // starting bluetoothd because a panel looked.
    bt->manager = g_dbus_object_manager_client_new_sync(
        bt->bus, G_DBUS_OBJECT_MANAGER_CLIENT_FLAGS_DO_NOT_AUTO_START, BLUEZ, "/", NULL, NULL,
        NULL, NULL, &error);
    if (bt->manager == NULL) {
      fprintf(stderr, "lava_bt: no BlueZ object manager: %s\n", error->message);
      g_clear_error(&error);
    } else {
      const char *signals[] = {"object-added", "object-removed", "interface-added",
                               "interface-removed", "interface-proxy-properties-changed"};
      for (size_t i = 0; i < G_N_ELEMENTS(signals); i++) {
        g_signal_connect_swapped(bt->manager, signals[i], G_CALLBACK(on_tree_changed), bt);
      }
      g_signal_connect(bt->manager, "notify::name-owner", G_CALLBACK(on_name_owner), bt);
    }

    // `LAVA_BT_AGENT=0` for a second panel beside a running one: the newer
    // would take the default agent from the first.
    const char *agent_env = g_getenv("LAVA_BT_AGENT");
    if (bt->manager && bt->want_agent && (agent_env == NULL || strcmp(agent_env, "0") != 0)) {
      bt->agent_info = g_dbus_node_info_new_for_xml(agent_xml, NULL);
      bt->agent_object = g_dbus_connection_register_object(
          bt->bus, AGENT_PATH, bt->agent_info->interfaces[0], &agent_vtable, bt, NULL, &error);
      if (bt->agent_object == 0) {
        fprintf(stderr, "lava_bt: agent: %s\n", error->message);
        g_clear_error(&error);
      }
      register_agent(bt);
    }
    // Now, not after the debounce: the manager has already loaded the tree.
    publish(bt);
  }

  g_mutex_lock(&bt->start_lock);
  bt->start_done = 1;
  g_cond_signal(&bt->started);
  g_mutex_unlock(&bt->start_lock);

  g_main_loop_run(bt->loop);

  take_down_all(bt, "org.bluez.Error.Canceled");
  if (bt->pending) {
    g_source_destroy(bt->pending);
    g_source_unref(bt->pending);
    bt->pending = NULL;
  }
  if (bt->bus) {
    // BlueZ would notice the name going, but a session destroyed inside a
    // process that goes on running would leave both behind.
    g_hash_table_foreach(bt->discovering, stop_discovery, bt);
    if (bt->agent_object) {
      GVariant *reply = g_dbus_connection_call_sync(
          bt->bus, BLUEZ, "/org/bluez", AGENT_MANAGER_IFACE, "UnregisterAgent",
          g_variant_new("(o)", AGENT_PATH), NULL, G_DBUS_CALL_FLAGS_NONE, 500, NULL, NULL);
      if (reply) g_variant_unref(reply);
      g_dbus_connection_unregister_object(bt->bus, bt->agent_object);
      bt->agent_object = 0;
    }
  }
  if (bt->manager) {
    g_signal_handlers_disconnect_by_data(bt->manager, bt);
    g_object_unref(bt->manager);
    bt->manager = NULL;
  }
  g_clear_object(&bt->bus);
  if (bt->agent_info) g_dbus_node_info_unref(bt->agent_info);
  while (g_main_context_iteration(bt->ctx, FALSE)) {
  }
  g_main_context_pop_thread_default(bt->ctx);
  return NULL;
}

LavaBt *lava_bt_create(const LavaBtCallbacks *callbacks, void *user, int agent) {
  LavaBt *bt = g_new0(LavaBt, 1);
  if (callbacks) bt->cb = *callbacks;
  bt->user = user;
  bt->busy = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  bt->discovering = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  bt->declined = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
  bt->ctx = g_main_context_new();
  bt->loop = g_main_loop_new(bt->ctx, FALSE);
  g_mutex_init(&bt->start_lock);
  g_cond_init(&bt->started);
  bt->want_agent = agent != 0;
  bt->thread = g_thread_new("lava-bt", thread_main, bt);
  g_mutex_lock(&bt->start_lock);
  while (!bt->start_done) g_cond_wait(&bt->started, &bt->start_lock);
  g_mutex_unlock(&bt->start_lock);
  return bt;
}

static gboolean do_quit(gpointer data) {
  g_main_loop_quit(data);
  return G_SOURCE_REMOVE;
}

void lava_bt_destroy(LavaBt *bt) {
  if (bt == NULL) return;
  g_main_context_invoke(bt->ctx, do_quit, bt->loop);
  g_thread_join(bt->thread);
  g_hash_table_unref(bt->busy);
  g_hash_table_unref(bt->discovering);
  g_hash_table_unref(bt->declined);
  g_main_loop_unref(bt->loop);
  g_main_context_unref(bt->ctx);
  g_mutex_clear(&bt->start_lock);
  g_cond_clear(&bt->started);
  g_free(bt);
}

void lava_bt_set_powered(LavaBt *bt, const char *adapter, int on) {
  Command *cmd = command(bt, adapter);
  cmd->flag = on;
  run(bt, do_set_powered, cmd);
}

void lava_bt_set_discovering(LavaBt *bt, const char *adapter, int on) {
  Command *cmd = command(bt, adapter);
  cmd->flag = on;
  run(bt, do_set_discovering, cmd);
}

void lava_bt_pair(LavaBt *bt, const char *device) { run(bt, do_pair, command(bt, device)); }

void lava_bt_connect(LavaBt *bt, const char *device) {
  run(bt, do_connect, command(bt, device));
}

void lava_bt_disconnect(LavaBt *bt, const char *device) {
  run(bt, do_disconnect, command(bt, device));
}

void lava_bt_forget(LavaBt *bt, const char *device) { run(bt, do_forget, command(bt, device)); }

void lava_bt_set_trusted(LavaBt *bt, const char *device, int on) {
  Command *cmd = command(bt, device);
  cmd->flag = on;
  run(bt, do_set_trusted, cmd);
}

void lava_bt_agent_reply(LavaBt *bt, uint64_t id, int accept, const char *text) {
  Command *cmd = command(bt, NULL);
  cmd->id = id;
  cmd->flag = accept;
  cmd->text = g_strdup(text);
  run(bt, do_reply, cmd);
}

void lava_bt_test_call_agent(LavaBt *bt, const char *method, const char *device,
                             uint32_t number, const char *text, LavaBtTestDone done,
                             void *user) {
  Command *cmd = command(bt, device);
  cmd->method = g_strdup(method);
  cmd->number = number;
  cmd->text = g_strdup(text);
  cmd->done = done;
  cmd->done_user = user;
  run(bt, do_test_call, cmd);
}

void lava_bt_set_blocked(LavaBt *bt, const char *device, int on) {
  Command *cmd = command(bt, device);
  cmd->flag = on;
  run(bt, do_set_blocked, cmd);
}

void lava_bt_set_discoverable(LavaBt *bt, const char *adapter, int on) {
  Command *cmd = command(bt, adapter);
  cmd->flag = on;
  run(bt, do_set_discoverable, cmd);
}

void lava_bt_set_alias(LavaBt *bt, const char *path, const char *alias) {
  Command *cmd = command(bt, path);
  cmd->text = g_strdup(alias);
  run(bt, do_set_alias, cmd);
}
