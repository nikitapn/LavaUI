#include "ipc/draw_arena.hpp"

#include <dirent.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <signal.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <iostream>
#include <string_view>
#include <vector>

namespace canvas::ipc {
namespace {

constexpr uint32_t kMagic   = 0x4c564441;  // 'LVDA'
// 2 added the gradient array. The layout of every slot changed, so a producer
// and a consumer from either side of that must not agree to share memory —
// which the version check below is exactly what enforces.
constexpr uint32_t kVersion = 2;

/// Every array starts on a cache line so two slots in flight cannot share one
/// with each other.
constexpr size_t kAlign = 64;

constexpr size_t alignUp(size_t v, size_t a) { return (v + a - 1) / a * a; }

/// `published` packs a monotonic frame sequence with the slot it landed in, so
/// a consumer can tell "a new frame" from "the same frame again" with one
/// atomic load. Sequence 0 means nothing has ever been published.
constexpr uint64_t packPublished(uint64_t seq, uint32_t slot)
{
  return (seq << 8) | slot;
}
constexpr uint64_t publishedSeq(uint64_t v) { return v >> 8; }
constexpr uint32_t publishedSlot(uint64_t v) { return static_cast<uint32_t>(v & 0xff); }

/// Shared header. Laid out explicitly because two processes — potentially two
/// *builds* — agree on it; `version` is checked on open.
struct ArenaHeader {
  uint32_t magic;
  uint32_t version;
  uint32_t generation;
  /// The process that created this arena. Only used to tell a live arena from
  /// one a killed producer left behind in `/dev/shm` — see `claimStale`.
  int32_t producerPid;
  /// Non-zero once the producer has moved to a larger mapping. The consumer
  /// discovers a growth by reading this, so growth needs no side channel.
  std::atomic<uint32_t> supersededBy;
  /// Set by the consumer just before it stops using this generation, so the
  /// producer knows when the old mapping can be unlinked.
  std::atomic<uint32_t> consumerLeft;

  uint32_t slots;
  uint32_t capCommands;
  uint32_t capGlyphs;
  uint32_t capMeshVertices;
  uint32_t capSpatialVertices;
  /// Took `pad0`'s place, so adding this did not move any field below it.
  uint32_t capGradients;

  uint64_t payloadBase;
  uint64_t slotStride;

  /// (sequence << 8) | slot of the newest committed frame.
  alignas(64) std::atomic<uint64_t> published;
  /// Slot the consumer is reading, or `kNoSlot`. The producer avoids it.
  alignas(64) std::atomic<uint32_t> acquiredSlot;

