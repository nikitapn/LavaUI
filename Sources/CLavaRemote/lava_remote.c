#include "lava_remote.h"

#include <curl/curl.h>
#include <fcntl.h>
#include <libsecret/secret.h>
#include <libssh2.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

struct lava_remote {
  CURL *curl;
  char *host;
  int port;
  char *known_hosts;
  char *ca_file;
  char *private_key;
  int use_agent;
  int require_tls;
  /// Set by the host-key callback, read back to tell a changed key from any
  /// other refusal: curl reports both as a failed peer verification.
  int host_key_refused;
};

static pthread_once_t global_once = PTHREAD_ONCE_INIT;

static void global_init(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }

static char *copy(const char *text) { return text ? strdup(text) : NULL; }

lava_remote *lava_remote_open(const char *host, int port, const char *known_hosts,
                              const char *ca_file, int require_tls) {
  pthread_once(&global_once, global_init);
  CURL *curl = curl_easy_init();
  if (!curl) return NULL;
  lava_remote *remote = calloc(1, sizeof *remote);
  if (!remote) {
    curl_easy_cleanup(curl);
    return NULL;
  }
  remote->curl = curl;
  remote->host = copy(host);
  remote->port = port;
  remote->known_hosts = copy(known_hosts);
  remote->ca_file = copy(ca_file);
  remote->require_tls = require_tls;
  remote->use_agent = 1;
  return remote;
}

void lava_remote_set_identity(lava_remote *remote, const char *private_key,
                              int use_agent) {
  free(remote->private_key);
  remote->private_key = copy(private_key);
  remote->use_agent = use_agent;
}

void lava_remote_close(lava_remote *remote) {
  if (!remote) return;
  curl_easy_cleanup(remote->curl);
  free(remote->host);
  free(remote->known_hosts);
  free(remote->ca_file);
  free(remote->private_key);
  free(remote);
}

void lava_remote_free(void *pointer) { free(pointer); }

// ─── Host keys ──────────────────────────────────────────────────────────────
//
// Checked here rather than by handing curl the file. Given `known_hosts`,
// curl looks the host up *without its port* and, finding it, restricts the
// key exchange to that entry's key type — so an SFTP server on 2222 beside an
// sshd on 22 with another kind of key could not be reached at all ("Unable
// to exchange encryption keys"). libssh2's own reader is used instead, asked
// about exactly the name OpenSSH files the host under: `host` on port 22,
// `[host]:port` otherwise. Hashed entries match too: OpenSSH hashes that
// same name.

/// The libssh2 key-type bits for a key blob, from the type name it starts
/// with; 0 for a kind libssh2 cannot file.
static int key_bits(const char *key, size_t length) {
  if (length < 4) return 0;
  const unsigned char *b = (const unsigned char *)key;
  size_t n = ((size_t)b[0] << 24) | ((size_t)b[1] << 16) | ((size_t)b[2] << 8) | b[3];
  if (n > length - 4) return 0;
  const char *name = key + 4;
  struct {
    const char *name;
    int bits;
  } kinds[] = {
      {"ssh-ed25519", LIBSSH2_KNOWNHOST_KEY_ED25519},
      {"ssh-rsa", LIBSSH2_KNOWNHOST_KEY_SSHRSA},
      {"ecdsa-sha2-nistp256", LIBSSH2_KNOWNHOST_KEY_ECDSA_256},
      {"ecdsa-sha2-nistp384", LIBSSH2_KNOWNHOST_KEY_ECDSA_384},
      {"ecdsa-sha2-nistp521", LIBSSH2_KNOWNHOST_KEY_ECDSA_521},
      {"ssh-dss", LIBSSH2_KNOWNHOST_KEY_SSHDSS},
  };
  for (size_t i = 0; i < sizeof kinds / sizeof kinds[0]; i++) {
    if (strlen(kinds[i].name) == n && memcmp(kinds[i].name, name, n) == 0) {
      return kinds[i].bits;
    }
  }
  return 0;
}

