#include "workspace_names.hpp"

#include <cstdlib>

namespace lava {

namespace {

std::string trimmed(const std::string &s) {
  const auto first = s.find_first_not_of(" \t");
  if (first == std::string::npos) return {};
  const auto last = s.find_last_not_of(" \t");
  return s.substr(first, last - first + 1);
}

} // namespace

std::string cleanWorkspaceName(const std::string &raw) {
  std::string kept;
  kept.reserve(raw.size());
  for (const char c : raw) {
    const auto byte = static_cast<unsigned char>(c);
    if (c == '#' || byte < 0x20 || byte == 0x7f) continue;
    kept.push_back(c);
  }
  kept = trimmed(kept);
  if (kept.size() > kWorkspaceNameBytes) {
    std::size_t cut = kWorkspaceNameBytes;
    // Back off continuation bytes (10xxxxxx) to the start of a character.
    while (cut > 0 && (static_cast<unsigned char>(kept[cut]) & 0xC0) == 0x80) --cut;
    kept = trimmed(kept.substr(0, cut));
  }
  return kept;
}

bool parseWorkspaceKey(std::vector<std::string> &names, const std::string &key,
                       const std::string &value) {
  char *end = nullptr;
  const long number = std::strtol(key.c_str(), &end, 10);
  if (end == key.c_str() || *end != '\0' || number < 1 || number > kWorkspaceCount)
    return false;
  const auto index = static_cast<std::size_t>(number - 1);
  if (names.size() <= index) names.resize(index + 1);
  names[index] = cleanWorkspaceName(value);
  return true;
}

} // namespace lava
