#pragma once

#include <string>

namespace canvas {

struct TreeItem {
  std::string id;
  std::string label;
  int depth = 0;
  bool selected = false;
};

struct PropertyItem {
  std::string key;
  std::string value;
};

} // namespace canvas
