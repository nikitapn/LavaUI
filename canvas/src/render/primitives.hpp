#pragma once

#include "render/mesh2d.hpp"
#include "render/mesh3d.hpp"

class Vulkan;

struct Primitives {
  static Mesh2D generateCircle(int numberOfSegments);
  static Mesh2D generateRectangle();
  static Mesh2D generateRoundedRectangle(int cornerSegments = 8);
  static Mesh3D* generateCube(Vulkan& vulkan);
  static Mesh3D* generateSphere(Vulkan& vulkan, int latitudeSegments = 18, int longitudeSegments = 36);
};
