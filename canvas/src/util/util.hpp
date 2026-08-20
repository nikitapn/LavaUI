#pragma once

#include <vector>
#include <iostream>
#include <filesystem>

#include "util/types.hpp"

namespace utils {

std::vector<char> readFile(const std::filesystem::path& filepath);
void*             alignedAlloc(size_t size, size_t alignment);
void              alignedFree(void* data);

/// Portable env flag via `std::getenv`
/// Unset / empty → `defaultValue`.
/// Truthy: 1, true, yes, on (case-insensitive).
/// Falsy:  0, false, no, off.
bool envFlag(const char *name, bool defaultValue = false);

namespace utf8 { namespace detail {
extern unsigned char utf8d[];
constexpr u32        UTF8_REJECT = 1;
constexpr u32        UTF8_ACCEPT = 0;

// UTF-8 decoder based on Bjoern Hoehrmann's DFA approach
// See https://bjoern.hoehrmann.de/utf-8/decoder/dfa/
u32 inline decode(
  u32* state, u32* codep, u32 byte)
{
  u32 type = utf8d[byte];

  *codep = (*state != UTF8_ACCEPT) ? (byte & 0x3fu) | (*codep << 6)
                                   : (0xff >> type) & (byte);

  *state = utf8d[256 + *state * 16 + type];
  return *state;
}

} // namespace detail

template <class Fn>
inline void read(
  std::string_view str, Fn&& fn)
{
  u32 codepoint;
  u32 state = 0;

  for (size_t i = 0; i < str.length(); ++i)
    if (!detail::decode(&state, &codepoint, static_cast<std::uint8_t>(str[i])))
      fn(codepoint);

  if (state != detail::UTF8_ACCEPT)
    std::cerr << "The string is ill-formed\n";
}

}}  // namespace utils::utf8
