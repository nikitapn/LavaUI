#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

struct wl_event_loop;

/// The compositor's half of the LavaUI control plane.
///
/// Everything that is not pixels. Draw lists cross through the arena — a
/// mapping the client writes once and canvas reads in place — and what is left
/// over is small, request/response shaped, and happens at human rates: naming
/// a font, asking for a surface, saying a frame is ready, and carrying input
/// back the other way.
///
/// That last one is why this exists at all. The compositor owns the window, so
/// it owns the only pointer and keyboard in the system; a process that draws
/// into shared memory has no other way to learn that the mouse moved. Before
/// this, a client could be *shown* and not *used*.
///
/// See `idl/lava.npidl`, which is the authority for both sides — the C++
/// servant here and the Swift proxy in `LavaClient` are generated from it.
namespace lava {

/// What the control plane needs from the compositor.
///
/// Implemented in `main.cpp`, where the scene graph and the surfaces live.
/// **Every method is called on the Wayland event loop thread** — the POA is
/// given a dispatch executor that hops there first, so none of these has to
/// think about it. That is a property of the POA rather than a rule each
/// method remembers, which matters because forgetting it would mean touching
/// wlroots and Vulkan from an RPC thread: a failure that is rare, late, and
/// nowhere near the mistake.
struct CompositorHost {
  virtual ~CompositorHost() = default;

  /// Id to stamp into `GlyphInstance.fontId`, or -1 if the face will not load.
  ///
  /// Keyed on the file's contents rather than its path, so the size is 26.6
  /// fixed point and the face index and hinting come along — see
  /// `canvas::FontKey`.
  virtual int registerFont(const std::string &path, uint32_t pixelSize26_6,
                           uint32_t faceIndex, uint32_t rasterFlags) = 0;

  /// Id to stamp into an `Image` command's `param`, or -1 if the file will
  /// not decode. `key` is the caller's name for the entry — the same string
  /// `releaseImage` is given — and `outWidth`/`outHeight` come back as the
  /// *decoded* size, which `maxPixelSize` changes.
  virtual int registerImage(const std::string &key, const std::string &path,
                            uint32_t maxPixelSize, uint32_t &outWidth,
                            uint32_t &outHeight) = 0;

  /// The same, from encoded bytes (PNG, JPEG, …) rather than a path.
  virtual int registerImageData(const std::string &key, const uint8_t *bytes,
                                size_t byteCount, uint32_t maxPixelSize,
                                uint32_t &outWidth, uint32_t &outHeight) = 0;

  /// Drops the compositor's reference to `key`.
  virtual void releaseImage(const std::string &key) = 0;

  /// One window as a shell sees it. Mirrors `WindowInfo` in the IDL without
  /// dragging the generated header into this one.
  struct WindowEntry {
    uint32_t surfaceId = 0;
    std::string title;
    std::string appId;
    uint32_t workspace = 0;
    bool minimized = false;
    bool focused = false;
  };

  /// Every window, and which workspace is showing. For a subscriber that has
  /// just arrived; after that the compositor pushes.
  virtual void windowList(uint32_t &outCurrentWorkspace,
                          std::vector<WindowEntry> &outWindows) const = 0;

  /// Restores, raises and focuses a window. False if the id is unknown.
  virtual bool activateWindow(uint32_t surfaceId) = 0;

  /// Limits where a surface takes pointer input. `w` or `h` of 0 restores the
  /// whole surface. False if the id is unknown.
  virtual bool setInputRegion(uint32_t surfaceId, int32_t x, int32_t y,
                              uint32_t w, uint32_t h) = 0;

  /// Remembers the pointer image a surface wants, and applies it now if the
  /// pointer is over that surface. `shape` is a `CursorShape` ordinal — an
  /// integer rather than the generated enum, the same way `createPanel` takes
  /// `edge`, so this header stays independent of the stubs.
  ///
  /// No return: the call behind it is `[unreliable]` and has no reply to put
  /// a failure in, so an unknown surface is dropped rather than reported.
  virtual void setCursor(uint32_t surfaceId, uint32_t shape) = 0;

