#include "lava_udisks.h"
#include <systemd/sd-bus.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SERVICE "org.freedesktop.UDisks2"
#define ROOT "/org/freedesktop/UDisks2"
#define FS SERVICE ".Filesystem"
#define TRY(call) do { int status = (call); if (status < 0) return status; } while (0)

typedef struct Record {
    char *object, *device, *label, *hint, *filesystem, *partition, *drive, *model, *bus;
    char **mounts;
    size_t mount_count;
    uint64_t size;
    int has_fs, ignored, removable, loop;
    struct Record *next;
} Record;

static void free_records(Record *record) {
    while (record) {
        Record *next = record->next;
        free(record->object); free(record->device); free(record->label);
        free(record->hint); free(record->filesystem); free(record->partition);
        free(record->drive); free(record->model); free(record->bus);
        for (size_t i = 0; i < record->mount_count; ++i) free(record->mounts[i]);
        free(record->mounts); free(record);
        record = next;
    }
}

static int read_string(sd_bus_message *message, const char *type, char **out) {
    const char *value = NULL;
    TRY(sd_bus_message_read(message, type, &value));
    char *copy = strdup(value ? value : "");
    if (!copy) return -ENOMEM;
    free(*out); *out = copy;
    return 0;
}

static int read_bytes(sd_bus_message *message, char **out) {
    const void *bytes = NULL;
    size_t size = 0;
    TRY(sd_bus_message_read_array(message, 'y', &bytes, &size));
    char *copy = strndup(bytes ? bytes : "", size);
    if (!copy) return -ENOMEM;
    free(*out); *out = copy;
    return 0;
}

static int property(sd_bus_message *message, Record *record, const char *iface,
                    const char *name, const char *signature) {
    if (!strcmp(iface, SERVICE ".Block")) {
        if (!strcmp(name, "PreferredDevice")) return read_bytes(message, &record->device);
        if (!strcmp(name, "IdLabel")) return read_string(message, "s", &record->label);
        if (!strcmp(name, "HintName")) return read_string(message, "s", &record->hint);
        if (!strcmp(name, "IdType")) return read_string(message, "s", &record->filesystem);
        if (!strcmp(name, "Drive")) return read_string(message, "o", &record->drive);
        if (!strcmp(name, "HintIgnore")) return sd_bus_message_read(message, "b", &record->ignored);
        if (!strcmp(name, "Size")) return sd_bus_message_read(message, "t", &record->size);
    } else if (!strcmp(iface, SERVICE ".Partition") && !strcmp(name, "Type")) {
        return read_string(message, "s", &record->partition);
    } else if (!strcmp(iface, SERVICE ".Drive")) {
        if (!strcmp(name, "Model")) return read_string(message, "s", &record->model);
        if (!strcmp(name, "ConnectionBus")) return read_string(message, "s", &record->bus);
        if (!strcmp(name, "Removable")) return sd_bus_message_read(message, "b", &record->removable);
    } else if (!strcmp(iface, FS) && !strcmp(name, "MountPoints")) {
        TRY(sd_bus_message_enter_container(message, 'a', "ay"));
        while (!sd_bus_message_at_end(message, 0)) {
            char **mounts = realloc(record->mounts, (record->mount_count + 1) * sizeof(char *));
            if (!mounts) return -ENOMEM;
            record->mounts = mounts;
            record->mounts[record->mount_count] = NULL;
            TRY(read_bytes(message, &record->mounts[record->mount_count]));
            record->mount_count++;
        }
        return sd_bus_message_exit_container(message);
    }
    return sd_bus_message_skip(message, signature);
}

static int read_record(sd_bus_message *message, Record *record) {
    TRY(read_string(message, "o", &record->object));
    TRY(sd_bus_message_enter_container(message, 'a', "{sa{sv}}"));
    int r;
    while ((r = sd_bus_message_enter_container(message, 'e', "sa{sv}")) > 0) {
        const char *iface;
        TRY(sd_bus_message_read(message, "s", &iface));
        if (!strcmp(iface, FS)) record->has_fs = 1;
        if (!strcmp(iface, SERVICE ".Loop")) record->loop = 1;
        TRY(sd_bus_message_enter_container(message, 'a', "{sv}"));
        while ((r = sd_bus_message_enter_container(message, 'e', "sv")) > 0) {
            const char *name, *signature;
            TRY(sd_bus_message_read(message, "s", &name));
            TRY(sd_bus_message_peek_type(message, NULL, &signature));
            TRY(sd_bus_message_enter_container(message, 'v', signature));
            TRY(property(message, record, iface, name, signature));
            TRY(sd_bus_message_exit_container(message));
            TRY(sd_bus_message_exit_container(message));
        }
        if (r < 0) return r;
        TRY(sd_bus_message_exit_container(message));
        TRY(sd_bus_message_exit_container(message));
    }
    if (r < 0) return r;
    return sd_bus_message_exit_container(message);
}

