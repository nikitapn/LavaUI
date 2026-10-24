#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

// All strings are borrowed for the duration of the callback.
typedef struct LavaDiskVolume {
    const char *object_path;
    const char *device;
    const char *label;
    const char *hint_name;
    const char *filesystem;
    const char *partition_type;
    const char *model;
    const char **mount_points;
    size_t mount_count;
    uint64_t size;
    int external;
    int ignored;
} LavaDiskVolume;
typedef void (*LavaDiskVolumeFn)(void *user, const LavaDiskVolume *volume);

// Blocking system-bus calls. Run on a worker, never on the frame loop.
int lava_disks_list(LavaDiskVolumeFn callback, void *user, char *error, size_t error_size);
// Mount returns its path, unmount returns an empty string. No forced unmounts.
int lava_disks_mount(const char *object_path, int unmount, char *result, size_t result_size,
                     char *error, size_t error_size);
#ifdef __cplusplus
}
#endif
