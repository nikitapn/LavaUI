#pragma once

#include <GLFW/glfw3.h>

// glfwGetPlatform() and GLFW_PLATFORM_* landed in 3.4. Ubuntu 24.04 ships
// 3.3, X11-only. One helper so both call sites agree on the fallback.
#if GLFW_VERSION_MAJOR > 3 || (GLFW_VERSION_MAJOR == 3 && GLFW_VERSION_MINOR >= 4)

inline int canvasGlfwPlatform() { return glfwGetPlatform(); }

#else

#ifndef GLFW_PLATFORM_WIN32
#define GLFW_PLATFORM_WIN32 0x00060001
#endif
#ifndef GLFW_PLATFORM_WAYLAND
#define GLFW_PLATFORM_WAYLAND 0x00060003
#endif
#ifndef GLFW_PLATFORM_X11
#define GLFW_PLATFORM_X11 0x00060004
#endif

inline int canvasGlfwPlatform()
{
#if defined(_WIN32)
  return GLFW_PLATFORM_WIN32;
#elif defined(CANVAS_HAVE_X11)
  return GLFW_PLATFORM_X11;
#else
  return 0;
#endif
}

#endif
