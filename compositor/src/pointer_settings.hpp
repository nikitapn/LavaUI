#pragma once

#include <string>

/// `[mouse]` and `[touchpad]` in `lava.conf`: how libinput is asked to set
/// up each kind of pointer.
///
/// Plain values and string work only, so the parsing is a test
/// (`tests/pointer_settings_test.cpp`); handing them to libinput is
/// `pointer_config.cpp`, which needs a device to talk to.
namespace lava {

struct PointerConfig {
  /// libinput's own scale: -1 is slowest, 1 fastest, 0 its default. Not a
  /// multiplier — it moves the acceleration curve, and every desktop's
  /// slider is this number.
  double speed = 0.0;
  /// "adaptive" speeds up with the hand; "flat" is one ratio, which is what
  /// a game or a trackball wants.
  std::string accel = "adaptive";
  /// Content follows the fingers, as on a phone, rather than the scroll bar.
  bool naturalScroll = false;

  // Touchpad only; a mouse has none of these and they are not applied to one.

  /// A light tap is a click; without it only pressing the pad down is.
  bool tapToClick = true;
  /// Ignore the pad for a moment after a key, so a palm does not move the
  /// pointer mid-sentence.
  bool disableWhileTyping = true;
  /// "two-finger", "edge" (a finger down the right edge), or "off".
  std::string scroll = "two-finger";
  /// "areas": the bottom of the pad is left and right buttons. "fingers":
  /// one, two or three fingers pressing are left, right and middle. ""
  /// leaves the device's own default, which differs between pads.
  std::string click;

  /// The touchpad defaults: what most people expect of one today.
  static PointerConfig touchpadDefaults() {
    PointerConfig c;
    c.naturalScroll = true;
    return c;
  }
};

/// One `key = value` from `[mouse]` or `[touchpad]`. False for a key it does
/// not know, which the caller reports. Bad values fall back or clamp, as the
/// rest of the file does: a typo is not worth refusing to start over.
bool parsePointerKey(PointerConfig &config, const std::string &key,
                     const std::string &value);

/// What `lava.conf` stores for `speed`: two decimals, "0.25".
std::string formatSpeed(double speed);

/// The accepted spellings, normalised; "" for anything else.
std::string canonicalAccel(const std::string &value);
std::string canonicalScroll(const std::string &value);
std::string canonicalClick(const std::string &value);

}  // namespace lava
