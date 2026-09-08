#include "png_file.hpp"

#include <fcntl.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>

namespace lava {

bool writeTempPng(const std::vector<uint8_t> &png, std::string &outPath) {
  if (png.empty()) return false;
  // `TMPDIR` if the session set one, so a machine that puts temporary files on
  // a real disk is obeyed rather than filling a tmpfs with screenshots.
  const char *dir = std::getenv("TMPDIR");
  std::string tmpl = (dir != nullptr && *dir != '\0' ? std::string(dir) : "/tmp");
  if (tmpl.back() == '/') tmpl.pop_back();
  tmpl += "/lava-shot-XXXXXX.png";

  std::vector<char> path(tmpl.begin(), tmpl.end());
  path.push_back('\0');
  const int fd = ::mkstemps(path.data(), 4);
  if (fd < 0) return false;

  const uint8_t *p = png.data();
  size_t left = png.size();
  while (left > 0) {
    const ssize_t n = ::write(fd, p, left);
    if (n < 0) {
      ::close(fd);
      ::unlink(path.data());
      return false;
    }
    p += static_cast<size_t>(n);
    left -= static_cast<size_t>(n);
  }
  ::close(fd);
  outPath = path.data();
  return true;
}

bool readFileBytes(const std::string &path, std::vector<uint8_t> &out) {
  std::FILE *file = std::fopen(path.c_str(), "rb");
  if (file == nullptr) return false;
  out.clear();
  uint8_t chunk[64 * 1024];
  for (;;) {
    const size_t got = std::fread(chunk, 1, sizeof(chunk), file);
    if (got == 0) break;
    out.insert(out.end(), chunk, chunk + got);
  }
  const bool ok = std::ferror(file) == 0;
  std::fclose(file);
  if (!ok) out.clear();
  return ok && !out.empty();
}

}  // namespace lava
