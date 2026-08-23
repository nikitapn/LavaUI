// Draw arena handoff, especially across a growth.
//
// Regression cover for the crash of 2026-08-17: the compositor segfaulted in
// `RenderWindow::render` while a maximizing LavaTerm grew its arena, because
// the consumer unmapped the generation it had handed a `DrawList` out of
// before it had anything to replace that list with. See `acquireFrame`.
//
// No GPU, no display, no second process: an arena is plain shared memory, so a
// producer and a consumer in one process exercise the whole protocol.

#include "ipc/draw_arena.hpp"

#include <unistd.h>

#include <cstdio>
#include <cstring>
#include <string>

using canvas::DrawList;
using canvas::ipc::ArenaCapacity;
using canvas::ipc::ArenaFrame;
using canvas::ipc::DrawArena;

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

/// Small enough that a growth is one call away, and distinct per array so a
/// stride computed from the wrong field would not accidentally agree.
constexpr ArenaCapacity kTiny{/*commands=*/8, /*glyphs=*/16,
                              /*meshVertices=*/8, /*spatialVertices=*/4,
                              /*gradients=*/2};

/// A name no other test run or leftover arena can collide with.
std::string uniqueId(const char *what)
{
  return std::string("test-") + what + "-" + std::to_string(::getpid());
}

/// Writes `count` recognisable commands and publishes them.
void publish(DrawArena &producer, ArenaFrame &frame, uint32_t count,
             uint32_t firstKind)
{
  for (uint32_t i = 0; i < count; ++i) {
    frame.commands[i]       = canvas::DrawCommand{};
    frame.commands[i].kind  = firstKind + i;
    frame.commands[i].param = i;
  }
  producer.commitFrame(frame, ArenaCapacity{count, 0, 0, 0, 0});
}

/// How many of this arena's generations this process still has mapped.
///
/// The point of the test that uses it is that a consumer keeping an old
/// generation readable does not thereby keep it *forever*.
int mappedGenerations(const std::string &id)
{
  std::FILE *maps = std::fopen("/proc/self/maps", "r");
  if (maps == nullptr) return -1;  // not Linux, or no /proc: skip the check
  const std::string needle = "lava-arena-" + id + "-";
  char line[1024];
  int  found = 0;
  while (std::fgets(line, sizeof line, maps) != nullptr) {
    if (std::strstr(line, needle.c_str()) != nullptr) ++found;
  }
  std::fclose(maps);
  return found;
}

// ─── the frame a consumer is holding survives a growth ──────────────────────

/// The crash. A producer grows *mid-frame*, so between the growth and the
/// commit the newest generation exists with nothing published in it. A
/// consumer polling in that window has to come back "nothing new" without
/// invalidating the frame its caller is still drawing — which is exactly what
/// a resize repaint does.
void heldFrameSurvivesGrowth()
{
  const std::string id = uniqueId("growth");
  DrawArena producer;
  CHECK(producer.create(id, kTiny));
  DrawArena consumer;
  CHECK(consumer.open(id));

  ArenaFrame frame = producer.beginFrame();
  CHECK(bool(frame));
  publish(producer, frame, 3, 100);

  DrawList held;
  CHECK(consumer.acquireFrame(held));
  CHECK(held.commandCount == 3);
  CHECK(held.commands[0].kind == 100);

  // Grow without committing, twice — the crash had the consumer three
  // generations behind, because one poll follows the whole chain.
  ArenaFrame growing = producer.beginFrame();
  CHECK(bool(growing));
  CHECK(producer.growFrame(growing, ArenaCapacity{32, 0, 0, 0, 0},
                           ArenaCapacity{0, 0, 0, 0, 0}));
  CHECK(producer.growFrame(growing, ArenaCapacity{128, 0, 0, 0, 0},
                           ArenaCapacity{0, 0, 0, 0, 0}));
  CHECK(producer.generation() == 2);

  DrawList newer;
  CHECK(!consumer.acquireFrame(newer));   // nothing published in generation 2 yet
  CHECK(consumer.generation() == 2);      // but the consumer has followed

  // The redraw that used to fault: the caller still holds a generation 0 list.
  CHECK(held.commandCount == 3);
  CHECK(held.commands[0].kind == 100);
  CHECK(held.commands[2].param == 2);

  // And the frame the producer eventually commits arrives normally.
  publish(producer, growing, 40, 200);
  CHECK(consumer.acquireFrame(newer));
  CHECK(newer.commandCount == 40);
  CHECK(newer.commands[39].kind == 239);
}

/// The generation kept alive for the old list is dropped once there is a newer
/// one, rather than accumulating a mapping per growth.
void oldGenerationIsNotKeptForever()
{
  const std::string id = uniqueId("nokeep");
  DrawArena producer;
  CHECK(producer.create(id, kTiny));
  DrawArena consumer;
  CHECK(consumer.open(id));

  ArenaFrame frame = producer.beginFrame();
  publish(producer, frame, 2, 1);
  DrawList list;
  CHECK(consumer.acquireFrame(list));

  const int before = mappedGenerations(id);
  if (before < 0) return;  // no /proc; nothing to assert
  // One mapping each side of generation 0.
  CHECK(before == 2);

  ArenaFrame growing = producer.beginFrame();
  CHECK(producer.growFrame(growing, ArenaCapacity{32, 0, 0, 0, 0},
                           ArenaCapacity{0, 0, 0, 0, 0}));
  CHECK(!consumer.acquireFrame(list));
  // Generation 0 is now held by both sides for the consumer's sake, plus
  // generation 1 on each: four.
  CHECK(mappedGenerations(id) == 4);

  publish(producer, growing, 5, 1);
  CHECK(consumer.acquireFrame(list));
  // The consumer has let generation 0 go; the producer keeps it pinned so a
  // late consumer can still join by name.
  CHECK(mappedGenerations(id) == 3);
}