/// Appends one line, never rewriting the file: libssh2 can write the whole
/// file back, but it would drop every line it did not understand — a
/// certificate authority, a key type newer than it — from the user's own.
static void append_line(const char *path, const char *line, size_t length) {
  int fd = open(path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
  if (fd < 0) return;
  // A file that does not end in a newline would glue this onto its last line.
  off_t size = lseek(fd, 0, SEEK_END);
  if (size > 0) {
    char last = '\n';
    if (pread(fd, &last, 1, size - 1) == 1 && last != '\n') {
      if (write(fd, "\n", 1) != 1) {
        close(fd);
        return;
      }
    }
  }
  if (write(fd, line, length) != (ssize_t)length) {
    // Nothing to undo that would not be worse; the next connect asks again.
  }
  close(fd);
}

static int check_host_key(void *context, int keytype, const char *key,
                          size_t length) {
  (void)keytype;
  lava_remote *remote = context;
  int bits = key_bits(key, length);
  if (!bits || !remote->host) {
    remote->host_key_refused = 1;
    return CURLKHMATCH_MISMATCH;
  }
  char name[512];
  if (remote->port == 22 || remote->port <= 0) {
    snprintf(name, sizeof name, "%s", remote->host);
  } else {
    snprintf(name, sizeof name, "[%s]:%d", remote->host, remote->port);
  }
  LIBSSH2_SESSION *session = libssh2_session_init();
  LIBSSH2_KNOWNHOSTS *hosts = session ? libssh2_knownhost_init(session) : NULL;
  if (!hosts) {
    if (session) libssh2_session_free(session);
    remote->host_key_refused = 1;
    return CURLKHMATCH_MISMATCH;
  }
  // Missing or unreadable is an empty file: every host is new.
  libssh2_knownhost_readfile(hosts, remote->known_hosts, LIBSSH2_KNOWNHOST_FILE_OPENSSH);
  const int type = LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW | bits;
  struct libssh2_knownhost *found = NULL;
  int answer;
  switch (libssh2_knownhost_check(hosts, name, key, length, type, &found)) {
  case LIBSSH2_KNOWNHOST_CHECK_MATCH:
    answer = CURLKHMATCH_OK;
    break;
  case LIBSSH2_KNOWNHOST_CHECK_NOTFOUND: {
    // First sight: trusted, and written down for next time.
    struct libssh2_knownhost *entry = NULL;
    if (libssh2_knownhost_addc(hosts, name, NULL, key, length, NULL, 0, type, &entry) == 0) {
      char line[8192];
      size_t used = 0;
      if (libssh2_knownhost_writeline(hosts, entry, line, sizeof line, &used,
                                      LIBSSH2_KNOWNHOST_FILE_OPENSSH) == 0) {
        append_line(remote->known_hosts, line, used);
      }
    }
    answer = CURLKHMATCH_OK;
    break;
  }
  default:
    // A different key for this name, or a check that could not be made.
    remote->host_key_refused = 1;
    answer = CURLKHMATCH_MISMATCH;
    break;
  }
  libssh2_knownhost_free(hosts);
  libssh2_session_free(session);
  return answer;
}

// ─── One request ────────────────────────────────────────────────────────────

/// The options every request shares. `curl_easy_reset` keeps the handle's
/// live connection, which is the point of keeping a handle at all.
static void prepare(lava_remote *remote, const char *url, const char *user,
                    const char *password, char *error_buffer) {
  CURL *curl = remote->curl;
  curl_easy_reset(curl);
  remote->host_key_refused = 0;
  curl_easy_setopt(curl, CURLOPT_URL, url);
  curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, error_buffer);
  // Worker threads: no SIGALRM for DNS timeouts.
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT, 15L);
  // Not a total timeout — a large file over a slow line is allowed to take
  // as long as it takes — but a minute with nothing moving is a dead line.
  curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, 1L);
  curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, 60L);
  if (user && *user) curl_easy_setopt(curl, CURLOPT_USERNAME, user);
  if (password) curl_easy_setopt(curl, CURLOPT_PASSWORD, password);
  if (remote->require_tls) {
    curl_easy_setopt(curl, CURLOPT_USE_SSL, (long)CURLUSESSL_ALL);
  }
  if (remote->ca_file) curl_easy_setopt(curl, CURLOPT_CAINFO, remote->ca_file);
  // SFTP: the key `~/.ssh/config` names, then the agent, then a password —
  // so a machine already set up for `ssh host` asks for nothing.
  long auth = CURLSSH_AUTH_PUBLICKEY | CURLSSH_AUTH_PASSWORD | CURLSSH_AUTH_KEYBOARD;
  if (remote->use_agent) auth |= CURLSSH_AUTH_AGENT;
  curl_easy_setopt(curl, CURLOPT_SSH_AUTH_TYPES, auth);
  if (remote->private_key) {
    curl_easy_setopt(curl, CURLOPT_SSH_PRIVATE_KEYFILE, remote->private_key);
    // Empty, not unset: libssh2 then works the public key out from the
    // private one, so a key with no `.pub` beside it still works.
    curl_easy_setopt(curl, CURLOPT_SSH_PUBLIC_KEYFILE, "");
    if (password) curl_easy_setopt(curl, CURLOPT_KEYPASSWD, password);
  }
  if (remote->known_hosts) {
    curl_easy_setopt(curl, CURLOPT_SSH_HOSTKEYFUNCTION, check_host_key);
    curl_easy_setopt(curl, CURLOPT_SSH_HOSTKEYDATA, remote);
  }
  error_buffer[0] = '\0';
}

