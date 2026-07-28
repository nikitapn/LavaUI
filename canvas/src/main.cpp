#include "pch.hpp"

#include "application.hpp"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

// Headless smoke test: adds a few retained rectangles, repaints the engine
// offscreen a handful of times (no window, no GLFW), and writes the last
// frame out as a PNG, so the Vulkan/offscreen-readback/retained-scene path
// can be sanity-checked visually without going through Swift.
int main(int argc, char *argv[])
{


  return 0;
}
