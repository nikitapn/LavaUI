#pragma once

// Shared-memory pixel arena: pixels a client rasterised, handed to the renderer
// without going through RPC.
//
// The draw arena's sibling, and a much simpler one, because nothing in it is
// read continuously. A draw arena is a live frame the renderer may be drawing
// out of at any moment; a pixel arena is scratch the client writes into and
// then lends, one region at a time, for the length of one `UploadPixels` call.
// So there are no slots, no generations and no header: the client owns the
// layout and the call says where to look.
//
// The consumer never maps it. It keeps the open file and `pread`s each region,
// which costs the same kernel copy a `memcpy` out of a mapping would, and
// turns a client that truncates the object under it into a short read instead
// of a SIGBUS in the compositor. Truncation is the one thing a mapping cannot
// defend against without sealing, and sealing needs a memfd, which needs fd
// passing, which the control plane does not have.

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace canvas::ipc {

/// Byte order of one pixel, in memory order. Mirrors `lava::PixelFormat` in
/// the IDL, value for value.
enum class PixelFormat : uint32_t {
  Rgba8 = 0,
  Bgra8 = 1,
  Rgbx8 = 2,
  Bgrx8 = 3,
};

/// Where a picture sits in an arena: everything about a region but which
/// arena it is in.
struct PixelLayout {
  uint64_t offset = 0;
  uint32_t width = 0;
  uint32_t height = 0;
  uint32_t stride = 0;
  PixelFormat format = PixelFormat::Rgba8;
};

/// The longest side a region may have. Vulkan guarantees 4096 and every
/// desktop GPU does 16384; past that the upload would fail on the device
/// rather than here, after the copy was already paid for.
constexpr uint32_t kMaxPixelSide = 16384;

/// The `shm_open` prefix every pixel arena carries. The consumer refuses any
/// other name, so attaching one cannot open some other process's mapping.
constexpr const char *kPixelArenaPrefix = "/lava-pixels-";

/// Bytes a layout spans from its first byte to its last: every row's stride
/// but the last one's, which needs only its pixels. Assumes a valid layout.
uint64_t pixelSpan(const PixelLayout &layout);

/// Why `layout` does not describe pixels inside `arenaBytes`, or null if it
/// does. Overflow-safe: every product is checked in 64 bits against limits
/// that keep it far from wrapping.
const char *checkPixelLayout(const PixelLayout &layout, uint64_t arenaBytes);

/// Converts `layout`'s rows at `src` to tightly packed RGBA8 at `dst`.
///
/// `dst` may be `src` itself, which is how the consumer converts in place: a
/// packed row is never longer than a strided one, so writing row `y` never
/// reaches a row not yet read. `dst` must hold `width * height * 4` bytes.
void packRgba(const uint8_t *src, const PixelLayout &layout, uint8_t *dst);

/// The client's end: creates the object, maps it and writes into it.
///
/// Pimpl'd and movable, like `DrawArena`, so Swift imports it as a class.
class PixelArena {
 public:
  PixelArena();
  ~PixelArena();
  PixelArena(PixelArena &&) noexcept;
  PixelArena &operator=(PixelArena &&) noexcept;
  PixelArena(const PixelArena &) = delete;
  PixelArena &operator=(const PixelArena &) = delete;

  /// Creates `/lava-pixels-<id>` of `bytes` and maps it. Fails if the name
  /// exists, so two arenas never share one by accident.
  bool create(const std::string &id, size_t bytes);

  /// Copies `count` bytes from `src` to `offset`. False, and nothing written,
  /// if that would run past the end.
  ///
  /// A copy rather than a pointer into the mapping because Swift's interop
  /// imports pointer parameters and not pointer returns, and because every
  /// write is then bounds-checked by construction.
  bool write(uint64_t offset, const uint8_t *src, size_t count);

  /// Removes the name. The mapping stays valid, and so does the renderer's
  /// open file; this only stops the object outliving both if the client is
  /// killed. Call it once the renderer has attached. The destructor does it
  /// too, if nobody did.
  void unlinkName();

  bool isOpen() const;
  /// The `shm_open` name, for `AttachPixelArena`. By value: Swift does not
  /// import a reference return from a class it cannot copy.
  std::string name() const;
  size_t size() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

/// The renderer's end: an open file, read a region at a time. Never mapped —
/// see the top of this file.
class PixelArenaReader {
 public:
  PixelArenaReader() = default;
  ~PixelArenaReader();
  PixelArenaReader(PixelArenaReader &&) noexcept;
  PixelArenaReader &operator=(PixelArenaReader &&) noexcept;
  PixelArenaReader(const PixelArenaReader &) = delete;
  PixelArenaReader &operator=(const PixelArenaReader &) = delete;

  /// Opens `name` read-only. False if it lacks the prefix, does not exist,
  /// or is not a regular shared-memory object.
  bool open(const std::string &name);

  /// Reads `layout` and converts it to packed RGBA8 in `out`. Null on
  /// success, otherwise why not; `out` is unspecified then.
  ///
  /// Checked against the object's size *now*, not at open: the client can
  /// grow or shrink it in between, and a short read is reported the same way
  /// as a layout that never fitted.
  const char *read(const PixelLayout &layout, std::vector<uint8_t> &out) const;

  bool isOpen() const { return fd_ >= 0; }

 private:
  int fd_ = -1;
};

} // namespace canvas::ipc
