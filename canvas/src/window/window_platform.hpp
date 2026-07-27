#pragma once

struct GLFWwindow;

/// Platform-specific “this is a tool surface, not a primary app window”
/// hints: skip taskbar/pager on X11, tool-window style on Win32, etc.
/// Call after glfwCreateWindow (and preferably before the first map/show).
void canvasApplyToolWindowHints(GLFWwindow *window);