  /// Written before `published`, read after — the release/acquire pair on
  /// `published` is what orders them.
  alignas(64) uint32_t counts[DrawArena::kSlots][5];
};

constexpr uint32_t kNoSlot = 0xffffffffu;

static_assert(std::atomic<uint64_t>::is_always_lock_free,
              "the header is shared between processes; a lock-based atomic "
              "would embed a mutex that is not valid across address spaces");
static_assert(std::atomic<uint32_t>::is_always_lock_free, "same");

std::string shmName(const std::string &id, uint32_t generation)
{
  return "/lava-arena-" + id + "-" + std::to_string(generation);
}

/// Byte size of one slot for `cap`, or 0 on overflow.
size_t slotStrideFor(const ArenaCapacity &cap)
{
  const size_t parts[5] = {
    alignUp(static_cast<size_t>(cap.commands) * sizeof(DrawCommand), kAlign),
    alignUp(static_cast<size_t>(cap.glyphs) * sizeof(GlyphInstance), kAlign),
    alignUp(static_cast<size_t>(cap.meshVertices) * sizeof(MeshVertex), kAlign),
    alignUp(static_cast<size_t>(cap.spatialVertices) * sizeof(SpatialVertex), kAlign),
    alignUp(static_cast<size_t>(cap.gradients) * sizeof(GradientDesc), kAlign),
  };
  size_t total = 0;
  for (size_t p : parts) total += p;
  return total;
}

bool capacityInRange(const ArenaCapacity &cap)
{
  return cap.commands <= DrawArena::kMaxElements
         && cap.glyphs <= DrawArena::kMaxElements
         && cap.meshVertices <= DrawArena::kMaxElements
         && cap.spatialVertices <= DrawArena::kMaxElements
         && cap.gradients <= DrawArena::kMaxElements;
}

void logErrno(const char *what, const std::string &name)
{
  std::cerr << "DrawArena: " << what << " " << name << ": " << std::strerror(errno)
            << "\n";
}

/// Unlinks `name` if it was left behind by a producer that no longer exists.
///
/// A producer killed with a signal never runs its destructor, so its shared
/// memory outlives it — and the *next* producer's `O_EXCL` create then fails
/// against a file nobody owns. Rather than making every start a manual
/// `rm /dev/shm/lava-arena-*`, check whether the recorded pid is still alive
/// and reclaim the name if it is not.
///
/// Deliberately conservative about pid reuse: a recycled pid makes a dead
/// arena look live, which refuses to start rather than stealing a running
/// producer's memory. That is the direction to be wrong in.
///
/// `announce` is off for the sweep, which would otherwise print a line per
/// arena on the first run after a long session.
bool claimStale(const std::string &name, bool announce = true)
{
  int fd = ::shm_open(name.c_str(), O_RDONLY, 0600);
  if (fd < 0) return false;
  ArenaHeader header{};
  const ssize_t got = ::read(fd, &header, sizeof(header));
  ::close(fd);
  if (got != static_cast<ssize_t>(sizeof(header)) || header.magic != kMagic) {
    // Not one of ours, or never finished initializing. Either way nothing
    // here is safe to reason about, so leave it alone.
    return false;
  }
  if (header.producerPid > 0 && ::kill(header.producerPid, 0) == 0) return false;
  if (announce) {
    std::cerr << "DrawArena: reclaiming " << name << " from dead pid "
              << header.producerPid << "\n";
  }
  return ::shm_unlink(name.c_str()) == 0;
}

} // namespace

ArenaCapacity ArenaCapacity::unionWith(const ArenaCapacity &other) const
{
  return ArenaCapacity{
    std::max(commands, other.commands),
    std::max(glyphs, other.glyphs),
    std::max(meshVertices, other.meshVertices),
    std::max(spatialVertices, other.spatialVertices),
    std::max(gradients, other.gradients),
  };
}

// ─── Impl ──────────────────────────────────────────────────────────────────

struct DrawArena::Impl {
  /// One mapped generation. The producer keeps superseded ones alive until the
  /// consumer has left them.
  struct Mapping {
    void       *base = nullptr;
    size_t      size = 0;
    uint32_t    generation = 0;
    std::string name;
    /// Generation 0 on the producer side. It is the name a consumer opens, so
    /// unlinking it would make a growing arena impossible to *join* — a
    /// renderer starting after the first growth, or reconnecting after a
    /// restart, has nothing else to look for. It stays mapped and keeps being
    /// updated to point at the newest generation.
    bool pinned = false;

    ArenaHeader *header() const { return static_cast<ArenaHeader *>(base); }
  };

  std::string id;
  bool        isProducer = false;
  Mapping     current;
  /// Superseded generations, unlinked once the consumer has moved on.
  std::vector<Mapping> retired;

  // Producer state.
  uint64_t nextSequence  = 1;
  uint32_t lastPublished = kNoSlot;

  // Consumer state.
  uint64_t lastSeenSequence = 0;
  uint32_t heldSlot         = kNoSlot;
  /// Generations the consumer has moved off but is still keeping mapped,
  /// because the `DrawList` it handed out last points into one of them. Dropped
  /// by `dropLeftBehind` — see `acquireFrame`.
  std::vector<Mapping> leftBehind;

  ~Impl()
  {
    if (heldSlot != kNoSlot) releaseHeld();
    if (!isProducer && current.base) {
      // Tell the producer this generation is free even on an abrupt close, so
      // it does not sit on mappings forever waiting for a consumer that left.
      current.header()->consumerLeft.store(1, std::memory_order_release);
    }
    for (auto &m : retired) {
      m.pinned = false;  // the arena is going away; there is nothing left to join
      unmapAndUnlink(m);
    }
    dropLeftBehind();
    unmapAndUnlink(current);
  }

  /// Unmaps the generations kept alive for a `DrawList` the caller no longer
  /// holds. Consumer side, so this only ever munmaps — the names belong to the
  /// producer, which has retired these generations already.
  void dropLeftBehind()
  {
    for (auto &m : leftBehind) unmapAndUnlink(m);
    leftBehind.clear();
  }

