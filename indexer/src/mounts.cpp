#include "mounts.hpp"

#include <fstream>
#include <sstream>

namespace lava::indexer {

namespace {

// mountinfo escapes space, tab, newline and backslash as \ooo octal.
std::string unescape(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '\\' && i + 3 < s.size() && s[i + 1] >= '0' && s[i + 1] <= '3') {
      out.push_back(static_cast<char>((s[i + 1] - '0') * 64 + (s[i + 2] - '0') * 8 +
                                      (s[i + 3] - '0')));
      i += 3;
    } else {
      out.push_back(s[i]);
    }
  }
  return out;
}

bool hasOption(std::string_view options, std::string_view want) {
  size_t start = 0;
  while (start <= options.size()) {
    size_t comma = options.find(',', start);
    if (comma == std::string_view::npos) comma = options.size();
    if (options.substr(start, comma - start) == want) return true;
    start = comma + 1;
  }
  return false;
}

}  // namespace

std::vector<MountInfo> parseMountInfo(std::string_view text) {
  // id parent major:minor root mountpoint options [optional…] - fstype source superoptions
  std::vector<MountInfo> out;
  size_t lineStart = 0;
  while (lineStart < text.size()) {
    size_t lineEnd = text.find('\n', lineStart);
    if (lineEnd == std::string_view::npos) lineEnd = text.size();
    std::istringstream line{std::string(text.substr(lineStart, lineEnd - lineStart))};
    lineStart = lineEnd + 1;

    std::string id, parent, dev, root, point, options, field;
    if (!(line >> id >> parent >> dev >> root >> point >> options)) continue;
    while (line >> field && field != "-") {
    }
    std::string type, source, superOptions;
    if (!(line >> type >> source)) continue;
    line >> superOptions;

    MountInfo m;
    m.fsRoot = unescape(root);
    m.mountPoint = unescape(point);
    m.fsType = type;
    m.source = unescape(source);
    // Either half can say read-only: the mount's own flags, or the
    // superblock's — which is where ntfs-3g's "volume is dirty, mounting ro"
    // tends to land.
    m.readOnly = hasOption(options, "ro") || hasOption(superOptions, "ro");
    out.push_back(std::move(m));
  }
  return out;
}

std::vector<MountInfo> readMounts() {
  std::ifstream in("/proc/self/mountinfo");
  std::stringstream buffer;
  buffer << in.rdbuf();
  return parseMountInfo(buffer.str());
}

const MountInfo *mountFor(const std::vector<MountInfo> &mounts, const std::string &path) {
  const MountInfo *best = nullptr;
  for (const MountInfo &m : mounts) {
    const std::string &p = m.mountPoint;
    const bool prefix =
        p == "/" || path == p || (path.size() > p.size() && path.compare(0, p.size(), p) == 0 &&
                                  path[p.size()] == '/');
    if (!prefix) continue;
    if (best == nullptr || p.size() >= best->mountPoint.size()) best = &m;
  }
  return best;
}

}  // namespace lava::indexer
