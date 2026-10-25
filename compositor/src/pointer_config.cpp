#include "pointer_config.hpp"

#include "wlr.hpp"

extern "C" {
#include <wlr/config.h>
}

#if WLR_HAS_LIBINPUT_BACKEND
#include <libinput.h>
extern "C" {
#include <wlr/backend/libinput.h>
}
#endif

namespace lava {

#if WLR_HAS_LIBINPUT_BACKEND

namespace {

libinput_device *handle(wlr_input_device *device) {
  if (device == nullptr || !wlr_input_device_is_libinput(device)) return nullptr;
  return wlr_libinput_get_device_handle(device);
}

void apply(libinput_device *d, const PointerConfig &c, bool touchpad) {
  if (libinput_device_config_accel_is_available(d)) {
    libinput_device_config_accel_set_speed(d, c.speed);
    const uint32_t profiles = libinput_device_config_accel_get_profiles(d);
    const auto profile = c.accel == "flat" ? LIBINPUT_CONFIG_ACCEL_PROFILE_FLAT
                                           : LIBINPUT_CONFIG_ACCEL_PROFILE_ADAPTIVE;
    if (profiles & profile) libinput_device_config_accel_set_profile(d, profile);
  }
  if (libinput_device_config_scroll_has_natural_scroll(d)) {
    libinput_device_config_scroll_set_natural_scroll_enabled(d, c.naturalScroll ? 1 : 0);
  }
  if (!touchpad) return;

  if (libinput_device_config_tap_get_finger_count(d) > 0) {
    libinput_device_config_tap_set_enabled(
        d, c.tapToClick ? LIBINPUT_CONFIG_TAP_ENABLED : LIBINPUT_CONFIG_TAP_DISABLED);
  }
  if (libinput_device_config_dwt_is_available(d)) {
    libinput_device_config_dwt_set_enabled(
        d, c.disableWhileTyping ? LIBINPUT_CONFIG_DWT_ENABLED : LIBINPUT_CONFIG_DWT_DISABLED);
  }
  const uint32_t methods = libinput_device_config_scroll_get_methods(d);
  const auto scroll = c.scroll == "edge"  ? LIBINPUT_CONFIG_SCROLL_EDGE
                      : c.scroll == "off" ? LIBINPUT_CONFIG_SCROLL_NO_SCROLL
                                          : LIBINPUT_CONFIG_SCROLL_2FG;
  if (scroll == LIBINPUT_CONFIG_SCROLL_NO_SCROLL || (methods & scroll)) {
    libinput_device_config_scroll_set_method(d, scroll);
  }
  const uint32_t clicks = libinput_device_config_click_get_methods(d);
  if (!c.click.empty()) {
    const auto click = c.click == "fingers" ? LIBINPUT_CONFIG_CLICK_METHOD_CLICKFINGER
                                            : LIBINPUT_CONFIG_CLICK_METHOD_BUTTON_AREAS;
    if (clicks & click) libinput_device_config_click_set_method(d, click);
  } else if (clicks != 0) {
    // Back to the pad's own, for a file that stopped saying.
    libinput_device_config_click_set_method(d, libinput_device_config_click_get_default_method(d));
  }
}

}  // namespace

bool isTouchpad(wlr_input_device *device) {
  libinput_device *d = handle(device);
  return d != nullptr && libinput_device_config_tap_get_finger_count(d) > 0;
}

bool isConfigurable(wlr_input_device *device) { return handle(device) != nullptr; }

void applyPointerConfig(wlr_input_device *device, const PointerConfig &mouse,
                        const PointerConfig &touchpad) {
  libinput_device *d = handle(device);
  if (d == nullptr) return;
  const bool pad = libinput_device_config_tap_get_finger_count(d) > 0;
  apply(d, pad ? touchpad : mouse, pad);
}

#else

bool isTouchpad(wlr_input_device *) { return false; }
bool isConfigurable(wlr_input_device *) { return false; }
void applyPointerConfig(wlr_input_device *, const PointerConfig &, const PointerConfig &) {}

#endif

}  // namespace lava