static int finish(lava_remote *remote, CURLcode code, const char *error_buffer,
                  lava_remote_result *result) {
  long response = 0;
  curl_easy_getinfo(remote->curl, CURLINFO_RESPONSE_CODE, &response);
  int mapped;
  switch (code) {
  case CURLE_OK:
    mapped = LAVA_REMOTE_OK;
    break;
  case CURLE_LOGIN_DENIED:
    mapped = LAVA_REMOTE_LOGIN;
    break;
  case CURLE_REMOTE_FILE_NOT_FOUND:
    mapped = LAVA_REMOTE_NOT_FOUND;
    break;
  case CURLE_PEER_FAILED_VERIFICATION:
    mapped = remote->host_key_refused ? LAVA_REMOTE_HOST_KEY : LAVA_REMOTE_TLS;
    break;
  case CURLE_SSL_CONNECT_ERROR:
  case CURLE_USE_SSL_FAILED:
  case CURLE_SSL_CERTPROBLEM:
  case CURLE_SSL_CACERT_BADFILE:
    mapped = LAVA_REMOTE_TLS;
    break;
  case CURLE_COULDNT_RESOLVE_HOST:
  case CURLE_COULDNT_CONNECT:
  case CURLE_OPERATION_TIMEDOUT:
  case CURLE_WEIRD_SERVER_REPLY:
    mapped = LAVA_REMOTE_CONNECT;
    break;
  case CURLE_ABORTED_BY_CALLBACK:
    mapped = LAVA_REMOTE_CANCELLED;
    break;
  default:
    // FTP says "no such file" as a 550 on whichever command met it; SFTP
    // as its own status, which curl surfaces as a quote or access error.
    mapped = response == 550 ? LAVA_REMOTE_NOT_FOUND : LAVA_REMOTE_FAILED;
    break;
  }
  // A host-key refusal can surface as a plain connection failure.
  if (code != CURLE_OK && remote->host_key_refused) mapped = LAVA_REMOTE_HOST_KEY;
  if (result) {
    result->code = mapped;
    result->response = response;
    const char *text = error_buffer[0] ? error_buffer : curl_easy_strerror(code);
    snprintf(result->message, sizeof result->message, "%s", text);
  }
  return mapped;
}

// ─── Listing ────────────────────────────────────────────────────────────────

typedef struct {
  char *data;
  size_t length;
  size_t capacity;
} buffer;

/// A listing larger than this is not a folder anybody is browsing; it is
/// somebody's mirror, and the window would be days drawing it.
static const size_t max_listing = 64u << 20;

static size_t collect(char *bytes, size_t size, size_t count, void *context) {
  buffer *into = context;
  size_t n = size * count;
  if (into->length + n + 1 > max_listing) return 0;
  if (into->length + n + 1 > into->capacity) {
    size_t grown = into->capacity ? into->capacity * 2 : 16384;
    while (grown < into->length + n + 1) grown *= 2;
    char *next = realloc(into->data, grown);
    if (!next) return 0;
    into->data = next;
    into->capacity = grown;
  }
  memcpy(into->data + into->length, bytes, n);
  into->length += n;
  into->data[into->length] = '\0';
  return n;
}

