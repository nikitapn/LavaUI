// The indexer against a real directory tree: the crawl, then each kind of
// change inotify reports, then a change made while the daemon was not
// running — the Windows-partition case, where nothing could have told it.
//
// Uses the real thread, the real inotify and the Reader the RPC answers
// with. Nothing is mocked; the only thing missing is the RPC itself.

#include "config.hpp"
#include "indexer.hpp"
#include "store.hpp"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <functional>
#include <string>
#include <thread>

using namespace lava::indexer;
namespace fs = std::filesystem;

namespace {

int failures = 0;

void check(bool ok, const std::string &what) {
  if (ok) return;
  std::printf("FAIL: %s\n", what.c_str());
  ++failures;
}

bool waitFor(const std::function<bool()> &done, int ms = 5000) {
  const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(ms);
  while (std::chrono::steady_clock::now() < until) {
    if (done()) return true;
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
  }
  return done();
}

void touch(const fs::path &p, const std::string &content = "x") {
  fs::create_directories(p.parent_path());
  std::ofstream(p) << content;
}

std::vector<std::string> paths(Reader &r, const std::string &q, Kind k = Kind::any) {
  std::vector<std::string> out;
  for (auto &h : r.search(q, k, 50, 0).hits) out.push_back(h.path);
  return out;
}

bool has(Reader &r, const std::string &q, const fs::path &p) {
  for (const auto &s : paths(r, q))
    if (s == p.string()) return true;
  return false;
}

}  // namespace

