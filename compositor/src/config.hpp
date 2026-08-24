#pragma once

#include <cstdint>
#include <string>
#include <string_view>
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

  /// Compositor shortcut modifier: "alt" (default) or "super" (Win/Meta).
  /// Also gates mod+drag. Kept as a string so `lava.conf` and the settings
  /// app share one vocabulary rather than inventing an enum each.
  std::string modKey = "alt";
};

/// How the desktop looks, as opposed to what the machine is.
///
/// The odd one out in this file: everything else here is a fact about the
/// hardware that the compositor cannot know, and this is a preference the user
/// is entitled to have. It lives here anyway because the alternative — a
/// second file, or a hard-coded number somebody has to rebuild to change — is
/// worse for the one thing a config exists to make possible.
struct AppearanceConfig {
  /// Corner radius for windows, in pixels. 0 is square.
  ///
  /// Applied to what the compositor draws: LavaUI clients and the title bars
  /// above them. A Wayland client's own buffer is not ours to reshape — see
  /// `docs/native-menus.md`'s neighbour in `decoration.hpp` for the same
  /// split — so those stay square until the scene is composited by hand.
  int32_t cornerRadius = 0;

  /// How far a window's shadow reaches, in pixels. 0 turns shadows off.
  ///
  /// Only the focused window casts one, which is the point: it says which
  /// window is active without tinting a border, and it says it in the one
  /// place the eye is already looking. Unlike rounding, this works for
  /// Wayland clients too — a shadow is drawn *behind* a window and needs
  /// nothing from its buffer.
  int32_t shadowBlur = 0;

  /// Shadow opacity directly under the window, 0…1. The falloff takes it to
  /// zero over `shadowBlur` pixels.
  float shadowOpacity = 0.35f;

  /// How far the shadow is pushed down, in pixels. Light comes from above, so
  /// a shadow sitting exactly under its window reads as a glow instead.
  int32_t shadowOffsetY = 4;
};

/// How the compositor's own renderer is set up.
///
/// Distinct from `[output]`, which is about screens, and from `[appearance]`,
/// which is about what windows look like: this is what the GPU is asked to do.
struct RenderConfig {
  /// Multisampling for the scene attachments: 1, 2, 4 or 8. Rounded down to a
  /// power of two and further limited by what the device supports.
  ///
  /// It is a memory setting as much as a quality one. Every surface the
  /// compositor draws — one per client window, plus one each for its title bar,
  /// its shadow and the frost behind it — allocates a multisampled colour
  /// attachment *and* a multisampled depth attachment, so this number multiplies
  /// the two largest things in the GPU report. At 1920x1080 it is 16 MiB per
  /// surface per step: 8 costs 128 MiB where 4 costs 64 and 2 costs 32.
  ///
  /// What it buys is the smoothness of a *diagonal* edge — a rounded corner, a
  /// triangle in a chart. Text is unaffected (it is coverage-blended from the
  /// glyph atlas) and so is every axis-aligned rectangle, which is most of a UI.
  /// 4 is the default for that reason; drop to 2 on a memory-tight machine and
  /// look at a corner before deciding it was free.
  int32_t msaa = 4;
};

/// Which LavaUI `Theme` clients that wear system colours should use.
///
/// A name, not a palette. The colours live in LavaUI; the compositor only
/// remembers which one the desktop picked. Keep this list in step with
/// `Theme.builtIns` — an unknown name is dark.
struct ThemeConfig {
  std::string name = "dark";
};

inline bool isKnownThemeName(std::string_view name) {
  return name == "dark" || name == "light" || name == "nebula" ||
         name == "ember" || name == "moss" || name == "paper" ||
         name == "graphite";
}

inline std::string canonicalThemeName(std::string_view name) {
  return isKnownThemeName(name) ? std::string(name) : std::string{"dark"};
}

/// What the desktop is painted with, behind every window.
///
/// Kept apart from `AppearanceConfig` deliberately. That block is the set of
/// numbers clients copy so their own menus match the windows around them; this
/// one is the compositor's own backdrop, which no client ever draws. They are
/// two different audiences that happen to both be about how the desktop looks.
struct BackgroundConfig {
  /// `solid` or `picture`. Anything else parses as `solid` — the mode with no
  /// file to be missing and no decode to fail.
  std::string mode = "solid";

  /// Packed `0x00RRGGBB`, opaque. The desktop is the bottom of the scene, so
  /// there is nothing underneath for an alpha channel to describe.
  ///
  /// Meaningful in both modes: in `picture` this is what shows wherever the
  /// picture does not reach, which is the letterbox under `fit`, the margin
  /// under `center`, and the whole screen while a picture is being decoded or
  /// after its file has gone away.
  /// The blue-black the desktop was hard-coded to before any of this existed,
  /// to a rounding error: 0.055, 0.075, 0.12 in floats is `0e131f` in bytes.
  /// Changing the default would repaint the desktop of everyone who has never
  /// opened the settings app, which is not a thing adding a setting should do.
  uint32_t color = 0x0e131f;

  /// Absolute path to the picture; empty in `solid` mode.
  std::string picture;

  /// `fill`, `fit`, `stretch` or `center`. Anything else parses as `fill`.
  std::string fit = "fill";
};

