// `[mouse]` / `[touchpad]` parsing: what a hand-edited file can say, and what
// Settings writes back.
#include "pointer_settings.hpp"

#include <cstdio>
#include <cstdlib>

static int failures = 0;

#define CHECK(cond)                                                    \
  do {                                                                 \
    if (!(cond)) {                                                     \
      std::fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #cond); \
      ++failures;                                                      \
    }                                                                  \
  } while (0)

int main() {
  using lava::PointerConfig;
  using lava::parsePointerKey;

  PointerConfig mouse;
  CHECK(parsePointerKey(mouse, "speed", "0.4"));
  CHECK(mouse.speed > 0.39 && mouse.speed < 0.41);
  // Clamped, not refused.
  parsePointerKey(mouse, "speed", "3");
  CHECK(mouse.speed == 1.0);
  parsePointerKey(mouse, "speed", "-7");
  CHECK(mouse.speed == -1.0);
  // Not a number: left as it was.
  parsePointerKey(mouse, "speed", "fast");
  CHECK(mouse.speed == -1.0);

  parsePointerKey(mouse, "acceleration", "Flat");
  CHECK(mouse.accel == "flat");
  parsePointerKey(mouse, "acceleration", "bouncy");
  CHECK(mouse.accel == "flat");

  parsePointerKey(mouse, "natural-scroll", "on");
  CHECK(mouse.naturalScroll);
  parsePointerKey(mouse, "natural-scroll", "maybe");
  CHECK(mouse.naturalScroll);
  parsePointerKey(mouse, "natural-scroll", "off");
  CHECK(!mouse.naturalScroll);

  PointerConfig pad = PointerConfig::touchpadDefaults();
  CHECK(pad.naturalScroll && pad.tapToClick && pad.disableWhileTyping);
  CHECK(pad.scroll == "two-finger" && pad.click.empty());
  parsePointerKey(pad, "tap-to-click", "off");
  CHECK(!pad.tapToClick);
  parsePointerKey(pad, "disable-while-typing", "no");
  CHECK(!pad.disableWhileTyping);
  parsePointerKey(pad, "scroll", "edge");
  CHECK(pad.scroll == "edge");
  parsePointerKey(pad, "scroll", "2fg");
  CHECK(pad.scroll == "two-finger");
  parsePointerKey(pad, "click", "clickfinger");
  CHECK(pad.click == "fingers");
  parsePointerKey(pad, "click", "default");
  CHECK(pad.click.empty());

  CHECK(!parsePointerKey(pad, "wobble", "1"));

  CHECK(lava::formatSpeed(0.25) == "0.25");
  CHECK(lava::formatSpeed(-0.001) == "0.00");
  CHECK(lava::formatSpeed(5) == "1.00");

  if (failures == 0) std::puts("pointer settings: ok");
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
