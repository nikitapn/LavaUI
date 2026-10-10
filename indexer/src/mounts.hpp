#pragma once

// Which mount a root lives on, read from /proc/self/mountinfo.
//
// The daemon polls that file for changes (it signals POLLPRI when the mount
// table changes) and re-reads it, which is how a remount — the Windows
// partition coming back read-write after a repair — reaches the index
// without anybody telling it.

#include <string>
#include <string_view>
#include <vector>

namespace lava::indexer {

struct MountInfo {
  std::string mountPoint;
  /// The part of the source filesystem mounted there; "/" except for bind
  /// mounts and btrfs subvolumes.
  std::string fsRoot;
  std::string fsType;
  std::string source;
  bool readOnly = false;

  /// Names the filesystem stably across mounts: source and fsRoot. See
  /// `root.filesystem` in schema.sql for why not a device number.
  std::string identity() const { return source + " " + fsRoot; }
};

/// Parses mountinfo text. Separate from the read so it can be tested on a
/// captured table.
std::vector<MountInfo> parseMountInfo(std::string_view text);

/// /proc/self/mountinfo, parsed.
std::vector<MountInfo> readMounts();

/// The mount `path` is on: the one with the longest mount point that is a
/// path prefix of it. The last such entry wins, as in the kernel — a later
/// mount over the same point hides an earlier one.
const MountInfo *mountFor(const std::vector<MountInfo> &mounts, const std::string &path);

}  // namespace lava::indexer
