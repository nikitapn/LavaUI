#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "render/draw_command.hpp"
#include "render/font.hpp"

/// The non-client area: the strip a window is dragged, titled and closed by.
///
/// Drawn by the compositor by default, and that default is the choice worth
/// stating. A client that draws its own — GTK does — reimplements the same
/// three buttons in every app, and the compositor has to trust each of them to
/// put a close button somewhere; with the frame here, a client that has
/// crashed can still be closed.
///
/// It is a default rather than a rule. A client that asks for
/// `WindowFrame::client` gets no strip at all and places LavaUI's own
/// `WindowControls` wherever its design wants them, which is the right trade
/// for an app already drawing a toolbar — and the only sensible one for an
/// overlay that should have no chrome. What it gives up is exactly the
/// property above: nothing but the client is drawing its close button, so a
/// client that stops answering is closed by `Alt+drag` and the keyboard rather
/// than by a button. Wayland windows are never offered the choice; theirs is
/// negotiated through `xdg-decoration`.
///
/// It is a separate surface, not a reserved strip inside the client's buffer.
/// Same reasoning as a drop shadow: the client's draw list is its own and this
/// has nothing to do with it, hit testing stays a rectangle comparison rather
/// than an inset one, and a title that changes redraws a 32-pixel strip
/// instead of the whole window.
///
/// A global menu does not remove the need for this. It moves the *menu* out of
/// the window and into a panel; the drag handle and the window buttons have
/// nowhere else to go.
namespace lava {

/// Where a point in the decoration strip landed.
enum class DecorationHit {
  /// Nothing in particular — the drag handle.
  Bar,
  Close,
  Maximize,
};

/// Builds the draw list for one window's title bar.
///
/// Holds no GPU state and knows nothing about surfaces: it turns a title, a
/// width and a hover into commands, and the caller draws them. That keeps the
/// layout of the strip — which is the only thing hit testing has to agree with
/// — in one place, so the buttons drawn and the buttons clicked cannot drift.
class Decoration {
 public:
  /// Height of the strip, in pixels. The window's content starts below it.
  static constexpr int kHeight = 32;

  /// Loads the face titles are shaped with. False if it will not load, in
  /// which case bars draw without text rather than not at all.
  bool loadFont(const std::string &path, float pixelSize);

  /// The face's registered id, which every glyph emitted here carries.
  void setFontId(uint32_t id) { fontId_ = id; }

  /// Which control is at `x`, `y` in strip-local coordinates.
  static DecorationHit hitTest(float x, float y, uint32_t width);

  /// Draw commands for a strip `width` wide.
  ///
  /// `hovered` lights one button; pass `Bar` for none. `focused` dims the
  /// whole strip when false, which is the only thing distinguishing the
  /// active window from the rest.
  void build(const std::string &title, uint32_t width, DecorationHit hovered,
             bool focused);

  /// The commands and glyphs from the last `build`. Valid until the next one.
  const std::vector<canvas::DrawCommand> &commands() const { return commands_; }
  const std::vector<canvas::GlyphInstance> &glyphs() const { return glyphs_; }

 private:
  /// Where a button sits, measured from the right edge.
  static float buttonCenterX(uint32_t width, int fromRight);

  canvas::Font font_;
  bool     fontLoaded_ = false;
  uint32_t fontId_     = 0;

  std::vector<canvas::DrawCommand>   commands_;
  std::vector<canvas::GlyphInstance> glyphs_;
};

}  // namespace lava
