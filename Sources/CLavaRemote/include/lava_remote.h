#pragma once

// FTP, FTPS and SFTP through libcurl, and passwords through libsecret, behind
// a C API with no variadic calls in it — Swift cannot make one, and
// `curl_easy_setopt` and `secret_password_lookup_sync` are nothing else.
//
// Everything here blocks. Call it from a worker thread, one call at a time
// per handle: a handle is one connection, kept open between calls so that
// opening a folder after the last one costs a round trip, not a login.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// What went wrong, in the terms the explorer answers differently.
typedef enum {
  LAVA_REMOTE_OK = 0,
  /// The server refused the name and password, or wanted one and had none.
  LAVA_REMOTE_LOGIN = 1,
  LAVA_REMOTE_NOT_FOUND = 2,
  /// An SSH server whose key is not the one `known_hosts` has for it.
  LAVA_REMOTE_HOST_KEY = 3,
  /// TLS would not come up, or the certificate is not one we trust.
  LAVA_REMOTE_TLS = 4,
  /// No such host, nothing listening, or no answer in time.
  LAVA_REMOTE_CONNECT = 5,
  LAVA_REMOTE_CANCELLED = 6,
  LAVA_REMOTE_FAILED = 7,
} lava_remote_code;

typedef struct {
  int code;
  /// The protocol's last reply (FTP's 550, say), or 0.
  long response;
  /// curl's own explanation, for the status line.
  char message[256];
} lava_remote_result;

/// Bytes moved so far and the total, when known (0 otherwise). Nonzero from
/// the callback stops the transfer, which then fails as cancelled.
typedef int (*lava_remote_progress_fn)(void *context, int64_t done, int64_t total);

typedef struct lava_remote lava_remote;

/// One connection to one server, `host` on `port`. `known_hosts` is the
/// OpenSSH file an SFTP host key is checked against and, the first time a
/// host is seen, has a line appended to — `StrictHostKeyChecking=accept-new`.
/// A key that differs from the one on file is refused. `ca_file`, if not
/// NULL, is trusted for TLS in place of the system's roots. `require_tls`
/// turns an `ftp://` connection into explicit FTPS (`AUTH TLS` on the
/// ordinary port), refusing to go on in the clear.
lava_remote *lava_remote_open(const char *host, int port, const char *known_hosts,
                              const char *ca_file, int require_tls);
void lava_remote_close(lava_remote *remote);

/// The SFTP key to log in with from now on — a private key file, its public
/// half worked out from it — or NULL for none. `use_agent` zero leaves the
/// agent out, as OpenSSH's `IdentitiesOnly` does. A password given to a call
/// is also tried as the key's passphrase.
void lava_remote_set_identity(lava_remote *remote, const char *private_key,
                              int use_agent);

/// The listing of the folder at `url`, which ends in "/". `mlsd` asks an FTP
/// server for its machine-readable listing rather than `ls -l` text. `*out`
/// is NUL-terminated and freed with `lava_remote_free`.
int lava_remote_list(lava_remote *remote, const char *url, const char *user,
                     const char *password, int mlsd, char **out, size_t *length,
                     lava_remote_result *result);

/// The file at `url`, written to `destination` (created or truncated).
int lava_remote_download(lava_remote *remote, const char *url, const char *user,
                         const char *password, const char *destination,
                         lava_remote_progress_fn progress, void *context,
                         lava_remote_result *result);

/// `source` written to `url`, making any folders on the way that are missing.
int lava_remote_upload(lava_remote *remote, const char *url, const char *user,
                       const char *password, const char *source,
                       lava_remote_progress_fn progress, void *context,
                       lava_remote_result *result);

/// Runs one protocol command once curl is in the folder `url` — `MKD name`
/// for FTP, `mkdir "/path"` for SFTP. Nothing is transferred.
int lava_remote_command(lava_remote *remote, const char *url, const char *user,
                        const char *password, const char *command,
                        lava_remote_result *result);

void lava_remote_free(void *pointer);

/// The password the keyring holds for this server and user, or NULL. Freed
/// with `lava_remote_free`. Stored under the network-password schema GNOME
/// Files and gvfs use, so a server saved there is found here too.
char *lava_secret_lookup(const char *protocol, const char *server, int port,
                         const char *user);
/// Nonzero when it was stored. `label` is what a keyring manager shows.
int lava_secret_store(const char *protocol, const char *server, int port,
                      const char *user, const char *password, const char *label);
/// Forgets it. Nonzero when something was there.
int lava_secret_clear(const char *protocol, const char *server, int port,
                      const char *user);

#ifdef __cplusplus
}
#endif
