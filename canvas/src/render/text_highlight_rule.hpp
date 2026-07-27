#pragma once

/// One syntax-highlight rule, supplied from outside (Swift/C API).
/// Patterns use ECMAScript syntax (`std::regex::ECMAScript`).
///
/// Kept in its own header, split out of text_widget.hpp: canvas_engine.hpp
/// needs a *complete* definition to expose `std::vector<TextHighlightRule>`
/// to Swift's C++ interop (which instantiates the vector's destructor/
/// allocator eagerly, unlike a normal translation unit that can often get
/// away with an incomplete element type) — pulling in the whole
/// CanvasTextWidget class (and its ImDrawList/ImFont/stb_textedit
/// dependencies) just for this would be a much heavier interop surface than
/// this plain struct needs.
#include <string>

struct TextHighlightRule {
  std::string pattern;
  float r = 1.f, g = 1.f, b = 1.f, a = 1.f;
  int priority = 0;
  /// 0 = whole match; >0 = that capture group only.
  int capture_group = 0;
};
