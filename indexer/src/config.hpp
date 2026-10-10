#pragma once

// What to index, from $XDG_CONFIG_HOME/lava/index.conf (or LAVA_INDEX_CONFIG):
//
//   # one per line; ~ is the home directory
//   root = ~/Documents
//   root = /mnt/windows/Learning
//   # directory or file names never descended into / never listed
//   exclude = node_modules
//   # whether names starting with '.' are indexed (default: no)
//   hidden = no
//
// No file means the default roots: the XDG user folders that exist.

#include <string>
#include <vector>

namespace lava::indexer {

struct Config {
  std::vector<std::string> roots;
  std::vector<std::string> excludes;
  bool hidden = false;

  /// True when `name` (one path component) is never indexed.
  bool excluded(const std::string &name) const;
};

/// The config at `path`, or the defaults when there is no file. Malformed
/// lines are reported on stderr and skipped, never fatal: a typo in one root
/// should not leave the user with no search at all.
Config loadConfig(const std::string &path);

/// $XDG_CONFIG_HOME/lava/index.conf, or LAVA_INDEX_CONFIG.
std::string defaultConfigPath();

/// Expands a leading `~`, strips trailing slashes.
std::string normalizeRoot(const std::string &path);

}  // namespace lava::indexer
