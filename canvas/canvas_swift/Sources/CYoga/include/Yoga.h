#pragma once

// Shim so the vendored source stays the single source of truth instead of
// being duplicated here. <yoga/...> resolves through the adjacent `yoga`
// symlink and this target's header search path.
#include <yoga/Yoga.h>
