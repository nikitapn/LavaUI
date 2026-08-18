// Per-workspace focus MRU. No compositor, no display.

#include "focus_history.hpp"

#include <cstdio>
#include <initializer_list>
#include <vector>

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

/// The order is the whole point of the list, so the checks are on the
/// whole list rather than on whichever id happens to be at the front.
bool is(const std::vector<uint32_t> &got, std::initializer_list<uint32_t> want) {
  if (got.size() != want.size()) return false;
  auto it = want.begin();
  for (uint32_t id : got) {
    if (id != *it++) return false;
  }
  return true;
}

void recordOrdersMostRecentFirst() {
  FocusHistory h;
  h.record(0, 1);
  h.record(0, 2);
  h.record(0, 3);
  CHECK(is(h.of(0), {3, 2, 1}));
  h.forget(3);
  CHECK(is(h.of(0), {2, 1}));
}

void workspaceIsolation() {
  FocusHistory h;
  h.record(0, 10);
  h.record(1, 20);
  CHECK(is(h.of(0), {10}));
  CHECK(is(h.of(1), {20}));
  CHECK(h.of(2).empty());
  // Closing takes a window off every workspace, wherever it ended up.
  h.forget(10);
  CHECK(h.of(0).empty());
  CHECK(is(h.of(1), {20}));
}

void reRecordMovesToFront() {
  FocusHistory h;
  h.record(0, 1);
  h.record(0, 2);
  h.record(0, 1);
  CHECK(is(h.of(0), {1, 2}));
}

void moveBetweenWorkspaces() {
  FocusHistory h;
  h.record(0, 5);
  h.record(0, 6);
  h.move(6, 0, 2);
  CHECK(is(h.of(0), {5}));
  CHECK(is(h.of(2), {6}));
  // Sending a window where it already is leaves the order alone.
  h.move(5, 0, 0);
  CHECK(is(h.of(0), {5}));
}

void capsAtLimit() {
  FocusHistory h;
  for (uint32_t i = 1; i <= FocusHistory::kLimit + 5; ++i) {
    h.record(0, i);
  }
  CHECK(h.of(0).size() == FocusHistory::kLimit);
  CHECK(h.of(0).front() == FocusHistory::kLimit + 5);
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
  CHECK(h.of(0).empty());
  CHECK(h.of(FocusHistory::kWorkspaces).empty());
  h.record(0, 3);
  h.forget(0);
  CHECK(is(h.of(0), {3}));
}

}  // namespace

int main() {
  recordOrdersMostRecentFirst();
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
