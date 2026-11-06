#pragma once

#include <algorithm>
#include <cmath>

#include "wlr.hpp"

namespace lava {

/// An output's box in the layout, widened to reach its last device pixel.
///
/// wlroots sizes an output's logical box by truncating: 2560 pixels at scale
/// 1.5 is 1706.67 layout pixels, and the box says 1706 — which ends at device
/// pixel 2559 of 2560. So everything sized from that box to *fill* the screen
/// (a maximized window, a panel, the wallpaper) stops one device pixel short of
/// the right and bottom edges, and the strip shows whatever is under it: the
/// backdrop colour headlessly, stale pixels on a real screen. Scales that
/// divide the mode — 1.25 of 2560, 2 of anything even — never show it, which is
/// why it looked like it depended on which scale came before.
///
/// Rounded up instead, the box overhangs by under one layout pixel, which the
/// output clips. Use this for anything that should *cover* an output; keep
/// `wlr_output_layout_get_box` for converting coordinates, where the origin is
/// what matters and the two agree.
inline wlr_box coveringBox(wlr_output_layout *layout, wlr_output *output) {
  wlr_box box{};
  wlr_output_layout_get_box(layout, output, &box);
  if (output == nullptr || box.width <= 0 || box.height <= 0) return box;
  const double scale = output->scale > 0.f ? output->scale : 1.0;
  int width = 0, height = 0;
  wlr_output_transformed_resolution(output, &width, &height);
  // The epsilon keeps an exact division exact: 2560 / 1.25 is 2048, not 2049.
  box.width = std::max(box.width, static_cast<int>(std::ceil(width / scale - 1e-4)));
  box.height = std::max(box.height, static_cast<int>(std::ceil(height / scale - 1e-4)));
  return box;
}

/// The union of every output's `coveringBox`. Empty with no outputs.
inline wlr_box coveringUnion(wlr_output_layout *layout) {
  wlr_box out{};
  bool any = false;
  wlr_output_layout_output *entry = nullptr;
  wl_list_for_each(entry, &layout->outputs, link) {
    const wlr_box box = coveringBox(layout, entry->output);
    if (box.width <= 0 || box.height <= 0) continue;
    if (!any) {
      out = box;
      any = true;
      continue;
    }
    const int x1 = std::max(out.x + out.width, box.x + box.width);
    const int y1 = std::max(out.y + out.height, box.y + box.height);
    out.x = std::min(out.x, box.x);
    out.y = std::min(out.y, box.y);
    out.width = x1 - out.x;
    out.height = y1 - out.y;
  }
  return out;
}

}  // namespace lava
