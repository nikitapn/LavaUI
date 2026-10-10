#include "config.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sys/stat.h>

namespace lava::indexer {

namespace {

std::string home() {
  const char *h = std::getenv("HOME");
  return h ? h : "/";
}

std::string trim(const std::string &s) {
  const size_t b = s.find_first_not_of(" \t\r");
  if (b == std::string::npos) return {};
  const size_t e = s.find_last_not_of(" \t\r");
  return s.substr(b, e - b + 1);
}

bool isDirectory(const std::string &path) {
  struct stat st {};
  return ::stat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

// What a home directory is full of that nobody searches for by name: version
// control, dependency trees, build output, caches. Every one of these is a
// directory with thousands of entries named like the files the user *does*
// look for — `index.js`, `report.o`.
const std::vector<std::string> kDefaultExcludes = {
    ".git", ".hg", ".svn", "node_modules", "__pycache__", ".build", "build",
    "builddir", ".cache", ".gradle", ".venv", "venv", "target", ".tox",
    ".mypy_cache", ".pytest_cache", "$RECYCLE.BIN", "System Volume Information",
};

}  // namespace

bool Config::excluded(const std::string &name) const {
  if (!hidden && !name.empty() && name[0] == '.') return true;
  return std::find(excludes.begin(), excludes.end(), name) != excludes.end();
}

std::string normalizeRoot(const std::string &path) {
  std::string out = path;
  if (out == "~") out = home();
  else if (out.rfind("~/", 0) == 0) out = home() + out.substr(1);
  while (out.size() > 1 && out.back() == '/') out.pop_back();
  return out;
}

std::string defaultConfigPath() {
  if (const char *p = std::getenv("LAVA_INDEX_CONFIG"); p && *p) return p;
  const char *xdg = std::getenv("XDG_CONFIG_HOME");
  const std::string base = (xdg && *xdg) ? xdg : home() + "/.config";
  return base + "/lava/index.conf";
}

Config loadConfig(const std::string &path) {
  Config config;
  config.excludes = kDefaultExcludes;
  std::ifstream in(path);
  if (!in) {
    // The folders the search window's footer names, where they exist. Not
    // the whole home directory: most of a developer's home is other people's
    // source code, and that is not what a file search is for.
    for (const char *d : {"Documents", "Downloads", "Pictures", "Videos", "Music", "Desktop"}) {
      const std::string p = home() + "/" + d;
      if (isDirectory(p)) config.roots.push_back(p);
    }
    return config;
  }
  std::string line;
  int number = 0;
  while (std::getline(in, line)) {
    ++number;
    line = trim(line);
    if (line.empty() || line[0] == '#') continue;
    const size_t eq = line.find('=');
    if (eq == std::string::npos) {
      std::fprintf(stderr, "lava-index: %s:%d: expected key = value\n", path.c_str(), number);
      continue;
    }
    const std::string key = trim(line.substr(0, eq));
    const std::string value = trim(line.substr(eq + 1));
    if (key == "root") {
      const std::string root = normalizeRoot(value);
      if (root.empty() || root[0] != '/') {
        std::fprintf(stderr, "lava-index: %s:%d: a root must be absolute\n", path.c_str(), number);
        continue;
      }
      if (std::find(config.roots.begin(), config.roots.end(), root) == config.roots.end())
        config.roots.push_back(root);
    } else if (key == "exclude") {
      config.excludes.push_back(value);
    } else if (key == "hidden") {
      config.hidden = value == "yes" || value == "true" || value == "1";
    } else {
      std::fprintf(stderr, "lava-index: %s:%d: unknown key '%s'\n", path.c_str(), number,
                   key.c_str());
    }
  }
  return config;
}

}  // namespace lava::indexer