static int list_once(lava_remote *remote, const char *url, const char *user,
                     const char *password, int mlsd, buffer *into,
                     lava_remote_result *result) {
  char error_buffer[CURL_ERROR_SIZE];
  prepare(remote, url, user, password, error_buffer);
  curl_easy_setopt(remote->curl, CURLOPT_WRITEFUNCTION, collect);
  curl_easy_setopt(remote->curl, CURLOPT_WRITEDATA, into);
  if (mlsd) curl_easy_setopt(remote->curl, CURLOPT_CUSTOMREQUEST, "MLSD");
  return finish(remote, curl_easy_perform(remote->curl), error_buffer, result);
}

int lava_remote_list(lava_remote *remote, const char *url, const char *user,
                     const char *password, int mlsd, char **out, size_t *length,
                     lava_remote_result *result) {
  buffer into = {0};
  int code = list_once(remote, url, user, password, mlsd, &into, result);
  // A server without MLSD says so with a 500-range reply; `LIST` is the
  // listing every FTP server has.
  if (mlsd && code == LAVA_REMOTE_FAILED && result && result->response >= 500 &&
      result->response <= 504) {
    into.length = 0;
    code = list_once(remote, url, user, password, 0, &into, result);
  }
  if (code != LAVA_REMOTE_OK) {
    free(into.data);
    *out = NULL;
    *length = 0;
    return code;
  }
  if (!into.data) into.data = calloc(1, 1);
  *out = into.data;
  *length = into.length;
  return code;
}

// ─── Transfers ──────────────────────────────────────────────────────────────

typedef struct {
  lava_remote_progress_fn progress;
  void *context;
  int upload;
} progress_relay;

static int relay(void *context, curl_off_t download_total, curl_off_t downloaded,
                 curl_off_t upload_total, curl_off_t uploaded) {
  progress_relay *to = context;
  if (!to->progress) return 0;
  return to->upload ? to->progress(to->context, uploaded, upload_total)
                    : to->progress(to->context, downloaded, download_total);
}

static void with_progress(lava_remote *remote, progress_relay *relay_to) {
  curl_easy_setopt(remote->curl, CURLOPT_NOPROGRESS, 0L);
  curl_easy_setopt(remote->curl, CURLOPT_XFERINFOFUNCTION, relay);
  curl_easy_setopt(remote->curl, CURLOPT_XFERINFODATA, relay_to);
}

int lava_remote_download(lava_remote *remote, const char *url, const char *user,
                         const char *password, const char *destination,
                         lava_remote_progress_fn progress, void *context,
                         lava_remote_result *result) {
  FILE *file = fopen(destination, "wb");
  if (!file) {
    if (result) {
      result->code = LAVA_REMOTE_FAILED;
      result->response = 0;
      snprintf(result->message, sizeof result->message, "Cannot write %s",
               destination);
    }
    return LAVA_REMOTE_FAILED;
  }
  char error_buffer[CURL_ERROR_SIZE];
  prepare(remote, url, user, password, error_buffer);
  // No write function: curl's default is fwrite into WRITEDATA.
  curl_easy_setopt(remote->curl, CURLOPT_WRITEDATA, file);
  progress_relay relay_to = {progress, context, 0};
  with_progress(remote, &relay_to);
  CURLcode code = curl_easy_perform(remote->curl);
  if (fclose(file) != 0 && code == CURLE_OK) code = CURLE_WRITE_ERROR;
  return finish(remote, code, error_buffer, result);
}

int lava_remote_upload(lava_remote *remote, const char *url, const char *user,
                       const char *password, const char *source,
                       lava_remote_progress_fn progress, void *context,
                       lava_remote_result *result) {
  FILE *file = fopen(source, "rb");
  struct stat info;
  if (!file || fstat(fileno(file), &info) != 0) {
    if (file) fclose(file);
    if (result) {
      result->code = LAVA_REMOTE_FAILED;
      result->response = 0;
      snprintf(result->message, sizeof result->message, "Cannot read %s", source);
    }
    return LAVA_REMOTE_FAILED;
  }
  char error_buffer[CURL_ERROR_SIZE];
  prepare(remote, url, user, password, error_buffer);
  curl_easy_setopt(remote->curl, CURLOPT_UPLOAD, 1L);
  // No read function: curl's default is fread from READDATA.
  curl_easy_setopt(remote->curl, CURLOPT_READDATA, file);
  curl_easy_setopt(remote->curl, CURLOPT_INFILESIZE_LARGE, (curl_off_t)info.st_size);
  // Applies to SFTP as well as FTP.
  curl_easy_setopt(remote->curl, CURLOPT_FTP_CREATE_MISSING_DIRS,
                   (long)CURLFTP_CREATE_DIR_RETRY);
  progress_relay relay_to = {progress, context, 1};
  with_progress(remote, &relay_to);
  CURLcode code = curl_easy_perform(remote->curl);
  fclose(file);
  return finish(remote, code, error_buffer, result);
}

