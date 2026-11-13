// `[workspaces]` parsing, and the cleaning `SetWorkspaceNames` does before a
// name is kept and written back to lava.conf.
#include "workspace_names.hpp"

#include <cstdio>
#include <string>
#include <vector>

static int failures = 0;

#define CHECK(cond)                                                    \
  do {                                                                 \
    if (!(cond)) {                                                     \
      std::fprintf(stderr, "%s:%d: CHECK(%s)\n", __FILE__, __LINE__, #cond); \
      ++failures;                                                      \
    }                                                                  \
  } while (0)

int main() {
  using lava::cleanWorkspaceName;
  using lava::parseWorkspaceKey;

  // Numbered as Mod+1…9 counts, stored from 0.
  std::vector<std::string> names;
  CHECK(parseWorkspaceKey(names, "2", "Work"));
  CHECK(names.size() == 2 && names[0].empty() && names[1] == "Work");
  CHECK(parseWorkspaceKey(names, "9", "Last"));
  CHECK(names.size() == 9 && names[8] == "Last");
  // An empty value is no name, not an error: Settings clears a name that way.
  CHECK(parseWorkspaceKey(names, "2", ""));
  CHECK(names[1].empty());

  // Keys that name no workspace are refused, and change nothing.
  const std::vector<std::string> before = names;
  CHECK(!parseWorkspaceKey(names, "0", "x"));
  CHECK(!parseWorkspaceKey(names, "10", "x"));
  CHECK(!parseWorkspaceKey(names, "-1", "x"));
  CHECK(!parseWorkspaceKey(names, "2a", "x"));
  CHECK(!parseWorkspaceKey(names, "", "x"));
  CHECK(!parseWorkspaceKey(names, "work", "x"));
  CHECK(names == before);

  // What the file could not hold back: a `#` would start a comment, a line
  // break would end the line and leave the rest as a line of its own.
  CHECK(cleanWorkspaceName("  Work  ") == "Work");
  CHECK(cleanWorkspaceName("C# work") == "C work");
  CHECK(cleanWorkspaceName("Work\nbogus = 1") == "Workbogus = 1");
  CHECK(cleanWorkspaceName("a\tb\rc\x7f") == "abc");
  CHECK(cleanWorkspaceName("#") == "");
  // Kept as typed otherwise: an `=` is fine, the parser splits at the first.
  CHECK(cleanWorkspaceName("A = B") == "A = B");
  CHECK(cleanWorkspaceName("Работа") == "Работа");

  // At most 64 bytes, and never through a character: "ж" is two bytes, so a
  // 32-character run of them is exactly 64 and one more is cut at 64, not 65.
  std::string zh;
  for (int i = 0; i < 33; ++i) zh += "ж";
  const std::string cut = cleanWorkspaceName(zh);
  CHECK(cut.size() == 64);
  // Odd offset: one ASCII letter first, so byte 64 is the middle of a "ж".
  const std::string odd = cleanWorkspaceName("a" + zh);
  CHECK(odd.size() == 63);
  CHECK(odd.back() != '\xd0');

  if (failures != 0) {
    std::fprintf(stderr, "%d failure(s)\n", failures);
    return 1;
  }
  std::puts("workspace names: ok");
  return 0;
}
