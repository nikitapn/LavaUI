#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>

/// Last frame of each application, so a window comes back where the user
/// left it.
///
/// Keyed by `app_id` (Wayland) / WM_CLASS (X11) / the name a Lava client
/// passed to `CreateSurface`. The title is not an identity: it changes with
/// the document. One slot per application, which is the last closed (or
/// last moved) *ordinary* window of that name. Dialogs and tool windows
/// share that identity without being that window, and must not read or
/// write this slot — otherwise a viewer inherits the parent's size and
/// maximized state. A second ordinary window of the same name does
/// inherit the slot: it is the same application, and there is no way to
/// tell one apart from a toolkit re-creating the window it just mapped.
///
/// Lives in its own file, not `lava.conf`. That file is about the machine
/// and people edit it; this one is a cache the compositor rewrites, and
/// mixing the two would make a surgical settings write fight a placement
/// dump.
namespace lava {

struct WindowPlacement {
  int x = 0;
  int y = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  bool maximized = false;

  bool usable() const { return width > 0 && height > 0; }

  bool operator==(const WindowPlacement &other) const {
    return x == other.x && y == other.y && width == other.width &&
           height == other.height && maximized == other.maximized;
  }
};

class WindowMemory {
 public:
  /// `$LAVA_WINDOWS`, else `~/.config/lava/windows` for a session
  /// compositor. A nested one writes under `$XDG_RUNTIME_DIR` so a
  /// development compositor does not overwrite the session the user is
  /// sitting in.
  static std::string defaultPath(bool nested);

  /// Missing file is empty memory, not an error.
  static WindowMemory load(const std::string &path);

  const WindowPlacement *find(const std::string &appId) const;

  /// Updates the in-memory slot. The file is not touched here — a drag
  /// would otherwise rewrite it on every release. `flush` is what writes,
  /// from a timer or from shutdown.
  void remember(const std::string &appId, const WindowPlacement &placement);

  /// Writes if anything changed since the last successful write. False
  /// on I/O error; the in-memory slots are unchanged either way.
  bool flush();

  bool dirty() const { return dirty_; }

  const std::string &path() const { return path_; }

 private:
  bool save() const;

  std::string path_;
  std::unordered_map<std::string, WindowPlacement> byApp_;
  bool dirty_ = false;
};

}  // namespace lava