  /// Opens a surface driven by `arenaId`. 0 if the arena does not exist.
  ///
  /// `decorated` is `WindowFrame::server` — the compositor draws the title
  /// bar. A bool rather than the generated enum so this header stays
  /// independent of the stubs, the same way `createPanel` takes `edge` as an
  /// integer.
  virtual uint32_t createSurface(const std::string &arenaId, uint32_t width,
                                 uint32_t height, const std::string &title,
                                 bool decorated, const std::string &appId) = 0;
  /// Opens a panel docked to `edge`, `thickness` deep. 0 if the arena does
  /// not exist. `reserve` asks that windows be laid out around it.
  virtual uint32_t createPanel(const std::string &arenaId, uint32_t edge,
                               uint32_t thickness, bool reserve,
                               const std::string &title,
                               const std::string &appId) = 0;

  virtual bool destroySurface(uint32_t surfaceId) = 0;
  virtual bool surfaceExists(uint32_t surfaceId) const = 0;

  /// Whether a window on the current workspace overlaps this panel's own
  /// rectangle — the question behind `SubscribePanelArea`.
  ///
  /// False for anything that is not a panel, including a surface that has
  /// gone: "nothing is in the way" is the safe answer for a dock, because it
  /// leaves the dock visible rather than hiding it over an empty desktop.
  virtual bool panelCovered(uint32_t surfaceId) const = 0;

  // ─── Window state ────────────────────────────────────────────────────────
  //
  // What a title bar's buttons do, for the client that draws its own. Each
  // returns false only when the surface is unknown, so the servant can turn
  // that into `SurfaceNotFound` without asking twice.

  /// Hands the pointer to an interactive move of `surfaceId`. No-op when no
  /// button is down — see `BeginMove`.
  virtual bool beginMove(uint32_t surfaceId) = 0;

  /// Fills the work area or restores; `outMaximized` is the state it ended in.
  virtual bool toggleMaximize(uint32_t surfaceId, bool &outMaximized) = 0;

  /// Hides the window without ending it.
  virtual bool minimize(uint32_t surfaceId) = 0;

  /// Re-thickens a panel, reserving `reserved` of it. False when the surface
  /// is unknown or is not a panel. See `SetPanelThickness`.
  /// The client's own floor for its window, in pixels. Zero means no opinion
  /// about that axis. False if the surface is gone.
  virtual bool setMinSize(uint32_t surfaceId, uint32_t minWidth,
                          uint32_t minHeight) = 0;

  virtual bool setPanelThickness(uint32_t surfaceId, uint32_t thickness,
                                 uint32_t reserved) = 0;

  /// What the desktop looks like: corner radius, and the shadow a focused
  /// window casts. See `Appearance` in the IDL.
  virtual void appearance(float &outCornerRadius, float &outShadowBlur,
                          float &outShadowOpacity,
                          float &outShadowOffsetY) const = 0;

  /// The system colour theme name (`dark` / `light` / `nebula`).
  virtual void systemTheme(std::string &outName) const = 0;
  virtual void updateSystemTheme(const std::string &name,
                                 std::string &outError) = 0;

  // ─── Settings ────────────────────────────────────────────────────────────
  //
  // The desktop's preferences, for the app that exists to change them. Each
  // setter does two things and both matter: it applies the change to the
  // running compositor, and it writes it to `lava.conf` so the next session
  // has it too.
  //
  // `outError` is how the second half reports: empty means saved, non-empty
  // means the change is live but did not reach the file. The distinction is
  // worth carrying because the user can see the first half happen, and would
  // otherwise find out about the second half at the next login.
  //
  // Mirrors of the IDL's messages rather than the generated types, for the
  // reason `WindowEntry` is: this header stays independent of the stubs.

  struct KeyboardState {
    std::string layout;
    std::string variant;
    std::string options;
    std::string model;
    std::string rules;
    int32_t repeatRate = 0;
    int32_t repeatDelay = 0;
    /// "alt" or "super" — see `KeyboardConfig::modKey`.
    std::string modKey = "alt";
  };

