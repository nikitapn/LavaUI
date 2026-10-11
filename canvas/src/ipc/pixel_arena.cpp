#include "ipc/pixel_arena.hpp"

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <iostream>
#include <utility>

namespace canvas::ipc {

uint64_t pixelSpan(const PixelLayout &layout)
{
  if (layout.height == 0) return 0;
  return uint64_t(layout.stride) * (layout.height - 1) + uint64_t(layout.width) * 4;
}

const char *checkPixelLayout(const PixelLayout &layout, uint64_t arenaBytes)
{
  if (layout.width == 0 || layout.height == 0) return "a side is zero";
  if (layout.width > kMaxPixelSide || layout.height > kMaxPixelSide)
    return "a side is longer than 16384";
  if (uint64_t(layout.stride) < uint64_t(layout.width) * 4)
    return "stride is shorter than a row";
  // A stride is a row plus padding, and the read buffer is a stride per row,
  // so an unbounded one would let a sparse arena ask for gigabytes here.
  if (layout.stride > kMaxPixelSide * 4) return "stride is longer than a row can be";
  if (static_cast<uint32_t>(layout.format) > static_cast<uint32_t>(PixelFormat::Bgrx8))
    return "unknown pixel format";
  // Both terms are under 2^32 * 2^14 and 2^64 / 2, so neither the span nor
  // the sum can wrap.
  if (layout.offset > arenaBytes || pixelSpan(layout) > arenaBytes - layout.offset)
    return "region runs past the end of the arena";
  return nullptr;
}

void packRgba(const uint8_t *src, const PixelLayout &layout, uint8_t *dst)
{
  const size_t row = size_t(layout.width) * 4;
  const bool swap = layout.format == PixelFormat::Bgra8 ||
                    layout.format == PixelFormat::Bgrx8;
  const bool opaque = layout.format == PixelFormat::Rgbx8 ||
                      layout.format == PixelFormat::Bgrx8;
  for (uint32_t y = 0; y < layout.height; ++y) {
    const uint8_t *from = src + size_t(y) * layout.stride;
    uint8_t *to = dst + size_t(y) * row;
    // memmove, not memcpy: in place, row 0 is the same bytes and later rows
    // overlap the tail of their own source.
    if (to != from) std::memmove(to, from, row);
    if (!swap && !opaque) continue;
    for (size_t i = 0; i < row; i += 4) {
      if (swap) std::swap(to[i], to[i + 2]);
      if (opaque) to[i + 3] = 0xff;
    }
  }
}

// ─── Producer ────────────────────────────────────────────────────────────────

struct PixelArena::Impl {
  std::string name;
  int fd = -1;
  uint8_t *base = nullptr;
  size_t bytes = 0;
  bool linked = false;

  ~Impl()
  {
    if (base != nullptr) ::munmap(base, bytes);
    if (fd >= 0) ::close(fd);
    if (linked) ::shm_unlink(name.c_str());
  }
};

PixelArena::PixelArena() : impl_(std::make_unique<Impl>()) {}
PixelArena::~PixelArena() = default;
PixelArena::PixelArena(PixelArena &&) noexcept = default;
PixelArena &PixelArena::operator=(PixelArena &&) noexcept = default;

bool PixelArena::create(const std::string &id, size_t bytes)
{
  if (!impl_) impl_ = std::make_unique<Impl>();
  if (impl_->base != nullptr || bytes == 0) return false;
  Impl &m = *impl_;
  m.name = std::string(kPixelArenaPrefix) + id;
  m.fd = ::shm_open(m.name.c_str(), O_CREAT | O_EXCL | O_RDWR, 0600);
  if (m.fd < 0) {
    std::cerr << "PixelArena: shm_open " << m.name << ": " << std::strerror(errno)
              << "\n";
    return false;
  }
  m.linked = true;
  if (::ftruncate(m.fd, static_cast<off_t>(bytes)) != 0) {
    std::cerr << "PixelArena: ftruncate " << m.name << ": " << std::strerror(errno)
              << "\n";
    impl_ = std::make_unique<Impl>();  // closes and unlinks
    return false;
  }
  void *base = ::mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, m.fd, 0);
  if (base == MAP_FAILED) {
    std::cerr << "PixelArena: mmap " << m.name << ": " << std::strerror(errno) << "\n";
    impl_ = std::make_unique<Impl>();
    return false;
  }
  m.base = static_cast<uint8_t *>(base);
  m.bytes = bytes;
  return true;
}

bool PixelArena::write(uint64_t offset, const uint8_t *src, size_t count)
{
  if (!impl_ || impl_->base == nullptr) return false;
  if (offset > impl_->bytes || count > impl_->bytes - offset) return false;
  if (count != 0) std::memcpy(impl_->base + offset, src, count);
  return true;
}

void PixelArena::unlinkName()
{
  if (!impl_ || !impl_->linked) return;
  ::shm_unlink(impl_->name.c_str());
  impl_->linked = false;
}

bool PixelArena::isOpen() const { return impl_ && impl_->base != nullptr; }

std::string PixelArena::name() const { return impl_ ? impl_->name : std::string(); }

size_t PixelArena::size() const { return impl_ ? impl_->bytes : 0; }

// ─── Consumer ────────────────────────────────────────────────────────────────

PixelArenaReader::~PixelArenaReader()
{
  if (fd_ >= 0) ::close(fd_);
}

PixelArenaReader::PixelArenaReader(PixelArenaReader &&other) noexcept
    : fd_(std::exchange(other.fd_, -1))
{
}

PixelArenaReader &PixelArenaReader::operator=(PixelArenaReader &&other) noexcept
{
  if (this != &other) {
    if (fd_ >= 0) ::close(fd_);
    fd_ = std::exchange(other.fd_, -1);
  }
  return *this;
}

bool PixelArenaReader::open(const std::string &name)
{
  // The prefix, and nothing after it that `shm_open` would read as a path.
  const size_t prefix = std::strlen(kPixelArenaPrefix);
  if (name.size() <= prefix || name.compare(0, prefix, kPixelArenaPrefix) != 0 ||
      name.find('/', prefix) != std::string::npos)
    return false;
  const int fd = ::shm_open(name.c_str(), O_RDONLY | O_CLOEXEC, 0);
  if (fd < 0) return false;
  struct stat st {};
  if (::fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
    ::close(fd);
    return false;
  }
  if (fd_ >= 0) ::close(fd_);
  fd_ = fd;
  return true;
}

const char *PixelArenaReader::read(const PixelLayout &layout,
                                   std::vector<uint8_t> &out) const
{
  if (fd_ < 0) return "arena is not open";
  struct stat st {};
  if (::fstat(fd_, &st) != 0) return "arena cannot be read";
  if (const char *why = checkPixelLayout(layout, static_cast<uint64_t>(st.st_size)))
    return why;

  const uint64_t span = pixelSpan(layout);
  out.resize(span);
  uint64_t done = 0;
  while (done < span) {
    const ssize_t got = ::pread(fd_, out.data() + done, span - done,
                                static_cast<off_t>(layout.offset + done));
    if (got < 0 && errno == EINTR) continue;
    // Zero is the end of the file: shrunk since the `fstat` above.
    if (got <= 0) return "region runs past the end of the arena";
    done += static_cast<uint64_t>(got);
  }
  packRgba(out.data(), layout, out.data());
  out.resize(size_t(layout.width) * layout.height * 4);
  return nullptr;
}

} // namespace canvas::ipc
