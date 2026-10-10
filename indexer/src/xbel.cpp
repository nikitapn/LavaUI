#include "xbel.hpp"

#include "uri_list.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <unordered_map>

namespace lava::indexer {

namespace {

std::string decodeEntities(std::string_view s) {
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i] != '&') {
      out.push_back(s[i]);
      continue;
    }
    const size_t semi = s.find(';', i);
    if (semi == std::string_view::npos) {
      out.push_back('&');
      continue;
    }
    const std::string_view name = s.substr(i + 1, semi - i - 1);
    if (name == "amp") out.push_back('&');
    else if (name == "lt") out.push_back('<');
    else if (name == "gt") out.push_back('>');
    else if (name == "quot") out.push_back('"');
    else if (name == "apos") out.push_back('\'');
    else {
      out.append(s.substr(i, semi - i + 1));
    }
    i = semi;
  }
  return out;
}

// The value of `name="…"` inside one tag, or empty.
std::string_view attribute(std::string_view tag, std::string_view name) {
  size_t at = 0;
  while ((at = tag.find(name, at)) != std::string_view::npos) {
    const bool boundary = at == 0 || tag[at - 1] == ' ' || tag[at - 1] == '\t' ||
                          tag[at - 1] == '\n';
    const size_t eq = at + name.size();
    if (boundary && eq + 1 < tag.size() && tag[eq] == '=' && tag[eq + 1] == '"') {
      const size_t end = tag.find('"', eq + 2);
      if (end == std::string_view::npos) return {};
      return tag.substr(eq + 2, end - eq - 2);
    }
    at = eq;
  }
  return {};
}

// "2026-10-05T12:34:56.123456Z" → ns since the epoch; 0 if unreadable.
int64_t parseTime(std::string_view s) {
  if (s.size() < 19) return 0;
  std::tm tm{};
  const std::string str(s);
  if (std::sscanf(str.c_str(), "%4d-%2d-%2dT%2d:%2d:%2d", &tm.tm_year, &tm.tm_mon,
                  &tm.tm_mday, &tm.tm_hour, &tm.tm_min, &tm.tm_sec) != 6) {
    return 0;
  }
  tm.tm_year -= 1900;
  tm.tm_mon -= 1;
  const time_t secs = timegm(&tm);
  int64_t ns = static_cast<int64_t>(secs) * 1'000'000'000;
  if (s.size() > 20 && s[19] == '.') {
    int64_t frac = 0;
    int digits = 0;
    for (size_t i = 20; i < s.size() && s[i] >= '0' && s[i] <= '9' && digits < 9; ++i, ++digits)
      frac = frac * 10 + (s[i] - '0');
    for (; digits < 9; ++digits) frac *= 10;
    ns += frac;
  }
  return ns;
}

}  // namespace

std::vector<RecentFile> parseXbel(std::string_view text) {
  std::vector<RecentFile> out;
  std::unordered_map<std::string, size_t> seen;
  size_t at = 0;
  while ((at = text.find("<bookmark ", at)) != std::string_view::npos) {
    const size_t tagEnd = text.find('>', at);
    if (tagEnd == std::string_view::npos) break;
    const std::string_view tag = text.substr(at, tagEnd - at);
    // `<bookmark …/>` has no body, and searching on for a `</bookmark>`
    // would take the *next* bookmark's as this one's.
    std::string_view body;
    if (text[tagEnd - 1] == '/') {
      at = tagEnd;
    } else {
      size_t close = text.find("</bookmark>", tagEnd);
      if (close == std::string_view::npos) close = text.size();
      body = text.substr(tagEnd, close - tagEnd);
      at = close;
    }

    const std::string href = decodeEntities(attribute(tag, "href"));
    const std::vector<std::string> paths = lava::paths_from_uri_list(href);
    if (paths.size() != 1) continue;

    int64_t newest = std::max(parseTime(attribute(tag, "modified")),
                              parseTime(attribute(tag, "visited")));
    // Each application that opened it has its own `modified`; the newest of
    // those is when it was last opened, which the bookmark's own times only
    // sometimes reflect.
    size_t app = 0;
    while ((app = body.find("<bookmark:application ", app)) != std::string_view::npos) {
      const size_t appEnd = body.find('>', app);
      if (appEnd == std::string_view::npos) break;
      newest = std::max(newest, parseTime(attribute(body.substr(app, appEnd - app), "modified")));
      app = appEnd;
    }
    if (newest == 0) continue;

    if (auto it = seen.find(paths[0]); it != seen.end()) {
      out[it->second].lastOpenNs = std::max(out[it->second].lastOpenNs, newest);
    } else {
      seen.emplace(paths[0], out.size());
      out.push_back({paths[0], newest});
    }
  }
  return out;
}

std::string defaultXbelPath() {
  const char *xdg = std::getenv("XDG_DATA_HOME");
  if (xdg && *xdg) return std::string(xdg) + "/recently-used.xbel";
  const char *home = std::getenv("HOME");
  return std::string(home ? home : "") + "/.local/share/recently-used.xbel";
}

}  // namespace lava::indexer