int main() {
  char tmpl[] = "/tmp/lava-index-test-XXXXXX";
  const fs::path base = mkdtemp(tmpl);
  const fs::path root = base / "root";
  const fs::path outside = base / "outside";
  const std::string db = (base / "index.db").string();
  // Our own recently-used.xbel, not the user's.
  setenv("XDG_DATA_HOME", (base / "data").c_str(), 1);
  fs::create_directories(base / "data");
  fs::create_directories(outside);

  touch(root / "Documents/Work/Quarterly Report Q3.pdf");
  touch(root / "Documents/Admin/Invoice 0042.pdf");
  touch(root / "Videos/Site Report Walkthrough.mp4", std::string(4096, 'v'));
  touch(root / "node_modules/pkg/report.js");
  touch(root / ".hidden/report.txt");

  Config config;
  config.roots = {root.string()};
  config.excludes = {"node_modules"};

  // Written by the indexer thread.
  std::atomic<int> changes{0};
  {
    Indexer indexer(config, db, [&](bool) { ++changes; });
    indexer.start();
    check(waitFor([&] { return indexer.idle(); }), "first crawl settles");
    Reader reader(db);

    // ── the crawl ──
    auto hits = paths(reader, "report");
    check(hits.size() == 2, "two reports found, excluded and hidden ones not (got " +
                                std::to_string(hits.size()) + ")");
    check(has(reader, "quarterly", root / "Documents/Work/Quarterly Report Q3.pdf"),
          "full path rebuilt");
    check(paths(reader, "report", Kind::videos).size() == 1, "category filter");
    check(paths(reader, "work", Kind::folders).size() == 1, "folders filter");
    check(paths(reader, "in").size() == 1, "two letters: prefix match on a name");
    check(paths(reader, "report q3").size() == 1, "short and long terms together");
    {
      auto r = reader.search("report", Kind::any, 50, 0);
      // Same tier (a word start); the video is one level shallower.
      check(!r.hits.empty() && r.hits[0].size == 4096 && r.hits[0].ext == "mp4" &&
                r.hits[0].matchStart == 5 && r.hits[0].matchLength == 6,
            "the shallower report first, with its metadata and match");
    }
    const auto status = indexer.status();
    check(status.size() == 1 && status[0].online && status[0].watched, "root online, watched");

    // ── live changes ──
    touch(root / "Documents/new-report.txt");
    check(waitFor([&] { return has(reader, "new-report", root / "Documents/new-report.txt"); }),
          "a created file appears");

    touch(root / "Documents/new-report.txt", std::string(1000, 'y'));
    check(waitFor([&] {
            auto r = reader.search("new-report", Kind::any, 5, 0);
            return !r.hits.empty() && r.hits[0].size == 1000;
          }),
          "a rewritten file's size follows");

    fs::rename(root / "Documents/Work", root / "Documents/Archive");
    check(waitFor([&] {
            return has(reader, "quarterly", root / "Documents/Archive/Quarterly Report Q3.pdf");
          }),
          "a renamed directory's files follow it");

    fs::remove(root / "Documents/new-report.txt");
    check(waitFor([&] { return paths(reader, "new-report").empty(); }), "a deleted file goes");

    fs::rename(root / "Documents/Admin", outside / "Admin");
    check(waitFor([&] { return paths(reader, "invoice").empty(); }),
          "a directory moved out of the tree goes");

    fs::rename(outside / "Admin", root / "Videos/Admin");
    check(waitFor([&] { return has(reader, "invoice", root / "Videos/Admin/Invoice 0042.pdf"); }),
          "a directory moved in is walked");

    touch(root / "Videos/Admin/deeper/later.pdf");
    check(waitFor([&] { return has(reader, "later", root / "Videos/Admin/deeper/later.pdf"); }),
          "and watched once it is");

    fs::create_directories(root / "Fresh/a/b");
    touch(root / "Fresh/a/b/quick.txt");
    check(waitFor([&] { return has(reader, "quick", root / "Fresh/a/b/quick.txt"); }),
          "a tree created at once is caught up");

    // ── recent ──
    indexer.noteOpened((root / "Videos/Site Report Walkthrough.mp4").string(), "test");
    check(waitFor([&] {
            std::vector<std::string> missing;
            auto r = reader.recent(10, missing);
            return r.size() == 1 && r[0].lastOpenedSeconds > 0 && r[0].size == 4096;
          }),
          "an open is recent, with the indexed metadata");
    indexer.noteOpened((base / "gone.txt").string(), "test");
    check(waitFor([&] {
            std::vector<std::string> missing;
            reader.recent(10, missing);
            return missing.size() == 1;
          }),
          "a recent path that does not exist is reported for pruning");

    check(!indexer.requestRescan("/not/a/root"), "rescan of a stranger is refused");
    // Coalesced: the first announcement is due 250 ms after the first change,
    // and everything above can finish inside that.
    check(waitFor([&] { return changes > 0; }), "changes were announced");
    indexer.stop();
  }

  // ── while it was not running ──
  fs::remove(root / "Videos/Admin/Invoice 0042.pdf");
  touch(root / "Videos/offline-made.pdf");
  {
    Indexer indexer(config, db, nullptr);
    indexer.start();
    check(waitFor([&] { return indexer.idle(); }), "restart settles");
    Reader reader(db);
    check(paths(reader, "invoice").empty(), "a file deleted while stopped is gone after restart");
    check(paths(reader, "offline-made").size() == 1, "one created while stopped is found");
    check(!paths(reader, "quarterly").empty(), "and nothing else was lost");
  }

  // ── a root dropped from the config takes its rows with it ──
  {
    Config none;
    Indexer indexer(none, db, nullptr);
    indexer.start();
    check(waitFor([&] { return indexer.idle(); }), "empty config settles");
    Reader reader(db);
    check(paths(reader, "quarterly").empty(), "unconfigured root forgotten");
  }

  // ── the config edited while running, the way Settings saves it ──
  {
    const fs::path second = base / "second";
    touch(second / "Music/song.flac");
    touch(second / "Music/skipme/hidden-by-exclude.flac");
    const fs::path conf = base / "conf/index.conf";
    fs::create_directories(conf.parent_path());
    auto save = [&](const std::string &text) {
      // Written beside and renamed over, as Settings and most editors do.
      std::ofstream(conf.string() + ".tmp") << text;
      fs::rename(conf.string() + ".tmp", conf);
    };
    save("root = " + root.string() + "\n");
    Indexer indexer(loadConfig(conf.string()), db, nullptr, conf.string());
    indexer.start();
    check(waitFor([&] { return indexer.idle(); }), "config run settles");
    Reader reader(db);
    check(!paths(reader, "quarterly").empty(), "the configured root is indexed");

    save("root = " + root.string() + "\nroot = " + second.string() + "\nexclude = skipme\n");
    check(waitFor([&] { return paths(reader, "song").size() == 1; }),
          "a root added to the config is crawled without a restart");
    check(paths(reader, "hidden-by-exclude").empty(), "and its excludes apply");
    check(waitFor([&] { return indexer.status().size() == 2; }), "status lists both roots");

    save("root = " + second.string() + "\n");
    check(waitFor([&] { return paths(reader, "quarterly").empty(); }),
          "a root removed from the config takes its rows with it");
    check(waitFor([&] { return paths(reader, "hidden-by-exclude").size() == 1; }),
          "and a dropped exclude lets its folder back in");
    touch(second / "Music/later.flac");
    check(waitFor([&] { return paths(reader, "later").size() == 1; }),
          "the remaining root is still watched after the reload");
  }

  fs::remove_all(base);
  if (failures) std::printf("%d failure(s)\n", failures);
  else std::printf("ok\n");
  return failures ? 1 : 0;
}
