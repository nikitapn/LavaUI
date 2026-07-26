#pragma once

#include <vector>

#include "util/types.hpp"

struct Mesh2D {
  std::vector<vec2> vertices;
  std::vector<vec2> texCoords;
  std::vector<u16>  indices;
};
