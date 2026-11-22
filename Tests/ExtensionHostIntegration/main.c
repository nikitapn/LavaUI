#include "extension_host.h"
#include <assert.h>
#include <errno.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static LavaExtensionProcess start(const char *library) {
    LavaExtensionProcess process;
    assert(lava_extension_start(library, &process) == 0);
    return process;
}

static void gone(int pid) {
    assert(pid > 1);
    assert(kill(pid, 0) == -1 && errno == ESRCH);
}

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--extension-supervisor")) return lava_extension_supervise(argv[2]);
    if (argc == 3 && !strcmp(argv[1], "--extension-worker")) return lava_extension_worker(argv[2]);
    assert(argc == 4);
    int status, reuse;
    LavaExtensionProcess p = start(argv[1]);
    assert(!lava_extension_invoke(p, "first", "", 1234, 2000, 1, &status, &reuse) && !status && reuse);
    assert(!lava_extension_invoke(p, "second", "", 9876, 2000, 1, &status, &reuse) && !status && reuse);
    assert(lava_extension_invoke(p, "crash", "", 1, 2000, 1, &status, &reuse) == EPIPE);
    lava_extension_close(p);
    for (int i = 0; i < 2; i++) {
        p = start(argv[1+i]);
        assert(!lava_extension_invoke(p, "first", "", 1234, 2000, i, &status, &reuse) && !status && !reuse);
        lava_extension_close(p);
    }
    p = start(argv[1]);
    assert(lava_extension_invoke(p, "teardown", "", 1, 2000, 0, &status, &reuse) == EPIPE);
    lava_extension_close(p);
    p = start(argv[1]);
    assert(lava_extension_invoke(p, "hang", argv[3], 1, 1500, 0, &status, &reuse) == ETIMEDOUT);
    FILE *file = fopen(argv[3], "r");
    int child, grandchild;
    assert(file && fscanf(file, "%d %d", &child, &grandchild) == 2);
    fclose(file);
    assert(getsid(child) == child && getsid(grandchild) == grandchild);
    lava_extension_close(p);
    gone(child);
    gone(grandchild);

    if (getenv("TEST_SWIFT_PACKAGE")) {
        p = start(argv[1]);
        assert(lava_extension_invoke(p, "swift-test", getenv("TEST_SWIFT_PACKAGE"), 1, 5000, 0, &status, &reuse) == ETIMEDOUT);
        lava_extension_close(p);
        const char *paths[] = {getenv("TEST_CLI_PID"), getenv("TEST_CASE_PID")};
        for (int i = 0; i < 2; ++i) {
            file = fopen(paths[i], "r");
            assert(file && fscanf(file, "%d", &child) == 1);
            fclose(file);
            gone(child);
        }
    }
    puts("Extension host checks passed");
}
