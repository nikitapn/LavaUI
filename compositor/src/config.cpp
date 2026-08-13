#include "config.hpp"

#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <optional>
#include <sstream>
#include <system_error>

#include "wlr.hpp"

namespace lava {
namespace {

std::string trim(std::string s) {
  const auto first = s.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return {};
  const auto last = s.find_last_not_of(" \t\r\n");
  return s.substr(first, last - first + 1);
}

/// Turns a leading `~` into the user's home directory.
///
/// Only for paths a person types. Nothing else in this file needs it — a
/// connector name or a program name has no `~` in it — but a wallpaper lives
/// in `~/Pictures`, and a config file that made people spell out `/home/…`
/// would be a config file that disagrees with every other one on the machine.
std::string expandUser(const std::string &path) {
  if (path.empty() || path.front() != '~') return path;
  // `~otheruser` is deliberately not handled: resolving it means a passwd
  // lookup to support a spelling nobody uses for their own wallpaper, and
  // leaving it alone at least fails visibly rather than resolving to the
  // wrong person's home.
  if (path.size() > 1 && path[1] != '/') return path;
  const char *home = std::getenv("HOME");
  if (home == nullptr || *home == '\0') return path;
  return std::string{home} + path.substr(1);
}

bool parseBool(const std::string &value, bool fallback) {
  if (value == "true" || value == "yes" || value == "on" || value == "1") {
    return true;
  }
  if (value == "false" || value == "no" || value == "off" || value == "0") {
    return false;
  }
  return fallback;
}

/// "1920x1080@74.973", "1920x1080@75Hz", "1920x1080", or "preferred".
///
/// The rate is written in Hz because that is what a monitor is sold as, and
/// stored in mHz because that is what wlroots compares against — 74.973 is a
/// real refresh rate and rounding it to 75 fails to match any mode.
bool parseMode(const std::string &value, OutputConfig &out) {
  if (value.empty() || value == "preferred" || value == "auto") {
    out.width = 0;
    out.height = 0;
    out.refresh = 0;
    return true;
  }
  const auto x = value.find('x');
  if (x == std::string::npos) return false;
  const auto at = value.find('@');

  try {
    out.width = std::stoi(value.substr(0, x));
    out.height = std::stoi(value.substr(x + 1, at == std::string::npos
                                                   ? std::string::npos
                                                   : at - x - 1));
    out.refresh = 0;
    if (at != std::string::npos) {
      std::string rate = value.substr(at + 1);
      if (rate.size() > 2 && rate.substr(rate.size() - 2) == "Hz") {
        rate = rate.substr(0, rate.size() - 2);
      }
      out.refresh = static_cast<int32_t>(std::stod(rate) * 1000.0);
    }
  } catch (const std::exception &) {
    return false;
  }
  return out.width > 0 && out.height > 0;
}

/// "1920,0" or "1920 0".
bool parsePosition(const std::string &value, OutputConfig &out) {
  std::string copy = value;
  for (char &c : copy) {
    if (c == ',') c = ' ';
  }
  std::istringstream in(copy);
  int32_t x = 0, y = 0;
  if (!(in >> x >> y)) return false;
  out.x = x;
  out.y = y;
  return true;
}

bool parseTransform(const std::string &value, OutputConfig &out) {
  const struct {
    const char *name;
    int32_t value;
  } kTransforms[] = {
      {"normal", WL_OUTPUT_TRANSFORM_NORMAL},
      {"90", WL_OUTPUT_TRANSFORM_90},
      {"180", WL_OUTPUT_TRANSFORM_180},
      {"270", WL_OUTPUT_TRANSFORM_270},
      {"flipped", WL_OUTPUT_TRANSFORM_FLIPPED},
      {"flipped-90", WL_OUTPUT_TRANSFORM_FLIPPED_90},
      {"flipped-180", WL_OUTPUT_TRANSFORM_FLIPPED_180},
      {"flipped-270", WL_OUTPUT_TRANSFORM_FLIPPED_270},
  };
  for (const auto &t : kTransforms) {
    if (value == t.name) {
      out.transform = t.value;
      return true;
    }
  }
  return false;
}

/// `#rrggbb`, `rrggbb`, `0xrrggbb`, or the three-digit short form.
///
/// The short form is worth the six lines: `#fff` and `#000` are how people
/// write white and black from memory, and a config file that took one spelling
/// of white and silently ignored the other would be a small daily annoyance.
bool parseColor(const std::string &value, uint32_t &out) {
  std::string digits = value;
  if (digits.rfind("0x", 0) == 0 || digits.rfind("0X", 0) == 0) {
    digits.erase(0, 2);
  } else if (!digits.empty() && digits.front() == '#') {
    digits.erase(0, 1);
  }
  if (digits.size() != 3 && digits.size() != 6) return false;
  for (const char c : digits) {
    if (std::isxdigit(static_cast<unsigned char>(c)) == 0) return false;
  }
  if (digits.size() == 3) {
    // `abc` means `aabbcc`, not `000abc` — each digit is a nibble repeated,
    // which is what makes `#fff` white rather than a very dark blue.
    digits = {digits[0], digits[0], digits[1], digits[1], digits[2], digits[2]};
  }
  out = static_cast<uint32_t>(std::stoul(digits, nullptr, 16)) & 0x00ffffffu;
  return true;
}

/// One of `solid`/`picture`, defaulting to `solid`.
///
/// Never fails, and that is the point: an unreadable mode falls to the one
/// that always works rather than leaving the desktop with no background at
/// all. Same argument as the clamping in `[appearance]` — a typo should cost
/// the user the setting, not the session.
std::string canonicalBackgroundMode(const std::string &value) {
  return value == "picture" || value == "image" ? "picture" : "solid";
}

/// One of `fill`/`fit`/`stretch`/`center`, defaulting to `fill`.
std::string canonicalBackgroundFit(const std::string &value) {
  if (value == "fit" || value == "contain") return "fit";
  if (value == "stretch" || value == "scale") return "stretch";
  if (value == "center" || value == "centre" || value == "none") return "center";
  return "fill";
}

}  // namespace

std::string canonicalWallpaperMode(const std::string &value) {
  return canonicalBackgroundMode(value);
}

std::string canonicalWallpaperFit(const std::string &value) {
  return canonicalBackgroundFit(value);
}

std::string formatWallpaperColor(uint32_t color) {
  // `0x`, never `#`, however the user typed it. A `#` starts a comment on
  // every line of this file, so `color = #1e2430` parses as `color =` and the
  // key is dropped — a colour written that way would not survive being read
  // back by the compositor that wrote it. Both spellings are accepted on the
  // way in; only this one is ever written out.
  char buffer[11];
  std::snprintf(buffer, sizeof(buffer), "0x%06x", color & 0x00ffffffu);
  return buffer;
}

bool parseWallpaperColor(const std::string &value, uint32_t &out) {
  return parseColor(value, out);
}

std::string Config::defaultPath() {
  if (const char *explicitPath = std::getenv("LAVA_CONFIG")) {
    return explicitPath;
  }
  if (const char *xdg = std::getenv("XDG_CONFIG_HOME")) {
    return std::string(xdg) + "/lava/lava.conf";
  }
  if (const char *home = std::getenv("HOME")) {
    return std::string(home) + "/.config/lava/lava.conf";
  }
  return "lava.conf";
}

Config Config::load(const std::string &path) {
  Config config;
  std::ifstream file(path);
  if (!file) {
    // Not an error, and deliberately only INFO: a compositor with no config
    // is a compositor with the defaults, which is how this one started.
    wlr_log(WLR_INFO, "config: none at '%s', using defaults", path.c_str());
    return config;
  }

  std::string section;
  std::string line;
  int lineNumber = 0;
  while (std::getline(file, line)) {
    ++lineNumber;
    // Comments run to the end of the line, anywhere on it. This is why a
    // colour is written `0x1e2430` rather than `#1e2430`: the latter is a
    // value that this loop turns into an empty one, silently.
    const auto hash = line.find('#');
    if (hash != std::string::npos) line = line.substr(0, hash);
    line = trim(line);
    if (line.empty()) continue;

    if (line.front() == '[' && line.back() == ']') {
      section = trim(line.substr(1, line.size() - 2));
      // `[output DP-3]` opens a block for one connector; each is its own
      // entry, so a later block for the same name does not merge into it.
      if (section.rfind("output", 0) == 0) {
        OutputConfig output;
        output.name = trim(section.substr(6));
        if (output.name.empty()) output.name = "*";
        config.outputs.push_back(output);
        section = "output";
      }
      continue;
    }

    const auto equals = line.find('=');
    if (equals == std::string::npos) {
      wlr_log(WLR_ERROR, "config: %s:%d: not a key = value", path.c_str(),
              lineNumber);
      continue;
    }
    const std::string key = trim(line.substr(0, equals));
    const std::string value = trim(line.substr(equals + 1));

    bool known = true;
    if (section == "core") {
      if (key == "renderer") {
        config.renderer = value;
      } else if (key == "drm-device" || key == "drm-devices") {
        config.drmDevices = value;
      } else if (key == "render-device") {
        config.renderDevice = value;
      } else {
        known = false;
      }
    } else if (section == "keyboard") {
      if (key == "layout") {
        config.keyboard.layout = value;
      } else if (key == "variant") {
        config.keyboard.variant = value;
      } else if (key == "options") {
        config.keyboard.options = value;
      } else if (key == "model") {
        config.keyboard.model = value;
      } else if (key == "rules") {
        config.keyboard.rules = value;
      } else if (key == "repeat-rate") {
        config.keyboard.repeatRate = std::atoi(value.c_str());
      } else if (key == "repeat-delay") {
        config.keyboard.repeatDelay = std::atoi(value.c_str());
      } else if (key == "mod-key" || key == "mod") {
        // "super", "logo", "win", "meta" all mean the Win key. Anything else
        // (including empty) is Alt — the historical default.
        const std::string lower = [&] {
          std::string s = value;
          for (char &c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
          return s;
        }();
        if (lower == "super" || lower == "logo" || lower == "win" ||
            lower == "meta" || lower == "mod4") {
          config.keyboard.modKey = "super";
        } else {
          config.keyboard.modKey = "alt";
        }
      } else {
        known = false;
      }
    } else if (section == "theme") {
      if (key == "name") {
        config.theme.name = value;
      } else {
        known = false;
      }
    } else if (section == "appearance") {
      if (key == "corner-radius") {
        // Clamped rather than refused: a negative radius is a typo and a
        // gigantic one is a request nothing can honour, and neither is worth
        // refusing to start over.
        const int32_t radius = std::atoi(value.c_str());
        config.appearance.cornerRadius = radius < 0 ? 0 : (radius > 64 ? 64 : radius);
      } else if (key == "shadow-blur") {
        const int32_t blur = std::atoi(value.c_str());
        config.appearance.shadowBlur = blur < 0 ? 0 : (blur > 128 ? 128 : blur);
      } else if (key == "shadow-opacity") {
        const double opacity = std::atof(value.c_str());
        config.appearance.shadowOpacity =
          static_cast<float>(opacity < 0.0 ? 0.0 : (opacity > 1.0 ? 1.0 : opacity));
      } else if (key == "shadow-offset-y") {
        const int32_t offset = std::atoi(value.c_str());
        config.appearance.shadowOffsetY =
          offset < -128 ? -128 : (offset > 128 ? 128 : offset);
      } else {
        known = false;
      }
    } else if (section == "background") {
      if (key == "mode") {
        config.background.mode = canonicalBackgroundMode(value);
      } else if (key == "color" || key == "colour") {
        // A colour that will not parse leaves the default in place and says
        // so, rather than painting the desktop whatever `atoi` made of it.
        known = parseColor(value, config.background.color);
      } else if (key == "picture" || key == "image" || key == "path") {
        config.background.picture = expandUser(value);
      } else if (key == "fit") {
        config.background.fit = canonicalBackgroundFit(value);
      } else {
        known = false;
      }
    } else if (section == "shell") {
      if (key == "panel") {
        config.shell.panel = value;
      } else if (key == "dock") {
        config.shell.dock = value;
      } else if (key == "enabled") {
        config.shell.enabled = parseBool(value, true);
      } else {
        known = false;
      }
    } else if (section == "output" && !config.outputs.empty()) {
      OutputConfig &output = config.outputs.back();
      if (key == "mode" || key == "resolution") {
        known = parseMode(value, output);
      } else if (key == "position") {
        known = parsePosition(value, output);
      } else if (key == "scale") {
        output.scale = std::atof(value.c_str());
      } else if (key == "transform") {
        known = parseTransform(value, output);
      } else if (key == "enabled") {
        output.enabled = parseBool(value, true);
      } else {
        known = false;
      }
    } else {
      known = false;
    }

    if (!known) {
      // Reported and skipped rather than fatal, so a config written against a
      // newer build still starts an older one.
      wlr_log(WLR_ERROR, "config: %s:%d: ignoring '%s' in [%s]", path.c_str(),
              lineNumber, key.c_str(), section.c_str());
    }
  }

  wlr_log(WLR_INFO, "config: loaded '%s' (%zu output block(s))", path.c_str(),
          config.outputs.size());
  return config;
}

namespace {

/// The section a header line opens, or nullopt if the line is not a header.
std::optional<std::string> sectionOf(const std::string &line) {
  const std::string t = trim(line);
  if (t.size() < 2 || t.front() != '[' || t.back() != ']') return std::nullopt;
  return trim(t.substr(1, t.size() - 2));
}

/// The key a line assigns, ignoring comments and blank lines.
///
/// A commented-out `# layout = us` deliberately does not count: it is a note,
/// and the value it names is not in effect.
std::optional<std::string> keyOf(const std::string &line) {
  const std::string t = trim(line);
  if (t.empty() || t.front() == '#') return std::nullopt;
  const auto equals = t.find('=');
  if (equals == std::string::npos) return std::nullopt;
  return trim(t.substr(0, equals));
}

/// Whether two section names refer to the same block. `[output DP-3]` is one
/// block per connector, and the name is the part after the word.
bool sameSection(const std::string &a, const std::string &b) { return a == b; }

}  // namespace

bool Config::write(const std::string &path,
                   const std::vector<Setting> &settings,
                   std::string &outError) {
  std::vector<std::string> lines;
  {
    std::ifstream file(path);
    std::string line;
    while (std::getline(file, line)) lines.push_back(line);
  }

  for (const Setting &setting : settings) {
    // Where the section runs from and to. `end` is one past its last line,
    // which for the final section is the end of the file.
    size_t sectionStart = std::string::npos;
    size_t sectionEnd = lines.size();
    for (size_t i = 0; i < lines.size(); ++i) {
      const auto header = sectionOf(lines[i]);
      if (!header) continue;
      if (sectionStart == std::string::npos) {
        if (sameSection(*header, setting.section)) sectionStart = i + 1;
      } else {
        sectionEnd = i;
        break;
      }
    }

    const std::string assignment = setting.key + " = " + setting.value;

    if (sectionStart == std::string::npos) {
      // A section this file has never had. Appended with a blank line before
      // it, which is how every other block in the file is separated.
      if (!lines.empty() && !trim(lines.back()).empty()) lines.push_back("");
      lines.push_back("[" + setting.section + "]");
      lines.push_back(assignment);
      continue;
    }

    size_t existing = std::string::npos;
    for (size_t i = sectionStart; i < sectionEnd; ++i) {
      const auto key = keyOf(lines[i]);
      if (key && *key == setting.key) {
        existing = i;
        break;
      }
    }

    if (existing != std::string::npos) {
      lines[existing] = assignment;
      continue;
    }

    // New key in an existing section: after its last real line, so it lands
    // with the block rather than after the blank line that follows it.
    size_t insert = sectionEnd;
    while (insert > sectionStart && trim(lines[insert - 1]).empty()) --insert;
    lines.insert(lines.begin() + static_cast<std::ptrdiff_t>(insert),
                 assignment);
  }

  std::error_code ec;
  const std::filesystem::path target(path);
  if (target.has_parent_path()) {
    std::filesystem::create_directories(target.parent_path(), ec);
    if (ec) {
      outError = "cannot create " + target.parent_path().string() + ": " +
                 ec.message();
      return false;
    }
  }

  // Written beside the target and renamed over it: rename is atomic within a
  // filesystem, so a compositor killed mid-write leaves the old config intact
  // rather than a truncated one that the next start cannot read.
  const std::filesystem::path temporary = target.string() + ".tmp";
  {
    std::ofstream out(temporary, std::ios::trunc);
    if (!out) {
      outError = "cannot write " + temporary.string();
      return false;
    }
    for (const std::string &line : lines) out << line << '\n';
    out.flush();
    if (!out) {
      outError = "write failed for " + temporary.string();
      return false;
    }
  }

  std::filesystem::rename(temporary, target, ec);
  if (ec) {
    std::filesystem::remove(temporary, ec);
    outError = "cannot replace " + path + ": " + ec.message();
    return false;
  }

  wlr_log(WLR_INFO, "config: wrote %zu setting(s) to '%s'", settings.size(),
          path.c_str());
  return true;
}

const OutputConfig *Config::forOutput(const std::string &name) const {
  const OutputConfig *fallback = nullptr;
  for (const auto &output : outputs) {
    if (output.name == name) return &output;
    if (output.name == "*") fallback = &output;
  }
  return fallback;
}

void Config::applyEnvironment() const {
  // 0 for overwrite: an environment variable set by hand on the command line
  // is a deliberate one-off, and losing it to the config file would make
  // "try it with pixman once" impossible without editing a file.
  const struct {
    const char *name;
    const std::string &value;
  } vars[] = {
      {"WLR_RENDERER", renderer},
      {"WLR_DRM_DEVICES", drmDevices},
      {"WLR_RENDER_DRM_DEVICE", renderDevice},
  };
  for (const auto &var : vars) {
    if (var.value.empty()) continue;
    setenv(var.name, var.value.c_str(), 0);
    wlr_log(WLR_INFO, "config: %s=%s", var.name, getenv(var.name));
  }
}

}  // namespace lava