// ─── the parts the growth path depends on ───────────────────────────────────

/// An idle arena says "nothing new" rather than handing the same frame out
/// twice — the condition that made the growth window a crash instead of a
/// redundant repaint.
void idleArenaHasNothingNew()
{
  const std::string id = uniqueId("idle");
  DrawArena producer;
  CHECK(producer.create(id, kTiny));
  DrawArena consumer;
  CHECK(consumer.open(id));

  DrawList list;
  CHECK(!consumer.acquireFrame(list));  // nothing published at all

  ArenaFrame frame = producer.beginFrame();
  publish(producer, frame, 1, 7);
  CHECK(consumer.acquireFrame(list));
  CHECK(!consumer.acquireFrame(list));  // same frame, second look
  CHECK(list.commands[0].kind == 7);    // and it is still readable
}

/// A producer that miscounts draws less, it does not scribble past the slot.
void countsAreClampedToCapacity()
{
  const std::string id = uniqueId("clamp");
  DrawArena producer;
  CHECK(producer.create(id, kTiny));
  DrawArena consumer;
  CHECK(consumer.open(id));

  ArenaFrame frame = producer.beginFrame();
  CHECK(frame.capacity.commands == kTiny.commands);
  for (uint32_t i = 0; i < kTiny.commands; ++i) {
    frame.commands[i]      = canvas::DrawCommand{};
    frame.commands[i].kind = i;
  }
  // Twice the capacity, in every array.
  producer.commitFrame(frame, ArenaCapacity{kTiny.commands * 2,
                                            kTiny.glyphs * 2,
                                            kTiny.meshVertices * 2,
                                            kTiny.spatialVertices * 2,
                                            kTiny.gradients * 2});

  DrawList list;
  CHECK(consumer.acquireFrame(list));
  CHECK(list.commandCount == kTiny.commands);
  CHECK(list.glyphCount == kTiny.glyphs);
  CHECK(list.meshVertexCount == kTiny.meshVertices);
  CHECK(list.spatialVertexCount == kTiny.spatialVertices);
  CHECK(list.gradientCount == kTiny.gradients);
}

/// Two producers on one id is a bug, and the second one has to be told rather
/// than quietly sharing the first one's memory.
void secondProducerIsRefused()
{
  const std::string id = uniqueId("dup");
  DrawArena first;
  CHECK(first.create(id, kTiny));
  DrawArena second;
  CHECK(!second.create(id, kTiny));
}

/// A consumer that arrives after the growth opens generation 0 by name and
/// hops to the newest, which is why the producer never unlinks generation 0.
void lateConsumerJoinsAtTheNewestGeneration()
{
  const std::string id = uniqueId("late");
  DrawArena producer;
  CHECK(producer.create(id, kTiny));

  ArenaFrame growing = producer.beginFrame();
  CHECK(producer.growFrame(growing, ArenaCapacity{32, 0, 0, 0, 0},
                           ArenaCapacity{0, 0, 0, 0, 0}));
  publish(producer, growing, 9, 50);

  DrawArena consumer;
  CHECK(consumer.open(id));
  CHECK(consumer.generation() == 1);
  DrawList list;
  CHECK(consumer.acquireFrame(list));
  CHECK(list.commandCount == 9);
  CHECK(list.commands[0].kind == 50);
}

/// Back-pressure: the producer can see whether its last frame was taken.
///
/// This is the whole of the frame-callback contract — without it a producer
/// has no way to tell "the consumer is keeping up" from "the consumer has not
/// looked in a hundred frames", so a client that re-dirties its own frame
/// publishes as fast as it can build a draw list.
void producerSeesWhetherItsFrameWasTaken()
{
  const std::string id = uniqueId("inflight");
  DrawArena producer;
  CHECK(producer.create(id, kTiny));
  // Nothing published yet is not a frame in flight.
  CHECK(producer.framesInFlight() == 0);

  DrawArena consumer;
  CHECK(consumer.open(id));
  CHECK(consumer.framesInFlight() == 0);  // consumer side is always zero

  ArenaFrame f = producer.beginFrame();
  publish(producer, f, 4, 7);
  CHECK(producer.framesInFlight() == 1);

  // Still one: publishing again without the consumer looking does not
  // discharge anything, which is exactly the runaway this detects.
  ArenaFrame f2 = producer.beginFrame();
  publish(producer, f2, 4, 7);
  CHECK(producer.framesInFlight() == 2);

  DrawList list;
  CHECK(consumer.acquireFrame(list));
  // The consumer takes the newest, so both are discharged at once — it is a
  // sequence, not a queue.
  CHECK(producer.framesInFlight() == 0);

  // And a fresh publish is in flight again.
  ArenaFrame f3 = producer.beginFrame();
  publish(producer, f3, 4, 7);
  CHECK(producer.framesInFlight() == 1);
}

} // namespace

int main()
{
  heldFrameSurvivesGrowth();
  oldGenerationIsNotKeptForever();
  idleArenaHasNothingNew();
  countsAreClampedToCapacity();
  secondProducerIsRefused();
  lateConsumerJoinsAtTheNewestGeneration();
  producerSeesWhetherItsFrameWasTaken();

  if (failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::puts("draw arena: ok");
  return 0;
}
