#include "window/window_platform.hpp"

#include <iostream>

#define GLFW_INCLUDE_NONE
#include <GLFW/glfw3.h>

// ─── X11: skip taskbar / pager, utility window type ─────────────────────────
#if defined(CANVAS_HAVE_X11)
#define GLFW_EXPOSE_NATIVE_X11
#include <GLFW/glfw3native.h>
#include <X11/Xlib.h>
#include <X11/Xatom.h>

static void applyX11ToolWindowHints(GLFWwindow *window)
{
  Display *display = glfwGetX11Display();
  Window xw = glfwGetX11Window(window);
  if (!display || !xw) return;

  Atom wmState = XInternAtom(display, "_NET_WM_STATE", False);
  Atom skipTaskbar = XInternAtom(display, "_NET_WM_STATE_SKIP_TASKBAR", False);
  Atom skipPager = XInternAtom(display, "_NET_WM_STATE_SKIP_PAGER", False);
  Atom wmWindowType = XInternAtom(display, "_NET_WM_WINDOW_TYPE", False);
  // UTILITY is the usual “palette / tool” type; many docks omit these.
  Atom typeUtility = XInternAtom(display, "_NET_WM_WINDOW_TYPE_UTILITY", False);

  // Set type before (or right as) the window is managed.
  XChangeProperty(
    display, xw, wmWindowType, XA_ATOM, 32, PropModeReplace,
    reinterpret_cast<unsigned char *>(&typeUtility), 1);

  Atom states[] = {skipTaskbar, skipPager};
  XChangeProperty(
    display, xw, wmState, XA_ATOM, 32, PropModeReplace,
    reinterpret_cast<unsigned char *>(states), 2);

  // Also send a client message so already-mapped windows update on WMs
  // that only listen for _NET_WM_STATE changes this way.
  auto sendState = [&](Atom a1, Atom a2) {
    XClientMessageEvent ev {};
    ev.type = ClientMessage;
    ev.window = xw;
    ev.message_type = wmState;
    ev.format = 32;
    ev.data.l[0] = 1; // _NET_WM_STATE_ADD
    ev.data.l[1] = static_cast<long>(a1);
    ev.data.l[2] = static_cast<long>(a2);
    ev.data.l[3] = 1; // application
    XSendEvent(
      display, DefaultRootWindow(display), False,
      SubstructureRedirectMask | SubstructureNotifyMask,
      reinterpret_cast<XEvent *>(&ev));
  };
  sendState(skipTaskbar, skipPager);
  XFlush(display);
}
#endif

// ─── Win32: WS_EX_TOOLWINDOW (no taskbar button) ────────────────────────────
#if defined(_WIN32)
#define GLFW_EXPOSE_NATIVE_WIN32
#include <GLFW/glfw3native.h>
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

static void applyWin32ToolWindowHints(GLFWwindow *window)
{
  HWND hwnd = glfwGetWin32Window(window);
  if (!hwnd) return;
  LONG_PTR ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  ex |= WS_EX_TOOLWINDOW;
  ex &= ~WS_EX_APPWINDOW;
  SetWindowLongPtr(hwnd, GWL_EXSTYLE, ex);
  // Force frame refresh so the style sticks.
  SetWindowPos(
    hwnd, nullptr, 0, 0, 0, 0,
    SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
}
#endif

void canvasApplyToolWindowHints(GLFWwindow *window)
{
  if (!window) return;

  const int platform = glfwGetPlatform();

#if defined(CANVAS_HAVE_X11)
  if (platform == GLFW_PLATFORM_X11) {
    applyX11ToolWindowHints(window);
    return;
  }
#endif

#if defined(_WIN32)
  if (platform == GLFW_PLATFORM_WIN32) {
    applyWin32ToolWindowHints(window);
    return;
  }
#endif

  if (platform == GLFW_PLATFORM_WAYLAND) {
    // Wayland has no portable “skip taskbar” request. The window may still
    // appear in the overview/dock as its own surface. Grouping under the
    // host app_id is the best we can do (set at create time via
    // GLFW_WAYLAND_APP_ID). Log once so this isn't mysterious.
    static bool warned = false;
    if (!warned) {
      warned = true;
      std::cerr
        << "canvas: Wayland cannot hide a surface from the dock/overview; "
           "X11 skip-taskbar hints do not apply.\n";
    }
  }
}
