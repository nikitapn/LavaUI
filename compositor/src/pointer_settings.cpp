#include "pointer_settings.hpp"

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <cstdlib>

namespace lava {

namespace {

std::string lower(std::string s) {
  for (char &c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  return s;
}

bool truthy(const std::string &value, bool fallback) {
  const std::string v = lower(value);
  if (v == "on" || v == "true" || v == "yes" || v == "1") return true;
  if (v == "off" || v == "false" || v == "no" || v == "0") return false;
  return fallback;
}

}  // namespace

std::string canonicalAccel(const std::string &value) {
  const std::string v = lower(value);
  if (v == "adaptive" || v == "flat") return v;
  return "";
}

std::string canonicalScroll(const std::string &value) {
  const std::string v = lower(value);
  if (v == "two-finger" || v == "2fg" || v == "twofinger") return "two-finger";
  if (v == "edge") return "edge";
  if (v == "off" || v == "none") return "off";
  return "";
}

std::string canonicalClick(const std::string &value) {
  const std::string v = lower(value);
  if (v == "areas" || v == "button-areas") return "areas";
  if (v == "fingers" || v == "clickfinger") return "fingers";
  return "";
}

bool parsePointerKey(PointerConfig &config, const std::string &key,
                     const std::string &value) {
  if (key == "speed") {
    char *end = nullptr;
    const double speed = std::strtod(value.c_str(), &end);
    if (end != value.c_str()) config.speed = std::clamp(speed, -1.0, 1.0);
  } else if (key == "acceleration" || key == "accel") {
    const std::string accel = canonicalAccel(value);
    if (!accel.empty()) config.accel = accel;
  } else if (key == "natural-scroll") {
    config.naturalScroll = truthy(value, config.naturalScroll);
  } else if (key == "tap-to-click" || key == "tap") {
    config.tapToClick = truthy(value, config.tapToClick);
  } else if (key == "disable-while-typing" || key == "dwt") {
    config.disableWhileTyping = truthy(value, config.disableWhileTyping);
  } else if (key == "scroll") {
    const std::string scroll = canonicalScroll(value);
    if (!scroll.empty()) config.scroll = scroll;
  } else if (key == "click") {
    // "default" (or anything unknown) is the device's own.
    config.click = canonicalClick(value);
  } else {
    return false;
  }
  return true;
}

std::string formatSpeed(double speed) {
  char buffer[16];
  std::snprintf(buffer, sizeof buffer, "%.2f", std::clamp(speed, -1.0, 1.0));
  // "-0.00" for a value that rounded to nothing reads like a bug.
  std::string out = buffer;
  return out == "-0.00" ? "0.00" : out;
}

}  // namespace lava
