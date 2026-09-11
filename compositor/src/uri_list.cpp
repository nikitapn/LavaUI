#include "uri_list.hpp"

namespace lava {

namespace {

int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

}  // namespace

std::vector<std::string> paths_from_uri_list(const std::string &text) {
  std::vector<std::string> out;
  static const std::string kScheme = "file://";

  size_t at = 0;
  while (at < text.size()) {
    size_t end = text.find('\n', at);
    if (end == std::string::npos) end = text.size();
    std::string line = text.substr(at, end - at);
    at = end + 1;

    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.empty() || line[0] == '#') continue;
    if (line.compare(0, kScheme.size(), kScheme) != 0) continue;

    // The path starts at the authority's trailing slash, so an empty authority
    // and `localhost` come out the same. Anything else — a real host — has no
    // local path in it and is left alone.
    const size_t slash = line.find('/', kScheme.size());
    if (slash == std::string::npos) continue;
    const std::string authority =
        line.substr(kScheme.size(), slash - kScheme.size());
    if (!authority.empty() && authority != "localhost") continue;

    std::string path;
    for (size_t i = slash; i < line.size(); ++i) {
      if (line[i] == '%' && i + 2 < line.size()) {
        const int hi = hex_value(line[i + 1]);
        const int lo = hex_value(line[i + 2]);
        if (hi >= 0 && lo >= 0) {
          // A NUL in the middle of a path is not a path; a source that sends
          // one is either broken or trying something.
          const char decoded = static_cast<char>(hi * 16 + lo);
          if (decoded == '\0') {
            path.clear();
            break;
          }
          path.push_back(decoded);
          i += 2;
          continue;
        }
        // A stray `%` that is not an escape stays a `%`: some senders do not
        // encode at all, and a file really can be called "100%".
      }
      path.push_back(line[i]);
    }
    if (!path.empty()) out.push_back(std::move(path));
  }
  return out;
}

std::string uri_list_from_paths(const std::vector<std::string> &paths) {
  std::string out;
  for (const std::string &path : paths) {
    if (path.empty() || path.front() != '/') continue;
    out += "file://";
    for (unsigned char c : path) {
      // Unreserved, plus `/` which is the path separator rather than data.
      if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
          c == '~' || c == '/') {
        out.push_back(static_cast<char>(c));
      } else {
        static const char kHex[] = "0123456789ABCDEF";
        out.push_back('%');
        out.push_back(kHex[c >> 4]);
        out.push_back(kHex[c & 0xf]);
      }
    }
    out += "\r\n";
  }
  return out;
}

}  // namespace lava
