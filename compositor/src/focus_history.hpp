#pragma once

#include <cstdint>
#include <vector>

namespace lava {

/// MRU keyboard-focus list, one per workspace.
///
/// Closing (or minimizing) the active window should hand the keyboard to
/// whoever had it last on *that* workspace. Stacking order is not that
/// list: Lava clients never join the foreign `toplevels` chain, and a
/// raise can bury a window the user is about to want back.
///
/// Ids are compositor surface ids. Dead or minimized ones stay in the
/// list until `forget`; the compositor skips them when it picks.
class FocusHistory {
 public:
  /// Matches `Workspaces::kCount`. A window on workspace 9 is a bug
  /// elsewhere; `record` ignores it rather than growing the table.
  static constexpr uint32_t kWorkspaces = 9;
  static constexpr size_t kLimit = 32;

  /// Moves `id` to the front of `workspace`. No-op for 0.
  void record(uint32_t workspace, uint32_t id);

  /// Drops `id` from every workspace. Closing is the usual caller.
  void forget(uint32_t id);

  /// The window is still the same window; it just lives somewhere else.
  void move(uint32_t id, uint32_t from, uint32_t to);

  /// Most recently recorded id on `workspace` that is not `except`, or 0.
  uint32_t previous(uint32_t workspace, uint32_t except = 0) const;

  const std::vector<uint32_t> &of(uint32_t workspace) const;

 private:
  std::vector<uint32_t> byWorkspace_[kWorkspaces];
  static const std::vector<uint32_t> kEmpty;
};

}  // namespace lava
