#pragma once

// `[workspaces]` in lava.conf: what each workspace is called. Kept out of
// config.cpp, which needs wlroots for its logging, so the test can be built
// from this file alone — the same split as `pointer_settings`.

#include <cstddef>
#include <string>
#include <vector>

namespace lava {

/// How many workspaces there are: Mod+1…9. `Workspaces::kCount` in
/// `main.cpp` asserts it agrees.
inline constexpr long kWorkspaceCount = 9;

/// The most a name keeps, in bytes.
inline constexpr std::size_t kWorkspaceNameBytes = 64;

/// A workspace name as `lava.conf` can hold it: no `#` (the parser cuts a
/// comment there), no line breaks or other control characters, no spaces
/// round it, and at most `kWorkspaceNameBytes` bytes, cut at a character
/// rather than through one. What `SetWorkspaceNames` keeps.
std::string cleanWorkspaceName(const std::string &raw);

/// One line of `[workspaces]`: `2 = Work` names workspace 2, stored at
/// index 1. False for a key that is not a number from 1 to 9, which the
/// caller reports like any unknown key. The value is taken as cleaned.
bool parseWorkspaceKey(std::vector<std::string> &names, const std::string &key,
                       const std::string &value);

} // namespace lava
