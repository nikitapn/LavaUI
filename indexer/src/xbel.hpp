#pragma once

// ~/.local/share/recently-used.xbel: where GTK and Qt applications record
// what was opened. Read for the "Recent" list, so files opened outside Lava
// appear there too.

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace lava::indexer {

struct RecentFile {
  std::string path;
  int64_t lastOpenNs = 0;
};

/// The local files in an xbel document with the newest time any application
/// recorded for each. Not an XML parser: the format is machine-written and
/// flat, and only `<bookmark href=… modified=… visited=…>` and the
/// per-application `modified=` matter. Non-file hrefs are skipped.
std::vector<RecentFile> parseXbel(std::string_view text);

/// $XDG_DATA_HOME/recently-used.xbel.
std::string defaultXbelPath();

}  // namespace lava::indexer
