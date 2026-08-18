// Per-workspace focus MRU. No compositor, no display.

#include "focus_history.hpp"

#include <cstdio>

using lava::FocusHistory;

namespace {

int failures = 0;

#define CHECK(cond)                                                            \
  do {                                                                         \
    if (!(cond)) {                                                             \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__,    \
                   #cond);                                                     \
      ++failures;                                                              \
    }                                                                          \
  } while (0)

void recordAndPrevious() {
  FocusHistory h;
  h.record(0, 1);
  h.record(0, 2);
  h.record(0, 3);
  CHECK(h.previous(0) == 3);
  CHECK(h.previous(0, 3) == 2);
  CHECK(h.previous(0, 2) == 3);
  h.forget(3);
  CHECK(h.previous(0) == 2);
  CHECK(h.previous(0, 2) == 1);
}

void workspaceIsolation() {
  FocusHistory h;
  h.record(0, 10);
  h.record(1, 20);
  CHECK(h.previous(0) == 10);
  CHECK(h.previous(1) == 20);
  CHECK(h.previous(2) == 0);
  h.forget(10);
  CHECK(h.previous(0) == 0);
  CHECK(h.previous(1) == 20);
}

void reRecordMovesToFront() {
  FocusHistory h;
  h.record(0, 1);
  h.record(0, 2);
  h.record(0, 1);
  CHECK(h.of(0).size() == 2);
  CHECK(h.previous(0) == 1);
  CHECK(h.previous(0, 1) == 2);
}

void moveBetweenWorkspaces() {
  FocusHistory h;
  h.record(0, 5);
  h.record(0, 6);
  h.move(6, 0, 2);
  CHECK(h.previous(0) == 5);
  CHECK(h.previous(2) == 6);
  CHECK(h.previous(0, 5) == 0);
}

void capsAtLimit() {
  FocusHistory h;
  for (uint32_t i = 1; i <= FocusHistory::kLimit + 5; ++i) {
    h.record(0, i);
  }
  CHECK(h.of(0).size() == FocusHistory::kLimit);
  CHECK(h.previous(0) == FocusHistory::kLimit + 5);
  // Oldest ids fell off the back.
  bool foundOldest = false;
  for (uint32_t id : h.of(0)) {
    if (id == 1) foundOldest = true;
  }
  CHECK(!foundOldest);
}

void ignoresZeroAndOutOfRange() {
  FocusHistory h;
  h.record(0, 0);
  h.record(FocusHistory::kWorkspaces, 7);
  CHECK(h.previous(0) == 0);
  CHECK(h.previous(FocusHistory::kWorkspaces) == 0);
  h.record(0, 3);
  h.forget(0);
  CHECK(h.previous(0) == 3);
}

}  // namespace

int main() {
  recordAndPrevious();
  workspaceIsolation();
  reRecordMovesToFront();
  moveBetweenWorkspaces();
  capsAtLimit();
  ignoresZeroAndOutOfRange();
  if (failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  return 0;
}
