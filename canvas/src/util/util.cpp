#include <cctype>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <filesystem>
#include <string_view>

#include "util/util.hpp"

namespace utils {

bool envFlag(const char *name, bool defaultValue)
{
  const char *raw = std::getenv(name);
  if (raw == nullptr || raw[0] == '\0') return defaultValue;

  // Strip leading/trailing whitespace without allocating.
  while (*raw != '\0' && std::isspace(static_cast<unsigned char>(*raw)))
    ++raw;
  if (*raw == '\0') return defaultValue;

  char buf[16]{};
  size_t n = 0;
  for (const char *p = raw; *p != '\0' && n + 1 < sizeof(buf); ++p) {
    if (std::isspace(static_cast<unsigned char>(*p))) break;
    buf[n++] = static_cast<char>(std::tolower(static_cast<unsigned char>(*p)));
  }
  buf[n] = '\0';
  const std::string_view v{buf, n};

  if (v == "0" || v == "false" || v == "no" || v == "off") return false;
  if (v == "1" || v == "true" || v == "yes" || v == "on") return true;

  // Any other non-empty value: treat as on (e.g. CANVAS_VK_VALIDATION=layers).
  return true;
}

std::vector<char> readFile(const std::filesystem::path& filepath) {
  std::ifstream file(filepath, std::ios::binary);
  if (!file.is_open()) {
    throw std::runtime_error("Failed to open file: " + filepath.string());
  }
  std::vector<char> result;
  std::copy(std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>(), std::back_inserter(result));
  return result;
}

void alignedFree(void* data)
{
#if	defined(_MSC_VER) || defined(__MINGW32__)
	_aligned_free(data);
#else
	free(data);
#endif
}

namespace utf8 { namespace detail {
// UTF-8 decoder based on Bjoern Hoehrmann's DFA approach
// See https://bjoern.hoehrmann.de/utf-8/decoder/dfa/
unsigned char utf8d[] = {
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, // 00..1f
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, // 20..3f
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, // 40..5f
  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, // 60..7f
  1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9, // 80..9f
  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7, // a0..bf
  8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2, // c0..df
  0xa,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x3,0x4,0x3,0x3, // e0..ef
  0xb,0x6,0x6,0x6,0x5,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8,0x8, // f0..ff
  0x0,0x1,0x2,0x3,0x5,0x8,0x7,0x1,0x1,0x1,0x4,0x6,0x1,0x1,0x1,0x1, // s0..s0
  1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,1,1,1,1,1,0,1,0,1,1,1,1,1,1, // s1..s2
  1,2,1,1,1,1,1,2,1,2,1,1,1,1,1,1,1,1,1,1,1,1,1,2,1,1,1,1,1,1,1,1, // s3..s4
  1,2,1,1,1,1,1,1,1,2,1,1,1,1,1,1,1,1,1,1,1,1,1,3,1,3,1,1,1,1,1,1, // s5..s6
  1,3,1,1,1,1,1,3,1,3,1,1,1,1,1,1,1,3,1,1,1,1,1,1,1,1,1,1,1,1,1,1, // s7..s8
};
} // namespace detail
} // namespace utf8
} // namespace utils