/// One `key = value` bound for one `[section]`.
///
/// The unit `Config::write` takes, because a settings app changes a handful of
/// keys and should not have to hand back a whole file to do it.
struct Setting {
  /// The section header without its brackets: "appearance", "keyboard", or
  /// "output DP-3".
  std::string section;
  std::string key;
  std::string value;
};

/// Which parts of the desktop the compositor starts and keeps running.
///
/// Deliberately thin. These are not a choice of panel — they are this
/// desktop's panel and dock, started the way Xwayland is, and the only reason
/// they are configurable at all is that a developer needs to run one by hand
/// sometimes and a packager needs to say where they live. There is no
/// mechanism here for assembling a session out of parts, because a session
/// that can come up without a dock is a session that will.
struct ShellConfig {
  /// Program names or paths. Empty, or the word `off`, means "do not start
  /// this one" — which is what a developer running it under a debugger wants.
  std::string panel = "LavaTaskbar";
  std::string dock = "LavaDock";
  /// The context menu client — what a right-click on the desktop or on a
  /// window's title bar opens. `off` leaves the desktop with no context menu,
  /// which is what it had before this existed; the right click still clears
  /// focus.
  std::string menu = "LavaContextMenu";

  /// Whether to start anything at all. `LAVA_NO_SHELL=1` in the environment
  /// says the same thing without editing a file, for a one-off run.
  bool enabled = true;
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
  /// Connector that hosts the panel and new windows: "DP-3", "eDP-1".
  /// Empty means no preference — the screen at the layout origin, which
  /// is where the panel sat before this existed. The name is kept when
  /// that screen is unplugged; another enabled one stands in until it
  /// comes back.
  std::string primaryOutput;
  /// How the screens share the desktop: `"extend"` (default) or `"mirror"`.
  /// Extend is each screen its own piece of the layout; mirror is the
  /// same picture on every screen, stacked at the origin.
  std::string arrangement = "extend";

  KeyboardConfig keyboard;
  RenderConfig render;
  AppearanceConfig appearance;
  BackgroundConfig background;
  ThemeConfig theme;
  ShellConfig shell;
  std::vector<OutputConfig> outputs;

  /// Where the file lives: `$LAVA_CONFIG`, else
  /// `$XDG_CONFIG_HOME/lava/lava.conf`, else `~/.config/lava/lava.conf`.
  static std::string defaultPath();

  /// The user's own startup script — `$LAVA_AUTOSTART`, else `autostart`
  /// beside `lava.conf`. Run with `/bin/sh` once the session is up.
  ///
  /// A script rather than a list of programs in `lava.conf`, because what
  /// these need is rarely just a name: an applet wants a flag, an environment
  /// variable, a `sleep` before something slow, and a shell says all of that
  /// already. It is also the honest boundary — `[shell]` above is this
  /// desktop's own parts, and this is everything that is the user's.
  static std::string autostartPath();

  /// Reads `path`. A missing file is not an error — it yields the defaults,
  /// which are what the compositor did before this existed.
  static Config load(const std::string &path);

  /// Writes `settings` into `path`, changing nothing else.
  ///
  /// Surgical on purpose. This file is one people write by hand, and most of
  /// what is in it is comments explaining which GPU drives which connector on
  /// this particular machine — none of which a settings app could regenerate
  /// and none of which it should destroy. So each setting replaces the value
  /// of an existing key where there is one, is appended to its section where
  /// the section exists, and appends a new section where it does not.
  ///
  /// A key that is commented out is left commented out and a live one added
  /// below it: uncommenting somebody's note would be deciding that a line
  /// they deliberately disabled was meant to be on.
  ///
  /// Creates the file, and the directory it lives in. Replaces it atomically,
  /// so an interrupted write cannot leave a half-written config that the next
  /// start cannot parse. False with `outError` filled if it could not.
  static bool write(const std::string &path,
                    const std::vector<Setting> &settings,
                    std::string &outError);

  /// The block for a connector: its own if it has one, else `*`, else null.
  const OutputConfig *forOutput(const std::string &name) const;

  /// Puts the GPU choices in the environment, which is how wlroots takes
  /// them. Must run before the backend is created — after that they are read
  /// and nothing rereads them. Values already set in the environment win, so
  /// a one-off `WLR_RENDERER=pixman ./compositor` still overrides the file.
  void applyEnvironment() const;
};

// ─── Background vocabulary ──────────────────────────────────────────────────
//
// Shared with the control plane so a value arriving over RPC and a value read
// out of the file are narrowed by the same code. Two implementations of "what
// counts as a fit mode" is two implementations to keep in step, and the one
// that drifts is always the one with no file to look at.

/// Narrows anything to `solid` or `picture`. Never fails.
std::string canonicalWallpaperMode(const std::string &value);

/// Narrows anything to `fill`, `fit`, `stretch` or `center`. Never fails.
std::string canonicalWallpaperFit(const std::string &value);

/// Narrows anything to `extend` or `mirror`. Never fails.
std::string canonicalArrangement(const std::string &value);

/// `#rrggbb`, for writing into the config file.
std::string formatWallpaperColor(uint32_t color);

/// Reads `#rrggbb`, `rrggbb`, `0xrrggbb` or the three-digit short form.
/// False leaves `out` untouched.
bool parseWallpaperColor(const std::string &value, uint32_t &out);

}  // namespace lava