  /// One layout, or one variant of one — `variant` empty means the layout
  /// itself. See `KeyboardLayout` in the IDL.
  struct LayoutEntry {
    std::string code;
    std::string variant;
    std::string description;
  };

  /// One compiled-in shortcut, as the key handler's own table describes it.
  struct BindingEntry {
    std::string modifiers;
    std::string key;
    std::string action;
    std::string description;
  };

  struct ModeEntry {
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t refresh = 0;  ///< mHz
    bool current = false;
    bool preferred = false;
  };

  struct OutputEntry {
    std::string name;
    std::string description;
    bool enabled = true;
    int32_t x = 0;
    int32_t y = 0;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t refresh = 0;
    float scale = 1.f;
    uint32_t transform = 0;
  };

  /// What to set a screen to. 0 for a size, rate or scale means "the default
  /// for that field" — see `OutputRequest` in the IDL.
  struct OutputChange {
    std::string name;
    bool enabled = true;
    uint32_t width = 0;
    uint32_t height = 0;
    uint32_t refresh = 0;
    float scale = 0.f;
    int32_t x = 0;
    int32_t y = 0;
    uint32_t transform = 0;
  };

  /// Where the settings below are saved. Named in `SettingsWriteFailed`, so
  /// a user told their change did not stick is told which file to look at.
  virtual std::string configPath() const = 0;

  /// Sets the desktop's look. Values are clamped to what can be drawn.
  virtual void updateAppearance(float cornerRadius, float shadowBlur,
                                float shadowOpacity, float shadowOffsetY,
                                std::string &outError) = 0;

  /// What the desktop is painted with now: `solid`/`picture`, `0x00RRGGBB`,
  /// the picture's path, and the fit mode.
  virtual void background(std::string &outMode, uint32_t &outColor,
                          std::string &outPicture,
                          std::string &outFit) const = 0;

  /// Sets the desktop background, applying before saving like the rest.
  ///
  /// The one setter here that can refuse outright. `outPictureError` is filled
  /// when the picture could not be read, and in that case *nothing* changed —
  /// not the screen and not the file — so the caller must report it as a
  /// refusal rather than as a failure to save. `outError` keeps its usual
  /// meaning: applied, not written.
  virtual void updateBackground(const std::string &mode, uint32_t color,
                                const std::string &picture,
                                const std::string &fit,
                                std::string &outPictureError,
                                std::string &outError) = 0;

  virtual void keyboardSettings(KeyboardState &out) const = 0;
  virtual void setKeyboardSettings(const KeyboardState &settings,
                                   std::string &outError) = 0;

  /// Every layout this machine's xkb offers. Empty if the rules cannot be
  /// read, which is a broken install rather than a machine with no layouts.
  virtual void keyboardLayouts(std::vector<LayoutEntry> &out) const = 0;

  /// Every shortcut the compositor takes for itself, from the table the key
  /// handler dispatches through.
  virtual void keyBindings(std::vector<BindingEntry> &out) const = 0;

  virtual void outputList(std::vector<OutputEntry> &out) const = 0;

  /// Every mode `name` can run at. False if no such screen is connected.
  virtual bool outputModes(const std::string &name,
                           std::vector<ModeEntry> &out) const = 0;

  /// Reconfigures a screen. False if no such screen is connected.
  virtual bool setOutput(const OutputChange &change, std::string &outError) = 0;

  /// The focused window and its title, for a subscriber that has just
  /// arrived. `outSurfaceId` is 0 when nothing has focus.
  ///
  /// `outMenuService` / `outMenuObjectPath` are the KDE Wayland AppMenu
  /// address for that window's dbusmenu export, or empty when the focused
  /// surface never sent one (Lava clients use the registrar + surface id
  /// instead).
  virtual void activeWindow(uint32_t &outSurfaceId, std::string &outTitle,
                            std::string &outMenuService,
                            std::string &outMenuObjectPath) const = 0;

  /// "A frame is committed on this surface" — draw it.
  virtual void present(uint32_t surfaceId) = 0;

  /// The size a surface's client should draw at, for the opening `Resize`.
  virtual void surfaceSize(uint32_t surfaceId, float &outW, float &outH) const = 0;

