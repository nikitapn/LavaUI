#pragma once

#include "pointer_settings.hpp"

struct wlr_input_device;

/// Handing `[mouse]` / `[touchpad]` to libinput.
///
/// Only devices that came through wlroots' libinput backend have anything to
/// set: a headless or nested session's pointers are virtual, and these do
/// nothing for them. That also means none of this runs in a test.
namespace lava {

/// A pointer libinput can tap on: what every desktop calls a touchpad.
bool isTouchpad(wlr_input_device *device);

/// libinput sits under this device, so the settings mean something.
bool isConfigurable(wlr_input_device *device);

/// Applies `touchpad` to a touchpad and `mouse` to anything else. A setting
/// the device does not support (a mouse has no tapping, a trackpoint no
/// acceleration profile) is left alone rather than refused.
void applyPointerConfig(wlr_input_device *device, const PointerConfig &mouse,
                        const PointerConfig &touchpad);

}  // namespace lava