  /// Points every mapping the producer still holds at `generation`, so a
  /// consumer joining or resuming at any of them hops straight to the newest
  /// rather than walking a chain whose middle links may already be gone.
  void republishGeneration(uint32_t generation)
  {
    for (auto &m : retired) {
      if (m.base) m.header()->supersededBy.store(generation, std::memory_order_release);
    }
  }

  void unmapAndUnlink(Mapping &m)
  {
    if (!m.base) return;
    ::munmap(m.base, m.size);
    m.base = nullptr;
    // Only the producer owns the name. A consumer unlinking it would make the
    // arena unopenable for everyone while the producer is still using it.
    if (isProducer && !m.name.empty()) ::shm_unlink(m.name.c_str());
    m.name.clear();
  }

  void releaseHeld()
  {
    if (heldSlot == kNoSlot || !current.base) return;
    current.header()->acquiredSlot.store(kNoSlot, std::memory_order_release);
    heldSlot = kNoSlot;
  }

  ArenaCapacity capacityOf(const Mapping &m) const
  {
    const ArenaHeader *h = m.header();
    return ArenaCapacity{h->capCommands, h->capGlyphs, h->capMeshVertices,
                         h->capSpatialVertices, h->capGradients};
  }

  /// Base of `slot`'s payload, and the sub-array pointers within it.
  template <typename Cmd, typename Gly, typename Mesh, typename Spat,
            typename Grad>
  void slotPointers(const Mapping &m, uint32_t slot, Cmd *&cmds, Gly *&glyphs,
                    Mesh *&mesh, Spat *&spatial, Grad *&gradients) const
  {
    const ArenaHeader *h = m.header();
    auto *bytes = static_cast<uint8_t *>(m.base) + h->payloadBase
                  + static_cast<size_t>(slot) * h->slotStride;
    cmds = reinterpret_cast<Cmd *>(bytes);
    bytes += alignUp(static_cast<size_t>(h->capCommands) * sizeof(DrawCommand), kAlign);
    glyphs = reinterpret_cast<Gly *>(bytes);
    bytes += alignUp(static_cast<size_t>(h->capGlyphs) * sizeof(GlyphInstance), kAlign);
    mesh = reinterpret_cast<Mesh *>(bytes);
    bytes += alignUp(static_cast<size_t>(h->capMeshVertices) * sizeof(MeshVertex), kAlign);
    spatial = reinterpret_cast<Spat *>(bytes);
    bytes += alignUp(static_cast<size_t>(h->capSpatialVertices) * sizeof(SpatialVertex), kAlign);
    gradients = reinterpret_cast<Grad *>(bytes);
  }