  /// A wheel notch the client's own tree declined. See `ScrollUnclaimed`.
  virtual void scrollUnclaimed(uint32_t surfaceId, float dx, float dy) = 0;

  /// "This surface is still drawing." Only the components the compositor
  /// started are watched; for everything else this is a no-op. See
  /// `Heartbeat` in the IDL.
  virtual void heartbeat(uint32_t surfaceId) = 0;

  /// PNG of what is on screen for this surface. False if there was nothing to
  /// read back.
  virtual bool captureSurface(uint32_t surfaceId, int32_t x, int32_t y,
                              int32_t w, int32_t h, int32_t maxSide,
                              std::vector<uint8_t> &outPng, uint32_t &outW,
                              uint32_t &outH) = 0;

  /// The seat's selection, as text. Empty when there is none or it is not
  /// text-shaped.
  ///
  /// The same selection every Wayland client reads, which is the point: a
  /// LavaUI client has no `wl_data_device` of its own, so without these two
  /// its copy and paste would be a private drawer that Firefox cannot see.
  virtual std::string clipboardText() const = 0;

  /// Offers `text` as the seat's selection, replacing what was there.
  virtual void setClipboardText(const std::string &text) = 0;

  /// The primary selection — what middle-click pastes. Filled by selecting
  /// rather than by copying, which is why a client sets it from wherever a
  /// drag ends.
  virtual std::string primarySelectionText() const = 0;
  virtual void setPrimarySelectionText(const std::string &text) = 0;
};

class ControlPlane {
 public:
  /// Starts the RPC runtime and publishes the compositor's reference where
  /// clients look for it. Null, having said why, if it could not.
  ///
  /// `host` must outlive the returned object.
  static std::unique_ptr<ControlPlane> start(wl_event_loop *loop,
                                             CompositorHost &host);

  virtual ~ControlPlane() = default;

  /// Sends one input event to whoever has subscribed to `surfaceId`.
  ///
  /// Called from the loop thread, where events are produced. Fields mean what
  /// `canvas::InputEventKind` says they mean — the compositor forwards and
  /// interprets nothing, which is what makes this a field copy rather than a
  /// protocol.
  virtual void postInput(uint32_t surfaceId, uint32_t kind, float x, float y,
                         int32_t button, int32_t mods) = 0;

  /// Ends every subscription to a surface that has gone away.
  virtual void surfaceGone(uint32_t surfaceId) = 0;

  /// "The set of windows changed" — to every shell watching. Called from the
  /// loop thread on anything a dock would draw differently.
  virtual void postWindowList() = 0;

  /// "Something moved" — recompute whether each subscribed panel is covered,
  /// and tell the ones whose answer changed.
  ///
  /// Called from far more places than `postWindowList`, because this depends
  /// on geometry and that one does not: a window dragged across the bottom of
  /// the screen changes nothing about the window *list*. Cheap to call
  /// wrongly — it is a rectangle test per panel, and it sends nothing when
  /// the answer is what it was.
  virtual void postPanelAreas() = 0;

  /// "The focused window is now this one" — to every panel watching.
  ///
  /// Called from the loop thread on every focus change, including the change
  /// to nothing, and again when the focused window's AppMenu address arrives
  /// late (Qt often sets it after map). Cheap when nobody is subscribed.
  virtual void postActiveWindow(uint32_t surfaceId, const std::string &title,
                                const std::string &menuService = {},
                                const std::string &menuObjectPath = {}) = 0;

  /// "The system theme changed" — to every Lava client watching.
  virtual void postSystemTheme() = 0;

  /// Which session this compositor is: the name of its Wayland socket, which
  /// is what tells a nested compositor from the one it is running inside.
  /// `"default"` before the socket is bound, which no caller should see.
  static std::string sessionId();

  /// Where the reference is published. Clients read this file to find us.
  ///
  /// `$XDG_RUNTIME_DIR/lava-compositor-<session>.ior`, or `$LAVA_COMPOSITOR_IOR`
  /// verbatim when that is set — the escape hatch for a client that has to
  /// reach a compositor it did not inherit an environment from.
  static std::string referencePath();
};

}  // namespace lava
