#pragma once

// Input state (Application::Impl::InputState) and processContinuousInput()
// are indexed by these key/button/action codes. They intentionally match
// GLFW's numbering (see <GLFW/glfw3.h>) so a future input bridge (fed from
// outside this engine, e.g. from Swift/Gtk) can keep using the same
// convention without this engine depending on GLFW itself.

constexpr int KEY_SPACE        = 32;
constexpr int KEY_1            = 49;
constexpr int KEY_2            = 50;
constexpr int KEY_3            = 51;
constexpr int KEY_4            = 52;
constexpr int KEY_5            = 53;
constexpr int KEY_A            = 65;
constexpr int KEY_D            = 68;
constexpr int KEY_E            = 69;
constexpr int KEY_Q            = 81;
constexpr int KEY_S            = 83;
constexpr int KEY_V            = 86;
constexpr int KEY_W            = 87;
constexpr int KEY_ESCAPE       = 256;
constexpr int KEY_TAB          = 258;
constexpr int KEY_RIGHT        = 262;
constexpr int KEY_LEFT         = 263;
constexpr int KEY_DOWN         = 264;
constexpr int KEY_UP           = 265;
constexpr int KEY_LEFT_SHIFT   = 340;
constexpr int KEY_LEFT_CONTROL = 341;
constexpr int KEY_LEFT_ALT     = 342;
constexpr int KEY_MENU         = 348;
constexpr int KEY_LAST         = KEY_MENU;

constexpr int MOUSE_BUTTON_1    = 0;
constexpr int MOUSE_BUTTON_LAST = 7;

constexpr int ACTION_RELEASE = 0;
constexpr int ACTION_PRESS   = 1;
constexpr int ACTION_REPEAT  = 2;
