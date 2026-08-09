#include "config.hpp"

#include <cstdlib>
#include <fstream>
#include <sstream>

#include "wlr.hpp"

namespace lava {
namespace {

std::string trim(std::string s) {
  const auto first = s.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return {};
  const auto last = s.find_last_not_of(" \t\r\n");
  return s.substr(first, last - first + 1);
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

}  // namespace

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
    // Comments run to the end of the line, and a `#` inside a value is not a
    // thing anyone writes in a resolution or a keyboard layout.
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
