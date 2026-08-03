#pragma once

// Shared-memory draw arena: one frame's draw list, written by one process and
// rendered by another.
//
// The transport is a mapping rather than a queue on purpose. A draw list is
// not a message — its size is not known when the frame starts, because
// `DrawList` grows *during* emit as the tree turns out to be bigger than the
// last one was. A ring buffer has to be told how many bytes to reserve at
// claim time, so putting frames through one would mean either reserving a
// worst case every frame or copying the finished list in. A mapping the
// producer writes straight into keeps the property that makes the in-process
// path fast: the UI writes draw commands exactly once, into the memory the
// renderer will read them from.
//
// # Layout
//
//   +--------------------------------------------------+
//   | ArenaHeader          (one page)                   |
//   +--------------------------------------------------+
//   | slot 0: commands | glyphs | meshVerts | spatial   |
//   | slot 1: ...                                       |
//   | slot 2: ...                                       |
//   +--------------------------------------------------+
//
// Every offset is *derived* from the capacities in the header, never
// transmitted. That is a deliberate safety property: a hostile producer can
// lie about how many elements it wrote, and those counts are clamped on the
// way out, but it cannot make the consumer compute a pointer outside the
// mapping, because the consumer does not read any pointer or offset from
// shared memory at all.
//
// # Handoff
//
// Triple buffered, single producer, single consumer, no blocking in either
// direction. The producer writes a slot that is neither the one it published
// last nor the one the consumer says it is holding; with three slots exactly
// one such slot always exists, so a producer never waits for a slow renderer
// and a renderer never sees a frame torn out from under it.
//
// # Growth
//
// A frame that outgrows the arena cannot be finished in it, and cannot be
// abandoned either — `DrawList` is already halfway through emitting. So the
// producer creates the next *generation* (a new, larger mapping under a
// derived name), copies the partial frame across, and continues writing where
// it left off. The old header records the new generation number, so the
// consumer discovers the move by reading memory it is already mapped to; no
// control channel is needed for what is fundamentally an allocation detail.

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

// Relative, not `-Isrc`: this header is re-exported to Swift through
// `canvas_pub/`, and the module map parses it without the engine target's
// include paths. Same reason `canvas_engine.hpp` does it this way.
#include "../render/draw_command.hpp"

// Swift's C++ interop refuses to import anything handing out a raw pointer
// unless it is told the caller takes responsibility. `ArenaFrame` is four of
// them, so the methods producing one need the same opt-in `Engine`'s
// `drawCommandData()` uses. Defined here rather than shared because these two
// headers are re-exported independently and neither includes the other.
#ifndef CANVAS_SWIFT_UNSAFE_POINTER
#if defined(__has_attribute) && __has_attribute(swift_attr)
#define CANVAS_SWIFT_UNSAFE_POINTER __attribute__((swift_attr("import_unsafe")))
#else
#define CANVAS_SWIFT_UNSAFE_POINTER
#endif
#endif

namespace canvas::ipc {

/// Per-slot element counts. Used both for "how much fits" (capacity) and "how
/// much was written" (counts), because they are compared constantly and
/// having one type makes the comparison a one-liner rather than four.
struct ArenaCapacity {
  uint32_t commands       = 0;
  uint32_t glyphs         = 0;
  uint32_t meshVertices   = 0;
  uint32_t spatialVertices = 0;

  /// Element-wise "fits inside".
  bool fitsIn(const ArenaCapacity &limit) const
  {
    return commands <= limit.commands && glyphs <= limit.glyphs
           && meshVertices <= limit.meshVertices
           && spatialVertices <= limit.spatialVertices;
  }

