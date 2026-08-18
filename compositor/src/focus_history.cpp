#include "focus_history.hpp"

#include <algorithm>

namespace lava {
namespace {

bool validWorkspace(uint32_t workspace) {
  return workspace < FocusHistory::kWorkspaces;
}

void eraseId(std::vector<uint32_t> &list, uint32_t id) {
  std::erase(list, id);
}

void pushFront(std::vector<uint32_t> &list, uint32_t id) {
  eraseId(list, id);
  list.insert(list.begin(), id);
  if (list.size() > FocusHistory::kLimit) {
    list.resize(FocusHistory::kLimit);
  }
}

}  // namespace

const std::vector<uint32_t> FocusHistory::kEmpty{};

void FocusHistory::record(uint32_t workspace, uint32_t id) {
  if (id == 0 || !validWorkspace(workspace)) return;
  pushFront(byWorkspace_[workspace], id);
}

void FocusHistory::forget(uint32_t id) {
  if (id == 0) return;
  for (auto &list : byWorkspace_) eraseId(list, id);
}

void FocusHistory::move(uint32_t id, uint32_t from, uint32_t to) {
  if (id == 0 || from == to) return;
  if (validWorkspace(from)) eraseId(byWorkspace_[from], id);
  if (validWorkspace(to)) pushFront(byWorkspace_[to], id);
}

uint32_t FocusHistory::previous(uint32_t workspace, uint32_t except) const {
  if (!validWorkspace(workspace)) return 0;
  for (uint32_t id : byWorkspace_[workspace]) {
    if (id != except) return id;
  }
  return 0;
}

const std::vector<uint32_t> &FocusHistory::of(uint32_t workspace) const {
  if (!validWorkspace(workspace)) return kEmpty;
  return byWorkspace_[workspace];
}

}  // namespace lava
