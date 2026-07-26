/*********************************************************************************
 * "colored cout" is free and unencumbered software released into the public
 *domain.
 *
 * Anyone is free to copy, modify, publish, use, compile, sell, or
 * distribute this software, either in source code form or as a compiled
 * binary, for any purpose, commercial or non-commercial, and by any
 * means.
 *
 * In jurisdictions that recognize copyright laws, the author or authors
 * of this software dedicate any and all copyright interest in the
 * software to the public domain. We make this dedication for the benefit
 * of the public at large and to the detriment of our heirs and
 * successors. We intend this dedication to be an overt act of
 * relinquishment in perpetuity of all present and future rights to this
 * software under copyright law.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
 * OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
 * ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
 * OTHER DEALINGS IN THE SOFTWARE.
 *
 * For more information, please refer to:
 * - http://unlicense.org/
 * - https://github.com/yurablok/colored-cout
 ********************************************************************************/
#pragma once

#include <ostream>

namespace clr {

#ifdef _WIN32
namespace internal {
constexpr int WIN__FOREGROUND_BLUE      = 0x0001;
constexpr int WIN__FOREGROUND_GREEN     = 0x0002;
constexpr int WIN__FOREGROUND_RED       = 0x0004;
constexpr int WIN__FOREGROUND_INTENSITY = 0x0008;
}  // namespace internal
enum color {
  reset = 0,
  blue  = internal::WIN__FOREGROUND_BLUE | internal::WIN__FOREGROUND_INTENSITY,
  green = internal::WIN__FOREGROUND_GREEN | internal::WIN__FOREGROUND_INTENSITY,
  cyan  = internal::WIN__FOREGROUND_BLUE | internal::WIN__FOREGROUND_GREEN |
         internal::WIN__FOREGROUND_INTENSITY,
  red     = internal::WIN__FOREGROUND_RED | internal::WIN__FOREGROUND_INTENSITY,
  magenta = internal::WIN__FOREGROUND_BLUE | internal::WIN__FOREGROUND_RED |
            internal::WIN__FOREGROUND_INTENSITY,
  yellow = internal::WIN__FOREGROUND_GREEN | internal::WIN__FOREGROUND_RED |
           internal::WIN__FOREGROUND_INTENSITY,
  white = internal::WIN__FOREGROUND_BLUE | internal::WIN__FOREGROUND_GREEN |
          internal::WIN__FOREGROUND_RED | internal::WIN__FOREGROUND_INTENSITY
};
#elif __unix__
enum color { reset, red, green, yellow, blue, magenta, cyan, white };
#endif
}  // namespace clr

std::ostream& operator<<(std::ostream& _Ostr, const clr::color& color);
