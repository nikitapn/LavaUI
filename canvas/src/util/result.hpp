#pragma once

#include <expected>
#include <string>
#include <utility>

// Error style for the canvas engine / C bridge boundary.
// Prefer returning Result/VoidResult over throwing across API layers — the C
// bridge and Swift cannot usefully catch C++ exceptions, so every throw just
// becomes more try/catch noise. Deep Vulkan helpers may still throw for now
// (VR macro); Application::init* converts those into unexpected values.

namespace canvas {

using Error = std::string;

template <typename T>
using Result = std::expected<T, Error>;

using VoidResult = std::expected<void, Error>;

inline VoidResult ok() { return {}; }

inline std::unexpected<Error> fail(std::string message) {
  return std::unexpected<Error>(std::move(message));
}

template <typename T>
inline std::unexpected<Error> fail(std::string message) {
  return std::unexpected<Error>(std::move(message));
}

} // namespace canvas
