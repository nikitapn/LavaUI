#define _GNU_SOURCE
#include "extension_host.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;
enum { control_fd = 3, max_packet = 16384 };
enum { complete, reusable_worker, worker_exited };
typedef struct { int status, kind; } Reply;
typedef int32_t (*Activate)(const char *, const char *, uint64_t);

static int spawn_host(const char *mode, const char *library, int fd, pid_t *pid) {
    char *args[] = {"LavaEditor", (char *)mode, (char *)library, NULL};
    posix_spawn_file_actions_t files;
    int err = posix_spawn_file_actions_init(&files);
    if (err) return err;
    err = posix_spawn_file_actions_adddup2(&files, fd, control_fd);
    if (!err) err = posix_spawn_file_actions_addclosefrom_np(&files, control_fd + 1);
    posix_spawnattr_t attrs;
    if (!err && !(err = posix_spawnattr_init(&attrs))) {
        err = posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETPGROUP);
        if (!err) err = posix_spawn(pid, "/proc/self/exe", &files, &attrs, args, environ);
        posix_spawnattr_destroy(&attrs);
    }
    posix_spawn_file_actions_destroy(&files);
    return err;
}

int lava_extension_start(const char *library, LavaExtensionProcess *process) {
    int pair[2];
    if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, pair) < 0) return errno;
    pid_t pid;
    int err = spawn_host("--extension-supervisor", library, pair[1], &pid);
    close(pair[1]);
    if (err) { close(pair[0]); return err; }
    *process = (LavaExtensionProcess){pair[0], pid};
    return 0;
}

int lava_extension_connected(LavaExtensionProcess process) {
    struct pollfd p = {.fd = process.fd, .events = POLLRDHUP};
    int n;
    do { n = poll(&p, 1, 0); } while (n < 0 && errno == EINTR);
    return n == 0;
}

static int64_t milliseconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int receive_reply(int fd, int64_t end, Reply *reply) {
    struct pollfd p = {.fd = fd, .events = POLLIN};
    for (;;) {
        int64_t left = end - milliseconds();
        if (left <= 0) return ETIMEDOUT;
        int n = poll(&p, 1, (int)left);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) return errno;
        if (!n) return ETIMEDOUT;
        ssize_t bytes = recv(fd, reply, sizeof(*reply), MSG_DONTWAIT | MSG_TRUNC);
        if (bytes < 0 && errno == EINTR) continue;
        return bytes == sizeof(*reply) ? 0 : EPIPE;
    }
}

int lava_extension_invoke(LavaExtensionProcess process, const char *command, const char *reference,
                          uint64_t token, int timeout_ms, int keep_alive, int *status, int *reusable) {
    size_t c = strlen(command) + 1, r = strlen(reference) + 1;
    unsigned char persist = keep_alive != 0;
    if (sizeof(token) + 1 + c + r > max_packet) return EMSGSIZE;
    struct iovec fields[] = {{&token, sizeof(token)}, {&persist, 1}, {(void *)command, c}, {(void *)reference, r}};
    struct msghdr packet = {.msg_iov = fields, .msg_iovlen = 4};
    ssize_t sent;
    do { sent = sendmsg(process.fd, &packet, MSG_NOSIGNAL | MSG_DONTWAIT); } while (sent < 0 && errno == EINTR);
    if (sent < 0) return errno;
    int64_t end = milliseconds() + timeout_ms;
    Reply reply;
    int err = receive_reply(process.fd, end, &reply);
    if (err) return err;
    if (reply.kind != reusable_worker && reply.kind != complete) return EPIPE;
    *status = reply.status;
    *reusable = reply.kind == reusable_worker;
    if (!*reusable && !*status) {
        // A formatter can crash during teardown after proposing an edit.
        err = receive_reply(process.fd, end, &reply);
        if (err) return err;
        if (reply.kind != worker_exited || reply.status) return EPIPE;
    }
    return 0;
}

void lava_extension_close(LavaExtensionProcess process) {
    close(process.fd);
    while (waitpid(process.supervisor, NULL, 0) < 0 && errno == EINTR) {}
}

// Kill our unreaped children, then repeat as orphans are adopted. Only this
// worker's descendants can become children of this dedicated subreaper.
static void reap_tree(void) {
    for (;;) {
        pid_t pid = waitpid(-1, NULL, WNOHANG);
        if (pid > 0 || (pid < 0 && errno == EINTR)) continue;
        if (pid < 0 && errno == ECHILD) return;
        FILE *children = fopen("/proc/thread-self/children", "re");
        if (children) {
            int child;
            while (fscanf(children, "%d", &child) == 1) kill(child, SIGKILL);
            fclose(children);
        }
        usleep(1000);
    }
}

static int send_reply(int status, int kind) {
    Reply reply = {status, kind};
    ssize_t n;
    do { n = send(control_fd, &reply, sizeof(reply), MSG_NOSIGNAL); } while (n < 0 && errno == EINTR);
    return n == sizeof(reply);
}

int lava_extension_supervise(const char *library) {
    if (prctl(PR_SET_CHILD_SUBREAPER, 1) < 0 || access("/proc/thread-self/children", R_OK) < 0) return 2;
    pid_t worker;
    if (spawn_host("--extension-worker", library, control_fd, &worker)) return 2;
    int pidfd = syscall(SYS_pidfd_open, worker, 0);
    // Requests belong to the worker. The supervisor watches the editor's end
    // closing (timeout, reload or editor exit) and the worker's actual death.
    struct pollfd watch[] = {{.fd = control_fd, .events = POLLRDHUP}, {.fd = pidfd, .events = POLLIN}};
    int clean = 0;
    for (;;) {
        int n = poll(watch, 2, pidfd < 0 ? 100 : -1);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 || watch[0].revents) break;
        int status;
        if (waitpid(worker, &status, WNOHANG) == worker) {
            clean = WIFEXITED(status) && WEXITSTATUS(status) == 0;
            break;
        }
    }
    reap_tree();
    send_reply(clean ? 0 : 1, worker_exited);
    return 0;
}

int lava_extension_worker(const char *library) {
    if (fcntl(control_fd, F_SETFD, FD_CLOEXEC) < 0) return 2;
    void *module = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!module) return 2;
    Activate activate = (Activate)dlsym(module, "lava_editor_activate_v1");
    if (!activate) return 2;
    int reusable = dlsym(module, "lava_editor_reusable_host_v1") != NULL;
    for (;;) {
        char data[max_packet];
        ssize_t n = recv(control_fd, data, sizeof(data), MSG_TRUNC);
        if (n < 0 && errno == EINTR) continue;
        if (!n) return 0;
        if (n <= (ssize_t)sizeof(uint64_t) + 1 || n > max_packet || data[n - 1]) return 2;
        uint64_t token;
        memcpy(&token, data, sizeof(token));
        int persist = reusable && data[sizeof(token)];
        char *command = data + sizeof(token) + 1;
        char *reference = command + strlen(command) + 1;
        if (reference >= data + n) return 2;
        int status = activate(command, reference, token);
        if (!send_reply(status, persist ? reusable_worker : complete)) return 2;
        if (!persist || status) return status;
    }
}
