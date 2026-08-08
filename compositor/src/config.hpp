#pragma once

#include <cstdint>
#include <string>
#include <vector>

/// The compositor's configuration file.
///
/// Everything here is a decision that cannot be made from the code, because it
/// is about the machine rather than about the program: which GPU drives the
/// screens, what resolution each screen runs at, what the keyboard layout is.
/// Hard-coding any of them is what makes a compositor somebody else's.
///
/// The format is INI-shaped and parsed by hand — a few dozen lines against a
/// dependency, on a file that is read once at startup and again on SIGHUP.
/// Unknown keys are reported and skipped rather than fatal, so a config
/// written for a newer build still starts an older one.
namespace lava {

/// One `[output NAME]` block, or the `[output *]` fallback.
struct OutputConfig {
  /// The connector name wlroots reports: "DP-3", "eDP-1", "HDMI-A-1". Run the
  /// compositor once and read the log — it lists every output it found, with
  /// the modes each one offers.
  std::string name;
  bool enabled = true;

  /// 0x0 means "whatever the display says it prefers", which is right far
  /// more often than a number typed by hand.
  int32_t width = 0;
  int32_t height = 0;
  /// In mHz, as wlroots counts refresh rates. 0 means "any rate at that size",
  /// which picks the highest.
  int32_t refresh = 0;

  /// Where the output sits in layout space. `kAuto` strings them left to
  /// right in the order they appear, which is what one screen always wants
  /// and two screens rarely do.
  static constexpr int32_t kAuto = INT32_MIN;
  int32_t x = kAuto;
  int32_t y = kAuto;

  double scale = 0.0;  ///< 0 means "leave it alone" — i.e. 1.
  /// `enum wl_output_transform`, kept as an int so this header does not drag
  /// in the Wayland protocol headers.
  int32_t transform = 0;

  /// True when this block named a size, as opposed to inheriting the default.
  bool hasMode() const { return width > 0 && height > 0; }
};

struct KeyboardConfig {
  // Empty means "whatever xkb defaults to", which is a US layout on most
  // installs. Named after the xkb_rule_names fields so the mapping is direct.
  std::string layout;
  std::string variant;
  std::string options;
  std::string model;
  std::string rules;

  int32_t repeatRate = 25;    ///< keys per second once repeating starts
  int32_t repeatDelay = 600;  ///< ms held before it starts
};

struct Config {
  /// `WLR_RENDERER`: "vulkan", "gles2", "pixman". Empty lets wlroots choose.
  std::string renderer;
  /// `WLR_DRM_DEVICES`: which card drives the screens. Colon-separated, first
  /// is primary. On a hybrid laptop this is the one the connectors hang off —
  /// not necessarily the fastest one.
  std::string drmDevices;
  /// `WLR_RENDER_DRM_DEVICE`: which card draws. Only differs from the above
  /// when rendering on one GPU and presenting on another.
  std::string renderDevice;

  KeyboardConfig keyboard;
  std::vector<OutputConfig> outputs;

  /// Where the file lives: `$LAVA_CONFIG`, else
  /// `$XDG_CONFIG_HOME/lava/lava.conf`, else `~/.config/lava/lava.conf`.
  static std::string defaultPath();

  /// Reads `path`. A missing file is not an error — it yields the defaults,
  /// which are what the compositor did before this existed.
  static Config load(const std::string &path);

  /// The block for a connector: its own if it has one, else `*`, else null.
  const OutputConfig *forOutput(const std::string &name) const;

  /// Puts the GPU choices in the environment, which is how wlroots takes
  /// them. Must run before the backend is created — after that they are read
  /// and nothing rereads them. Values already set in the environment win, so
  /// a one-off `WLR_RENDERER=pixman ./compositor` still overrides the file.
  void applyEnvironment() const;
};

}  // namespace lava