  bool mapNew(const std::string &name, ArenaCapacity cap, uint32_t generation,
              Mapping &out);
  bool mapExisting(const std::string &name, Mapping &out);
  /// Drops retired mappings the consumer has finished with.
  void reclaimRetired();
};

bool DrawArena::Impl::mapNew(const std::string &name, ArenaCapacity cap,
                             uint32_t generation, Mapping &out)
{
  const size_t stride = slotStrideFor(cap);
  if (stride == 0) {
    std::cerr << "DrawArena: refusing a zero-sized arena\n";
    return false;
  }
  const size_t payloadBase = alignUp(sizeof(ArenaHeader), 4096);
  const size_t total       = payloadBase + stride * kSlots;

  // O_EXCL: two producers on one id is a bug, and a silent second attach
  // would be a very confusing one.
  int fd = ::shm_open(name.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
  if (fd < 0 && errno == EEXIST && claimStale(name)) {
    fd = ::shm_open(name.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
  }
  if (fd < 0) {
    if (errno == EEXIST) {
      std::cerr << "DrawArena: " << name
                << " already exists and its producer is alive\n";
    } else {
      logErrno("shm_open (create)", name);
    }
    return false;
  }
  if (::ftruncate(fd, static_cast<off_t>(total)) != 0) {
    logErrno("ftruncate", name);
    ::close(fd);
    ::shm_unlink(name.c_str());
    return false;
  }
  void *base = ::mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  ::close(fd);
  if (base == MAP_FAILED) {
    logErrno("mmap", name);
    ::shm_unlink(name.c_str());
    return false;
  }

  auto *h = static_cast<ArenaHeader *>(base);
  std::memset(h, 0, sizeof(ArenaHeader));
  h->version            = kVersion;
  h->generation         = generation;
  h->producerPid        = static_cast<int32_t>(::getpid());
  h->slots              = kSlots;
  h->capCommands        = cap.commands;
  h->capGlyphs          = cap.glyphs;
  h->capMeshVertices    = cap.meshVertices;
  h->capSpatialVertices = cap.spatialVertices;
  h->capGradients       = cap.gradients;
  h->payloadBase        = payloadBase;
  h->slotStride         = stride;
  h->supersededBy.store(0, std::memory_order_relaxed);
  h->consumerLeft.store(0, std::memory_order_relaxed);
  h->published.store(0, std::memory_order_relaxed);
  h->acquiredSlot.store(kNoSlot, std::memory_order_relaxed);
  // Magic last, with a release: a consumer that opens the object between
  // ftruncate and here sees zeroes and rejects it rather than reading a
  // half-initialized header.
  std::atomic_ref<uint32_t>(h->magic).store(kMagic, std::memory_order_release);

  out.base       = base;
  out.size       = total;
  out.generation = generation;
  out.name       = name;
  return true;
}

bool DrawArena::Impl::mapExisting(const std::string &name, Mapping &out)
{
  int fd = ::shm_open(name.c_str(), O_RDWR, 0600);
  if (fd < 0) {
    // "There is no arena by that name" is the normal answer to a consumer
    // asking whether its producer has started yet, not a failure. A renderer
    // that polls until one appears would otherwise print a line per attempt,
    // and the log it buries is the one that says why the arena that *did*
    // appear could not be mapped.
    if (errno != ENOENT) logErrno("shm_open", name);
    return false;
  }
  struct stat st{};
  if (::fstat(fd, &st) != 0 || st.st_size < static_cast<off_t>(sizeof(ArenaHeader))) {
    std::cerr << "DrawArena: " << name << " is too small to be an arena\n";
    ::close(fd);
    return false;
  }
  const size_t total = static_cast<size_t>(st.st_size);
  void *base = ::mmap(nullptr, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  ::close(fd);
  if (base == MAP_FAILED) {
    logErrno("mmap", name);
    return false;
  }

  auto *h = static_cast<ArenaHeader *>(base);
  // Everything below is read from memory another process can write, so it is
  // all checked. The point is not that the producer is expected to lie — it is
  // that the consumer must not be the thing that crashes when it does.
  const uint32_t magic =
    std::atomic_ref<uint32_t>(h->magic).load(std::memory_order_acquire);
  const bool ok = magic == kMagic && h->version == kVersion && h->slots == kSlots
                  && h->payloadBase >= sizeof(ArenaHeader)
                  && capacityInRange(ArenaCapacity{h->capCommands, h->capGlyphs,
                                                   h->capMeshVertices,
                                                   h->capSpatialVertices,
                                                   h->capGradients});
  if (!ok) {
    std::cerr << "DrawArena: " << name << " has a bad header\n";
    ::munmap(base, total);
    return false;
  }
  // The slot geometry must be the one *this* build would have produced for
  // that capacity, and it must fit the file. Recomputing rather than trusting
  // `slotStride` is what keeps every derived pointer inside the mapping.
  // Every field, including `capGradients`. Leaving one out here does not fail
  // loudly at the omission — it silently computes a *shorter* stride than the
  // producer used, which then disagrees with `slotStride` and rejects every
  // arena as inconsistent. Adding an array to the payload means adding it in
  // all three places: `slotStrideFor`, `slotPointers`, and here.
  const size_t stride = slotStrideFor(ArenaCapacity{
    h->capCommands, h->capGlyphs, h->capMeshVertices, h->capSpatialVertices,
    h->capGradients});
  if (stride == 0 || h->slotStride != stride
      || h->payloadBase + stride * kSlots > total) {
    std::cerr << "DrawArena: " << name << " has inconsistent geometry\n";
    ::munmap(base, total);
    return false;
  }

  out.base       = base;
  out.size       = total;
  out.generation = h->generation;
  out.name       = name;
  return true;
}

void DrawArena::Impl::reclaimRetired()
{
  auto done = std::remove_if(retired.begin(), retired.end(), [&](Mapping &m) {
    if (m.pinned) return false;
    if (m.header()->consumerLeft.load(std::memory_order_acquire) == 0) return false;
    unmapAndUnlink(m);
    return true;
  });
  retired.erase(done, retired.end());
}

// ─── DrawArena ─────────────────────────────────────────────────────────────

DrawArena::DrawArena() : impl_(std::make_unique<Impl>()) {}
DrawArena::~DrawArena() = default;
DrawArena::DrawArena(DrawArena &&) noexcept = default;
DrawArena &DrawArena::operator=(DrawArena &&) noexcept = default;

size_t DrawArena::reapStale()
{
#if defined(__linux__)
  DIR *dir = ::opendir("/dev/shm");
  if (dir == nullptr) return 0;

  size_t removed = 0;
  while (const dirent *entry = ::readdir(dir)) {
    const std::string_view name(entry->d_name);
    if (!name.starts_with("lava-arena-")) continue;
    // The name is the shm object's, with the leading slash every other call
    // here uses.
    if (claimStale("/" + std::string(name), /*announce=*/false)) ++removed;
  }
  ::closedir(dir);

  if (removed != 0) {
    std::cerr << "DrawArena: reclaimed " << removed
              << " arena(s) from processes that are gone\n";
  }
  return removed;
#else
  // Nowhere to look: /dev/shm is Linux's, and POSIX gives no way to enumerate
  // shared memory objects.
  return 0;
#endif
}

bool DrawArena::create(const std::string &id, ArenaCapacity capacity)
{
  if (impl_->current.base) return false;
  if (!capacityInRange(capacity)) {
    std::cerr << "DrawArena: capacity above the per-array limit\n";
    return false;
  }

  // Every producer clears up after the ones that died before it. Here rather
  // than once at compositor startup because the arenas that accumulate are
  // mostly launcher invocations — dozens within a single session, each one a
  // process that ends by calling exit() and so destroys nothing. A sweep per
  // producer keeps the count near zero instead of near a session's worth.
  //
  // Not in mapNew, which also runs for every growth generation: this belongs
  // to starting up, not to allocating.
  reapStale();
  Impl::Mapping m;
  if (!impl_->mapNew(shmName(id, 0), capacity, 0, m)) return false;
  impl_->id         = id;
  impl_->isProducer = true;
  impl_->current    = m;
  return true;
}

bool DrawArena::open(const std::string &id)
{
  if (impl_->current.base) return false;
  Impl::Mapping m;
  if (!impl_->mapExisting(shmName(id, 0), m)) return false;
  impl_->id         = id;
  impl_->isProducer = false;
  impl_->current    = m;
  // The producer may already have grown past generation 0; follow the chain
  // so a consumer that starts late does not read a superseded arena.
  for (;;) {
    const uint32_t next =
      impl_->current.header()->supersededBy.load(std::memory_order_acquire);
    if (next == 0) break;
    Impl::Mapping newer;
    if (!impl_->mapExisting(shmName(id, next), newer)) break;
    impl_->current.header()->consumerLeft.store(1, std::memory_order_release);
    impl_->unmapAndUnlink(impl_->current);
    impl_->current = newer;
  }
  return true;
}

ArenaFrame DrawArena::beginFrame()
{
  ArenaFrame frame;
  if (!impl_->isProducer || !impl_->current.base) return frame;
  impl_->reclaimRetired();

  auto *h = impl_->current.header();
  const uint32_t held = h->acquiredSlot.load(std::memory_order_acquire);
  // Three slots, at most two of them spoken for: whatever the consumer holds
  // and whatever was published last. So a free slot always exists and the
  // producer never has to wait for the renderer.
  uint32_t slot = kNoSlot;
  for (uint32_t i = 0; i < kSlots; ++i) {
    if (i == held || i == impl_->lastPublished) continue;
    slot = i;
    break;
  }
  if (slot == kNoSlot) return frame;  // unreachable with kSlots >= 3

  frame.slot     = slot;
  frame.capacity = impl_->capacityOf(impl_->current);
  impl_->slotPointers(impl_->current, slot, frame.commands, frame.glyphs,
                      frame.meshVertices, frame.spatialVertices,
                      frame.gradients);
  frame.valid = true;
  return frame;
}

bool DrawArena::growFrame(ArenaFrame &frame, ArenaCapacity atLeast,
                          ArenaCapacity written)
{
  if (!impl_->isProducer || !frame.valid) return false;
  if (!written.fitsIn(frame.capacity)) return false;

  // Double every array that has to grow, then take the element-wise max with
  // what was asked for. A frame that discovers it needs one more command at a
  // time therefore creates a handful of generations over its lifetime, not
  // one per command.
  ArenaCapacity next = frame.capacity;
  next.commands        = std::max(next.commands * 2, 256u);
  next.glyphs          = std::max(next.glyphs * 2, 2048u);
  next.meshVertices    = std::max(next.meshVertices * 2, 256u);
  next.spatialVertices = std::max(next.spatialVertices * 2, 256u);
  next.gradients       = std::max(next.gradients * 2, 64u);
  next = next.unionWith(atLeast);
  if (!capacityInRange(next)) {
    std::cerr << "DrawArena: frame needs more than the per-array limit\n";
    return false;
  }

  const uint32_t generation = impl_->current.generation + 1;
  Impl::Mapping newer;
  if (!impl_->mapNew(shmName(impl_->id, generation), next, generation, newer)) {
    return false;
  }

  // Carry the partial frame across into the same slot index, so the caller's
  // element indices — which are already baked into commands it has written —
  // stay correct.
  DrawCommand   *cmds    = nullptr;
  GlyphInstance *glyphs  = nullptr;
  MeshVertex    *mesh    = nullptr;
  SpatialVertex *spatial = nullptr;
  GradientDesc  *grads   = nullptr;
  impl_->slotPointers(newer, frame.slot, cmds, glyphs, mesh, spatial, grads);
  std::memcpy(cmds, frame.commands, static_cast<size_t>(written.commands) * sizeof(DrawCommand));
  std::memcpy(glyphs, frame.glyphs, static_cast<size_t>(written.glyphs) * sizeof(GlyphInstance));
  std::memcpy(mesh, frame.meshVertices, static_cast<size_t>(written.meshVertices) * sizeof(MeshVertex));
  std::memcpy(spatial, frame.spatialVertices, static_cast<size_t>(written.spatialVertices) * sizeof(SpatialVertex));
  std::memcpy(grads, frame.gradients, static_cast<size_t>(written.gradients) * sizeof(GradientDesc));

  // The consumer may be mid-frame in the old generation, so the old mapping
  // has to stay alive and readable. It learns about the move from the old
  // header and tells us when it has left.
  impl_->current.pinned = impl_->current.generation == 0;
  impl_->retired.push_back(impl_->current);
  impl_->republishGeneration(generation);
  impl_->current = newer;
  // Nothing is published in the new generation yet, so no slot is off limits
  // for the reason the old one's was.
  impl_->lastPublished = kNoSlot;

  frame.capacity        = next;
  frame.commands        = cmds;
  frame.glyphs          = glyphs;
  frame.meshVertices    = mesh;
  frame.spatialVertices = spatial;
  frame.gradients       = grads;
  return true;
}

void DrawArena::commitFrame(const ArenaFrame &frame, ArenaCapacity written)
{
  if (!impl_->isProducer || !frame.valid || !impl_->current.base) return;
  auto *h = impl_->current.header();
  if (frame.slot >= kSlots) return;

  // Clamp rather than reject: a producer that miscounts should draw less than
  // it meant to, not scribble past the slot.
  const ArenaCapacity cap = impl_->capacityOf(impl_->current);
  h->counts[frame.slot][0] = std::min(written.commands, cap.commands);
  h->counts[frame.slot][1] = std::min(written.glyphs, cap.glyphs);
  h->counts[frame.slot][2] = std::min(written.meshVertices, cap.meshVertices);
  h->counts[frame.slot][3] = std::min(written.spatialVertices, cap.spatialVertices);
  h->counts[frame.slot][4] = std::min(written.gradients, cap.gradients);

  // Release: everything above — the payload and the counts — is visible to a
  // consumer that acquires this value.
  h->published.store(packPublished(impl_->nextSequence, frame.slot),
                     std::memory_order_release);
  ++impl_->nextSequence;
  impl_->lastPublished = frame.slot;
}

bool DrawArena::acquireFrame(canvas::DrawList &out)
{
  if (impl_->isProducer || !impl_->current.base) return false;

  // Follow a growth before looking for a frame: the producer publishes into
  // the new generation, so staying here would see nothing new forever.
  for (;;) {
    const uint32_t next =
      impl_->current.header()->supersededBy.load(std::memory_order_acquire);
    if (next == 0) break;
    Impl::Mapping newer;
    if (!impl_->mapExisting(shmName(impl_->id, next), newer)) break;
    impl_->current.header()->consumerLeft.store(1, std::memory_order_release);
    // Kept mapped, not unmapped here. The caller is holding the `DrawList`
    // this generation's last frame was acquired into, and is entitled to draw
    // it again — a resize repaints without waiting for a publish. The producer
    // grows *mid-frame*, so the usual state right after a growth is a new
    // generation with nothing published in it yet, and the `return false`
    // below would then leave the caller rendering out of a mapping this loop
    // had already dropped. Unmapping happens once there are new pointers to
    // hand over instead.
    //
    // `consumerLeft` above is still correct and still early: it lets the
    // producer unlink and unmap its side, which does not disturb ours.
    impl_->heldSlot = kNoSlot;  // that slot belongs to a generation the producer has left
    impl_->leftBehind.push_back(impl_->current);
    impl_->current = newer;
    // Sequence numbers continue across generations, so nothing resets here.
  }

  auto *h = impl_->current.header();
  const uint64_t published = h->published.load(std::memory_order_acquire);
  const uint64_t seq       = publishedSeq(published);
  if (seq == 0 || seq == impl_->lastSeenSequence) return false;

  const uint32_t slot = publishedSlot(published);
  if (slot >= kSlots) return false;

  // Claiming the new slot releases the previous one in the same store, so a
  // consumer holding a frame never briefly holds none. That matters because
  // the renderer keeps the last acquired frame mapped between publishes: a
  // window resize has to repaint, and the producer may have nothing new to
  // say about it.
  h->acquiredSlot.store(slot, std::memory_order_release);
  impl_->heldSlot         = slot;
  impl_->lastSeenSequence = seq;

  const ArenaCapacity cap = impl_->capacityOf(impl_->current);
  const uint32_t commands = std::min(h->counts[slot][0], cap.commands);
  const uint32_t glyphs   = std::min(h->counts[slot][1], cap.glyphs);
  const uint32_t mesh     = std::min(h->counts[slot][2], cap.meshVertices);
  const uint32_t spatial  = std::min(h->counts[slot][3], cap.spatialVertices);
  const uint32_t grads    = std::min(h->counts[slot][4], cap.gradients);

  const DrawCommand   *cmdPtr     = nullptr;
  const GlyphInstance *glyphPtr   = nullptr;
  const MeshVertex    *meshPtr    = nullptr;
  const SpatialVertex *spatialPtr = nullptr;
  const GradientDesc  *gradPtr    = nullptr;
  impl_->slotPointers(impl_->current, slot, cmdPtr, glyphPtr, meshPtr, spatialPtr,
                      gradPtr);

  out.commands           = cmdPtr;
  out.commandCount       = commands;
  out.glyphs             = glyphPtr;
  out.glyphCount         = glyphs;
  out.meshVertices       = meshPtr;
  out.meshVertexCount    = mesh;
  out.spatialVertices    = spatialPtr;
  out.spatialVertexCount = spatial;
  out.gradients          = gradPtr;
  out.gradientCount      = grads;
  // `out` no longer points into any generation we moved off, so those can go.
  impl_->dropLeftBehind();
  return true;
}

void DrawArena::releaseFrame() { impl_->releaseHeld(); }

bool DrawArena::isOpen() const { return impl_->current.base != nullptr; }

uint32_t DrawArena::generation() const { return impl_->current.generation; }

ArenaCapacity DrawArena::capacity() const
{
  if (!impl_->current.base) return {};
  return impl_->capacityOf(impl_->current);
}

const std::string &DrawArena::id() const { return impl_->id; }

size_t DrawArena::mappedBytes() const { return impl_->current.size; }

} // namespace canvas::ipc
