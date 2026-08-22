// The font digest memo: what it may skip, and what it must not.
//
// `fontFileDigest` exists to stop a face being hashed twice — the same file at
// two sizes, a second client registering what the first already did, a
// relaunch into a compositor that has been up all day. Hashing 19 MiB of CJK
// collection is most of what starting a terminal used to cost.
//
// The risk in a memo is the other half: a font replaced under a running
// session must not keep the identity of the bytes it no longer has, because
// that identity is what the glyph atlas is keyed by. So both directions are
// checked here — a repeat answer is the same, and a rewritten file's is not.
//
// No GPU and no FreeType: hashing a file is plain I/O and arithmetic.

#include "render/font_key.hpp"

#include <unistd.h>

#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

using canvas::FontDigest;

namespace {

int failures = 0;

#define CHECK(cond)                                                            \
  do {                                                                         \
    if (!(cond)) {                                                             \
      std::fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__,    \
                   #cond);                                                     \
      ++failures;                                                              \
    }                                                                          \
  } while (0)

/// A file of `size` bytes filled from `seed`, so two calls with different
/// seeds differ everywhere rather than in a header nobody reads.
bool writeFile(const std::string &path, size_t size, uint8_t seed) {
  std::vector<uint8_t> bytes(size);
  for (size_t i = 0; i < size; ++i) {
    bytes[i] = static_cast<uint8_t>(seed + (i % 251));
  }
  std::FILE *file = std::fopen(path.c_str(), "wb");
  if (file == nullptr) return false;
  const size_t written = std::fwrite(bytes.data(), 1, bytes.size(), file);
  std::fclose(file);
  return written == bytes.size();
}

std::string tempPath(const char *name) {
  return std::string("/tmp/canvas-font-digest-") + name + "-" +
         std::to_string(::getpid()) + ".bin";
}

/// The plain answer, and the bytes that come with it.
void digestMatchesTheHashOfTheBytes() {
  const std::string path = tempPath("plain");
  CHECK(writeFile(path, 4096, 7));

  std::vector<uint8_t> bytes;
  FontDigest digest;
  CHECK(canvas::fontFileDigest(path, digest, bytes));
  CHECK(!digest.empty());
  // A miss reads the file, and the caller is handed what was read rather than
  // being made to read it again.
  CHECK(bytes.size() == 4096);
  CHECK(digest == canvas::sha256(bytes));

  std::remove(path.c_str());
}

/// The point of the thing: asking twice costs one read.
void repeatAnswersFromTheMemo() {
  const std::string path = tempPath("repeat");
  CHECK(writeFile(path, 4096, 11));

  std::vector<uint8_t> first;
  FontDigest firstDigest;
  CHECK(canvas::fontFileDigest(path, firstDigest, first));
  CHECK(first.size() == 4096);

  std::vector<uint8_t> second;
  FontDigest secondDigest;
  CHECK(canvas::fontFileDigest(path, secondDigest, second));
  CHECK(secondDigest == firstDigest);
  // Nothing was read the second time — which is the whole saving, and the
  // contract callers rely on when they decide whether to read it themselves.
  CHECK(second.empty());

  std::remove(path.c_str());
}

/// The half that keeps content addressing honest.
void rewrittenFileGetsANewDigest() {
  const std::string path = tempPath("rewritten");
  CHECK(writeFile(path, 4096, 3));

  std::vector<uint8_t> bytes;
  FontDigest before;
  CHECK(canvas::fontFileDigest(path, before, bytes));

  // Same path, same length: only the bytes and the mtime differ, which is a
  // font package upgrade in miniature. Some filesystems keep mtime at a
  // coarser resolution than one write takes, so give it a tick to change.
  std::this_thread::sleep_for(std::chrono::milliseconds(20));
  CHECK(writeFile(path, 4096, 200));

  std::vector<uint8_t> after;
  FontDigest afterDigest;
  CHECK(canvas::fontFileDigest(path, afterDigest, after));
  CHECK(!(afterDigest == before));
  CHECK(after.size() == 4096);
  CHECK(afterDigest == canvas::sha256(after));

  std::remove(path.c_str());
}

/// A path that is not there is not a digest, and does not poison the memo.
void missingFileFails() {
  std::vector<uint8_t> bytes;
  FontDigest digest;
  CHECK(!canvas::fontFileDigest(tempPath("absent"), digest, bytes));
  CHECK(bytes.empty());
}

} // namespace

int main()
{
  digestMatchesTheHashOfTheBytes();
  repeatAnswersFromTheMemo();
  rewrittenFileGetsANewDigest();
  missingFileFails();

  if (failures != 0) {
    std::fprintf(stderr, "%d check(s) failed\n", failures);
    return 1;
  }
  std::puts("font digest: ok");
  return 0;
}
