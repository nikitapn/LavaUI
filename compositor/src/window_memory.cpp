#include "window_memory.hpp"

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <system_error>
#include <vector>

#include "wlr.hpp"

namespace lava {
namespace {

std::string trim(std::string s) {
  const auto first = s.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return {};
  const auto last = s.find_last_not_of(" \t\r\n");
  return s.substr(first, last - first + 1);
}

bool parseBool(const std::string &value) {
  return value == "true" || value == "yes" || value == "on" || value == "1";
}

bool parseInt(const std::string &value, int &out) {
  try {
    size_t end = 0;
    const int parsed = std::stoi(value, &end);
    if (end != value.size()) return false;
    out = parsed;
    return true;
  } catch (const std::exception &) {
    return false;
  }
}

bool parseU32(const std::string &value, uint32_t &out) {
  int parsed = 0;
  if (!parseInt(value, parsed) || parsed <= 0) return false;
  out = static_cast<uint32_t>(parsed);
  return true;
}

}  // namespace

std::string WindowMemory::defaultPath(bool nested) {
  if (const char *explicitPath = std::getenv("LAVA_WINDOWS")) {
    return explicitPath;
  }
  if (nested) {
    if (const char *runtime = std::getenv("XDG_RUNTIME_DIR")) {
      return std::string(runtime) + "/lava-windows";
    }
    return "lava-windows";
  }
  if (const char *xdg = std::getenv("XDG_CONFIG_HOME")) {
    return std::string(xdg) + "/lava/windows";
  }
  if (const char *home = std::getenv("HOME")) {
    return std::string(home) + "/.config/lava/windows";
  }
  return "windows";
}

WindowMemory WindowMemory::load(const std::string &path) {
  WindowMemory memory;
  memory.path_ = path;
  std::ifstream file(path);
  if (!file) {
    wlr_log(WLR_INFO, "windows: none at '%s'", path.c_str());
    return memory;
  }

  std::string section;
  std::string line;
  int lineNumber = 0;
  while (std::getline(file, line)) {
    ++lineNumber;
    const auto hash = line.find('#');
    if (hash != std::string::npos) line = line.substr(0, hash);
    line = trim(line);
    if (line.empty()) continue;

    if (line.front() == '[' && line.back() == ']') {
      section = trim(line.substr(1, line.size() - 2));
      if (!section.empty()) memory.byApp_.emplace(section, WindowPlacement{});
      continue;
    }
    if (section.empty()) continue;

    const auto equals = line.find('=');
    if (equals == std::string::npos) {
      wlr_log(WLR_INFO, "windows: %s:%d: ignored '%s'", path.c_str(),
              lineNumber, line.c_str());
      continue;
    }
    const std::string key = trim(line.substr(0, equals));
    const std::string value = trim(line.substr(equals + 1));
    WindowPlacement &slot = memory.byApp_[section];
    if (key == "x") {
      parseInt(value, slot.x);
    } else if (key == "y") {
      parseInt(value, slot.y);
    } else if (key == "width") {
      parseU32(value, slot.width);
    } else if (key == "height") {
      parseU32(value, slot.height);
    } else if (key == "maximized") {
      slot.maximized = parseBool(value);
    }
  }

  // Drop sections that never named a size — a hand-edit, or a write that
  // was killed before the numbers landed.
  for (auto it = memory.byApp_.begin(); it != memory.byApp_.end();) {
    if (!it->second.usable()) {
      it = memory.byApp_.erase(it);
    } else {
      ++it;
    }
  }

  wlr_log(WLR_INFO, "windows: %zu placement(s) from '%s'", memory.byApp_.size(),
          path.c_str());
  return memory;
}

const WindowPlacement *WindowMemory::find(const std::string &appId) const {
  if (appId.empty()) return nullptr;
  const auto it = byApp_.find(appId);
  if (it == byApp_.end() || !it->second.usable()) return nullptr;
  return &it->second;
}

void WindowMemory::remember(const std::string &appId,
                            const WindowPlacement &placement) {
  if (appId.empty() || !placement.usable()) return;
  const auto it = byApp_.find(appId);
  if (it != byApp_.end() && it->second == placement) return;
  byApp_[appId] = placement;
  dirty_ = true;
}

bool WindowMemory::flush() {
  if (!dirty_) return true;
  if (!save()) {
    wlr_log(WLR_ERROR, "windows: not saved to '%s'", path_.c_str());
    return false;
  }
  dirty_ = false;
  return true;
}

bool WindowMemory::save() const {
  if (path_.empty()) return false;

  std::error_code ec;
  const std::filesystem::path target(path_);
  if (target.has_parent_path()) {
    std::filesystem::create_directories(target.parent_path(), ec);
    if (ec) {
      wlr_log(WLR_ERROR, "windows: cannot create %s: %s",
              target.parent_path().c_str(), ec.message().c_str());
      return false;
    }
  }

  std::vector<std::string> names;
  names.reserve(byApp_.size());
  for (const auto &entry : byApp_) names.push_back(entry.first);
  std::sort(names.begin(), names.end());

  const std::filesystem::path temporary = target.string() + ".tmp";
  {
    std::ofstream out(temporary, std::ios::trunc);
    if (!out) return false;
    out << "# Last frame of each application. Written by the compositor.\n"
           "# Delete a section to forget that app; the next launch centres.\n"
           "\n";
    for (const std::string &name : names) {
      const auto it = byApp_.find(name);
      if (it == byApp_.end() || !it->second.usable()) continue;
      const WindowPlacement &p = it->second;
      out << '[' << name << "]\n";
      out << "x = " << p.x << '\n';
      out << "y = " << p.y << '\n';
      out << "width = " << p.width << '\n';
      out << "height = " << p.height << '\n';
      out << "maximized = " << (p.maximized ? "true" : "false") << "\n\n";
    }
    out.flush();
    if (!out) {
      std::filesystem::remove(temporary, ec);
      return false;
    }
  }

  std::filesystem::rename(temporary, target, ec);
  if (ec) {
    std::filesystem::remove(temporary, ec);
    return false;
  }
  return true;
}

}  // namespace lava
