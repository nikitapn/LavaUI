#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef LEGACY
void lava_editor_reusable_host_v1(void) {}
#endif

static void crash(void) { raise(SIGKILL); }

int32_t lava_editor_activate_v1(const char *command, const char *reference, uint64_t token) {
    static int calls;
    ++calls;
    if (!strcmp(command, "first")) return calls != 1 || token != 1234;
    if (!strcmp(command, "second")) return calls != 2 || token != 9876;
    if (!strcmp(command, "crash")) crash();
    if (!strcmp(command, "teardown")) return atexit(crash);
    if (!strcmp(command, "hang")) {
        if (fork() == 0) {
            if (setsid() < 0) _exit(2);
            if (fork() == 0) {
                if (setsid() < 0) _exit(2);
                FILE *file = fopen(reference, "w");
                if (!file) _exit(2);
                fprintf(file, "%d %d\n", getppid(), getpid());
                fclose(file);
            }
        }
        for (;;) pause();
    }
    if (!strcmp(command, "swift-test")) {
        pid_t child = fork();
        if (!child) {
            if (setsid() < 0) _exit(2);
            execlp("swift", "swift", "test", "--build-system", "native", "--package-path", reference, "--skip-build", "--filter", "testWait", NULL);
            _exit(2);
        }
        FILE *file = fopen(getenv("TEST_CLI_PID"), "w");
        if (!file) return 2;
        fprintf(file, "%d\n", child);
        fclose(file);
        waitpid(child, NULL, 0);
    }
    return 2;
}
