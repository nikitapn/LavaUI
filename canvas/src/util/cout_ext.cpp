#include "cout_ext.hpp"

#ifdef _WIN32
# ifndef NOMINMAX
#  define NOMINMAX
# endif
# ifndef WIN32_LEAN_AND_MEAN
#  define WIN32_LEAN_AND_MEAN
# endif
# include <Windows.h>
# include <wincon.h>
#endif

#ifdef _WIN32
thread_local static WORD old_color_attrs = -1;
#elif __unix__
static const char* getAnsiColorCode(
  const clr::color& clr)
{
  switch (clr) {
    case clr::reset:
      return nullptr;
    case clr::red:
      return "1";
    case clr::green:
      return "2";
    case clr::yellow:
      return "3";
    case clr::blue:
      return "4";
    case clr::magenta:
      return "5";
    case clr::cyan:
      return "6";
    case clr::white:
      return "7";
    default:
      return nullptr;
  }
}
#endif

std::ostream& operator<<(std::ostream& _Ostr, const clr::color& color)
{
#ifdef _WIN32
  if (old_color_attrs == static_cast<WORD>(-1)) {
    // Store the current text color
    CONSOLE_SCREEN_BUFFER_INFO buffer_info;
    GetConsoleScreenBufferInfo(GetStdHandle(STD_OUTPUT_HANDLE), &buffer_info);
    old_color_attrs = buffer_info.wAttributes;
  }
#endif
  if (color == clr::color::reset) {
#ifdef _WIN32
    _Ostr.flush();
    // Restores the text color.
    SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE),
                            old_color_attrs);
#elif __unix__
    _Ostr << "\033[m";  // Resets the terminal to default
#endif
  } else {
#ifdef _WIN32
    _Ostr.flush();
    SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE),
                            static_cast<WORD>(color));
#elif __unix__
    _Ostr << "\033[0;3" << getAnsiColorCode(color) << "m";
#endif
  }
  return _Ostr;
}