int lava_remote_command(lava_remote *remote, const char *url, const char *user,
                        const char *password, const char *command,
                        lava_remote_result *result) {
  char error_buffer[CURL_ERROR_SIZE];
  prepare(remote, url, user, password, error_buffer);
  // One command per line: a rename is two (RNFR, RNTO) and has to be sent
  // on the same connection, in that order.
  struct curl_slist *commands = NULL;
  const char *line = command;
  while (*line) {
    const char *end = strchr(line, '\n');
    size_t length = end ? (size_t)(end - line) : strlen(line);
    char *one = strndup(line, length);
    if (one && *one) commands = curl_slist_append(commands, one);
    free(one);
    if (!end) break;
    line = end + 1;
  }
  // After, not before: `QUOTE` runs straight after login, in whatever folder
  // the reused connection was last left in, so a relative name meant nothing
  // in particular. `POSTQUOTE` runs once curl has gone into the URL's folder.
  curl_easy_setopt(remote->curl, CURLOPT_POSTQUOTE, commands);
  curl_easy_setopt(remote->curl, CURLOPT_NOBODY, 1L);
  CURLcode code = curl_easy_perform(remote->curl);
  int mapped = finish(remote, code, error_buffer, result);
  // The handle keeps a pointer to the list until it is reset.
  curl_easy_setopt(remote->curl, CURLOPT_POSTQUOTE, NULL);
  curl_slist_free_all(commands);
  return mapped;
}

// ─── Keyring ────────────────────────────────────────────────────────────────

char *lava_secret_lookup(const char *protocol, const char *server, int port,
                         const char *user) {
  GError *error = NULL;
  gchar *found;
  if (port > 0) {
    found = secret_password_lookup_sync(
        SECRET_SCHEMA_COMPAT_NETWORK, NULL, &error, "protocol", protocol,
        "server", server, "port", port, "user", user, NULL);
  } else {
    found = secret_password_lookup_sync(SECRET_SCHEMA_COMPAT_NETWORK, NULL,
                                        &error, "protocol", protocol, "server",
                                        server, "user", user, NULL);
  }
  if (error) g_error_free(error);
  if (!found) return NULL;
  char *out = strdup(found);
  secret_password_free(found);
  return out;
}

int lava_secret_store(const char *protocol, const char *server, int port,
                      const char *user, const char *password, const char *label) {
  GError *error = NULL;
  gboolean stored;
  if (port > 0) {
    stored = secret_password_store_sync(
        SECRET_SCHEMA_COMPAT_NETWORK, SECRET_COLLECTION_DEFAULT, label, password,
        NULL, &error, "protocol", protocol, "server", server, "port", port,
        "user", user, NULL);
  } else {
    stored = secret_password_store_sync(
        SECRET_SCHEMA_COMPAT_NETWORK, SECRET_COLLECTION_DEFAULT, label, password,
        NULL, &error, "protocol", protocol, "server", server, "user", user, NULL);
  }
  if (error) g_error_free(error);
  return stored ? 1 : 0;
}

int lava_secret_clear(const char *protocol, const char *server, int port,
                      const char *user) {
  GError *error = NULL;
  gboolean cleared;
  if (port > 0) {
    cleared = secret_password_clear_sync(SECRET_SCHEMA_COMPAT_NETWORK, NULL,
                                         &error, "protocol", protocol, "server",
                                         server, "port", port, "user", user, NULL);
  } else {
    cleared = secret_password_clear_sync(SECRET_SCHEMA_COMPAT_NETWORK, NULL,
                                         &error, "protocol", protocol, "server",
                                         server, "user", user, NULL);
  }
  if (error) g_error_free(error);
  return cleared ? 1 : 0;
}
