#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct { int fd, supervisor; } LavaExtensionProcess;
int lava_extension_start(const char *library, LavaExtensionProcess *process);
int lava_extension_connected(LavaExtensionProcess process);
// Returns errno on transport failure. A successful exchange sets status and reusable.
int lava_extension_invoke(LavaExtensionProcess process, const char *command, const char *reference,
                          uint64_t token, int timeout_ms, int keep_alive, int *status, int *reusable);
void lava_extension_close(LavaExtensionProcess process);
int lava_extension_supervise(const char *library);
int lava_extension_worker(const char *library);

#ifdef __cplusplus
}
#endif
