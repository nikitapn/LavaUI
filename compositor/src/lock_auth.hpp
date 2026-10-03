#pragma once

#include <string>

/// Checking the password that unlocks the session.
///
/// In the compositor rather than in the lock screen, because whoever checks
/// the password is whoever decides to unlock — and a lock that a client could
/// end by saying "it was right" is a lock any client could end. The lock
/// screen collects keystrokes and is told the answer; it never gives one.
namespace lava {

/// The account the compositor runs as. The only one it can check a password
/// for, and the only one a session lock is about.
std::string lockUserName();

/// Asks PAM whether `password` is `user`'s, and wipes `password` either way.
/// What the PAM stack said on the way — `pam_faillock`'s "the account is
/// locked" above all — lands in `message`, for the lock screen to show.
///
/// **Blocks** — on a wrong password for as long as the PAM stack's fail delay
/// says, which is usually two seconds and is the point of it. Call it from a
/// thread of its own, never from the event loop.
///
/// The service is `lava-lock` when `/etc/pam.d/lava-lock` exists — see
/// `packaging/pam/` — and `login` otherwise, which is what every stock lock
/// screen falls back to and which ends in `pam_unix` on any distribution.
bool checkPassword(const std::string &user, std::string &password,
                   std::string &message);

/// Overwrites a string's bytes before it is freed. `std::string`'s destructor
/// hands them back to the allocator as they were.
void wipe(std::string &secret);

}  // namespace lava