  /// Element-wise maximum — what a growth has to satisfy when only one of
  /// the four arrays actually overflowed.
  ArenaCapacity unionWith(const ArenaCapacity &other) const;
};

/// What LavaUI's first frame asks for today (`DrawList.init`), which makes the
/// common case a single mapping with no growth at all.
inline constexpr ArenaCapacity kDefaultArenaCapacity{
  /*commands=*/1024, /*glyphs=*/4096, /*meshVertices=*/1024,
  /*spatialVertices=*/1024};

/// One frame in progress: where to write, and how much room there is.
///
/// The pointers are into the producer's mapping and are invalidated by
/// `growFrame` — which is why that takes the frame by reference and rewrites
/// it, rather than leaving the caller holding pointers into a mapping that is
/// no longer the current generation.
struct CANVAS_SWIFT_UNSAFE_POINTER ArenaFrame {
  DrawCommand   *commands        = nullptr;
  GlyphInstance *glyphs          = nullptr;
  MeshVertex    *meshVertices    = nullptr;
  SpatialVertex *spatialVertices = nullptr;
  ArenaCapacity  capacity;
  uint32_t       slot  = 0;
  bool           valid = false;

  explicit operator bool() const { return valid; }
};

/// A draw arena, opened as either the producer or the consumer.
///
/// Pimpl'd and movable rather than a `unique_ptr` factory so Swift's C++
/// interop imports it as a class — the same shape `canvas::Engine` uses, for
/// the same reason.
class DrawArena {
 public:
  static constexpr uint32_t kSlots = 3;
  /// Refuses anything larger, per array, so a bad capacity request fails here
  /// rather than as a several-gigabyte `ftruncate`.
  static constexpr uint32_t kMaxElements = 1u << 24;

  DrawArena();
  ~DrawArena();
  DrawArena(DrawArena &&) noexcept;
  DrawArena &operator=(DrawArena &&) noexcept;
  DrawArena(const DrawArena &)            = delete;
  DrawArena &operator=(const DrawArena &) = delete;

  // ─── Producer ────────────────────────────────────────────────────────

  /// Creates generation 0 and maps it. `id` names the arena; the shared
  /// memory objects are `/lava-arena-<id>-<generation>`.
  ///
  /// Fails if an arena with this id already exists, which is what stops two
  /// producers from silently writing over each other.
  bool create(const std::string &id, ArenaCapacity capacity = kDefaultArenaCapacity);

  /// Claims a slot to write into. The returned pointers stay valid until
  /// `commitFrame`, or until `growFrame` replaces them.
  ArenaFrame beginFrame() CANVAS_SWIFT_UNSAFE_POINTER;

  /// Enlarges the arena mid-frame, preserving the `written` prefix of the
  /// frame in progress.
  ///
  /// `atLeast` is the capacity the caller needs *now*; the actual new
  /// capacity at least doubles every array that grew, so a frame that grows
  /// element by element does not create a generation per element.
  ///
  /// On success `frame` is rewritten to point into the new generation, with
  /// the already-written prefix copied across, and the caller carries on as
  /// if nothing happened. On failure `frame` is untouched and still usable —
  /// the caller has to finish within the capacity it has, or drop the frame.
  bool growFrame(ArenaFrame &frame, ArenaCapacity atLeast,
                 ArenaCapacity written) CANVAS_SWIFT_UNSAFE_POINTER;

  /// Publishes the frame. Counts above the slot's capacity are clamped,
  /// because a producer that miscounts should draw less, not corrupt.
  void commitFrame(const ArenaFrame &frame,
                   ArenaCapacity written) CANVAS_SWIFT_UNSAFE_POINTER;

  // ─── Consumer ────────────────────────────────────────────────────────

  /// Maps the newest generation of an existing arena.
  bool open(const std::string &id);

  /// Takes the most recently published frame, if it is one this consumer has
  /// not already seen. Returns false when there is nothing new — which is the
  /// normal answer on an idle frame, not an error.
  ///
  /// Follows a generation handoff transparently: a producer that grew the
  /// arena between frames is picked up here.
  ///
  /// The returned `DrawList` points into the mapping and stays valid until
  /// `releaseFrame`.
  bool acquireFrame(canvas::DrawList &out);

  /// Releases the acquired slot back to the producer. Safe to call without a
  /// matching `acquireFrame`.
  void releaseFrame();

  // ─── Both ────────────────────────────────────────────────────────────

  bool isOpen() const;
  /// Generation currently mapped. Changes when the arena grows.
  uint32_t generation() const;
  ArenaCapacity capacity() const;
  const std::string &id() const;
  /// Total bytes mapped, for logging and tests.
  size_t mappedBytes() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

} // namespace canvas::ipc
