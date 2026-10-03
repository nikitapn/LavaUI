#include "lock_auth.hpp"

#include <pwd.h>
#include <security/pam_appl.h>
#include <string.h>
#include <unistd.h>

#include <cstdlib>
#include <vector>

#include "wlr.hpp"

namespace lava {
namespace {

/// Answers PAM's questions. Only the hidden prompt gets the password; a stack
/// that asks anything else (a one-time code, say) gets an empty answer and
/// fails, which is the honest result for a lock screen with one field.
/// What `converse` is handed: the answer to give, and where to put what PAM
/// says back.
struct Conversation {
  const std::string *password;
  std::string *said;
};

int converse(int count, const pam_message **messages, pam_response **out,
             void *data) {
  if (count <= 0) return PAM_CONV_ERR;
  auto *conversation = static_cast<Conversation *>(data);
  const std::string *password = conversation->password;
  // calloc, because PAM frees the array and every `resp` in it with free().
  auto *replies =
      static_cast<pam_response *>(std::calloc(static_cast<size_t>(count),
                                              sizeof(pam_response)));
  if (replies == nullptr) return PAM_BUF_ERR;
  for (int i = 0; i < count; ++i) {
    switch (messages[i]->msg_style) {
    case PAM_PROMPT_ECHO_OFF:
      replies[i].resp = ::strdup(password->c_str());
      if (replies[i].resp == nullptr) {
        for (int j = 0; j < i; ++j) std::free(replies[j].resp);
        std::free(replies);
        return PAM_BUF_ERR;
      }
      break;
    case PAM_ERROR_MSG:
    case PAM_TEXT_INFO:
      // Kept for the lock screen as well as logged: "the account is locked"
      // is the difference between a wrong password and a right one refused.
      if (messages[i]->msg != nullptr) {
        wlr_log(WLR_INFO, "lock: pam says '%s'", messages[i]->msg);
        if (!conversation->said->empty()) *conversation->said += ' ';
        *conversation->said += messages[i]->msg;
      }
      break;
    default:
      break;
    }
  }
  *out = replies;
  return PAM_SUCCESS;
}

const char *service() {
  // A file of our own is the right answer, because it says exactly what a
  // lock screen is allowed to do. `login` is the fallback because it exists
  // everywhere and its auth stack is the user's password — the same choice
  // swaylock ships with.
  return ::access("/etc/pam.d/lava-lock", R_OK) == 0 ? "lava-lock" : "login";
}

}  // namespace

std::string lockUserName() {
  // The passwd entry for our own uid, not $USER: the environment is the
  // session's to rewrite, and a lock that checked the password of whoever
  // $USER named would be a lock with a door in it.
  std::vector<char> buffer(4096);
  passwd entry{};
  passwd *found = nullptr;
  if (::getpwuid_r(::getuid(), &entry, buffer.data(), buffer.size(),
                   &found) == 0 &&
      found != nullptr && found->pw_name != nullptr) {
    return found->pw_name;
  }
  return {};
}

bool checkPassword(const std::string &user, std::string &password,
                   std::string &message) {
  message.clear();
  if (user.empty()) {
    wipe(password);
    return false;
  }
  Conversation conversation{&password, &message};
  const pam_conv conv{converse, &conversation};
  pam_handle_t *handle = nullptr;
  int result = ::pam_start(service(), user.c_str(), &conv, &handle);
  if (result == PAM_SUCCESS) {
    // Authentication only, the way every lock screen does it. `acct_mgmt`
    // would also refuse an expired password, and refusing to unlock a session
    // that is already running over an expiry date strands the user at the
    // lock screen with no way to change it.
    result = ::pam_authenticate(handle, 0);
  }
  if (result != PAM_SUCCESS && result != PAM_AUTH_ERR) {
    wlr_log(WLR_ERROR, "lock: pam (%s): %s", service(),
            ::pam_strerror(handle, result));
    if (message.empty()) message = ::pam_strerror(handle, result);
  }
  if (handle != nullptr) ::pam_end(handle, result);
  wipe(password);
  return result == PAM_SUCCESS;
}

void wipe(std::string &secret) {
  if (!secret.empty()) ::explicit_bzero(secret.data(), secret.size());
  secret.clear();
}

}  // namespace lava
