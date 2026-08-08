#pragma once

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
  virtual int registerFont(const std::string &path, float pixelSize) = 0;

  /// Opens a surface driven by `arenaId`. 0 if the arena does not exist.
  virtual uint32_t createSurface(const std::string &arenaId, uint32_t width,
                                 uint32_t height, const std::string &title) = 0;
  /// Opens a panel docked to `edge`, `thickness` deep. 0 if the arena does
  /// not exist. `reserve` asks that windows be laid out around it.
  virtual uint32_t createPanel(const std::string &arenaId, uint32_t edge,
                               uint32_t thickness, bool reserve,
                               const std::string &title) = 0;

  virtual bool destroySurface(uint32_t surfaceId) = 0;
  virtual bool surfaceExists(uint32_t surfaceId) const = 0;

  /// "A frame is committed on this surface" — draw it.
  virtual void present(uint32_t surfaceId) = 0;

  /// The size a surface's client should draw at, for the opening `Resize`.
  virtual void surfaceSize(uint32_t surfaceId, float &outW, float &outH) const = 0;

  /// A wheel notch the client's own tree declined. See `ScrollUnclaimed`.
  virtual void scrollUnclaimed(uint32_t surfaceId, float dx, float dy) = 0;

  /// PNG of what is on screen for this surface. False if there was nothing to
  /// read back.
  virtual bool captureSurface(uint32_t surfaceId, int32_t x, int32_t y,
                              int32_t w, int32_t h, int32_t maxSide,
                              std::vector<uint8_t> &outPng, uint32_t &outW,
                              uint32_t &outH) = 0;
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

  /// Where the reference is published. Clients read this file to find us.
  static std::string referencePath();
};

}  // namespace lava