static void describe_error(char *out, size_t size, const sd_bus_error *error, int status) {
    snprintf(out, size, "%s", error->message ? error->message : strerror(-status));
}

int lava_disks_list(LavaDiskVolumeFn callback, void *user, char *error_text, size_t error_size) {
    sd_bus *bus = NULL;
    sd_bus_message *reply = NULL;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    Record *records = NULL;
    int r = sd_bus_open_system(&bus);
    if (r < 0) goto done;
    r = sd_bus_call_method(bus, SERVICE, ROOT, "org.freedesktop.DBus.ObjectManager",
                           "GetManagedObjects", &error, &reply, "");
    if (r < 0) goto done;
    r = sd_bus_message_enter_container(reply, 'a', "{oa{sa{sv}}}");
    if (r < 0) goto done;
    while ((r = sd_bus_message_enter_container(reply, 'e', "oa{sa{sv}}")) > 0) {
        Record *record = calloc(1, sizeof(Record));
        if (!record) { r = -ENOMEM; goto done; }
        record->next = records; records = record;
        r = read_record(reply, record);
        if (r < 0) goto done;
        r = sd_bus_message_exit_container(reply);
        if (r < 0) goto done;
    }
    if (r < 0) goto done;
    for (Record *record = records; record; record = record->next) {
        if (!record->has_fs || record->loop || !record->device) continue;
        Record *drive = NULL;
        for (Record *candidate = records; candidate; candidate = candidate->next) {
            if (record->drive && !strcmp(candidate->object, record->drive)) { drive = candidate; break; }
        }
        LavaDiskVolume volume = {
            .object_path = record->object, .device = record->device, .label = record->label,
            .hint_name = record->hint, .filesystem = record->filesystem,
            .partition_type = record->partition, .model = drive ? drive->model : NULL,
            .mount_points = (const char **)record->mounts, .mount_count = record->mount_count,
            .size = record->size, .ignored = record->ignored,
            .external = drive && (drive->removable || (drive->bus && !strcmp(drive->bus, "usb")))
        };
        callback(user, &volume);
    }
    r = 0;
done:
    if (r < 0) describe_error(error_text, error_size, &error, r);
    free_records(records);
    sd_bus_error_free(&error); sd_bus_message_unref(reply); sd_bus_unref(bus);
    return r;
}

int lava_disks_mount(const char *object_path, int unmount, char *result, size_t result_size,
                     char *error_text, size_t error_size) {
    sd_bus *bus = NULL;
    sd_bus_message *call = NULL, *reply = NULL;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    int r = sd_bus_open_system(&bus);
    if (r < 0) goto done;
    r = sd_bus_message_new_method_call(bus, &call, SERVICE, object_path, FS, unmount ? "Unmount" : "Mount");
    if (r < 0) goto done;
    r = sd_bus_message_set_allow_interactive_authorization(call, 1);
    if (r < 0) goto done;
    r = sd_bus_message_open_container(call, 'a', "{sv}");
    if (r < 0) goto done;
    r = sd_bus_message_close_container(call);
    if (r < 0) goto done;
    // Authentication and filesystem checks can take longer than a frame or an ordinary RPC.
    r = sd_bus_call(bus, call, 120000000, &error, &reply);
    if (r < 0) goto done;
    const char *path = "";
    if (!unmount) {
        r = sd_bus_message_read(reply, "s", &path);
        if (r < 0) goto done;
    }
    if (strlen(path) >= result_size) { r = -ENAMETOOLONG; goto done; }
    snprintf(result, result_size, "%s", path);
    r = 0;
done:
    if (r < 0) describe_error(error_text, error_size, &error, r);
    sd_bus_error_free(&error); sd_bus_message_unref(call); sd_bus_message_unref(reply); sd_bus_unref(bus);
    return r;
}
