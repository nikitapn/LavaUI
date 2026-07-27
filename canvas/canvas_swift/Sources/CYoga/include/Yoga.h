#pragma once

// Shim so the vendored source (canvas/third-party/yoga, symlinked in as
// ../yoga) stays the single source of truth instead of being duplicated
// here. <yoga/...> resolves via the headerSearchPath(".") on this target
// (see Package.swift) pointing at Sources/CYoga itself, where the `yoga`
// symlink lives.
#include <yoga/Yoga.h>
