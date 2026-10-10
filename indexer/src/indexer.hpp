#pragma once

// The writer: one thread that owns the database's only read-write connection
// and everything that feeds it — the crawl, inotify, the mount table and the
// GTK recent-files list.
//
// One thread on purpose. Every source of change ends in the same handful of
// statements, and serialising them here is what lets a rename seen by
// inotify and a reconcile walking the same directory never interleave. The
// cost is that events wait while a crawl runs; they queue in the kernel, and
// if the queue overflows (`IN_Q_OVERFLOW`) the answer is another reconcile,
// which is what it would have been anyway.

#include "config.hpp"

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace lava::indexer {

struct RootState {
  int64_t id = 0;
  std::string path;
  bool online = false;
  bool watched = false;
  bool scanning = false;
  int64_t lastReconcileNs = 0;
};

class Indexer {
 public:
  /// Called on the indexer thread, coalesced to a few a second.
  /// `recentOnly` is true when no entry changed, only the recent list.
  using ChangeFn = std::function<void(bool recentOnly)>;

  Indexer(Config config, std::string dbPath, ChangeFn onChange);
  ~Indexer();
  Indexer(const Indexer &) = delete;
  Indexer &operator=(const Indexer &) = delete;

  /// Opens the database (creating it) and starts the thread. Throws if the
  /// database cannot be opened, so a broken setup fails at start, loudly.
  void start();
  void stop();

  // Thread-safe; each queues work for the indexer thread and returns.
  /// False when `path` is not a configured root.
  bool requestRescan(const std::string &path);
  void noteOpened(const std::string &path, const std::string &appId);
  void forgetRecent(std::vector<std::string> paths);

  std::vector<RootState> status() const;

  /// True once every online root has finished its first reconcile. For tests
  /// and for the query tool's `--wait`.
  bool idle() const;

 private:
  struct Impl;
  Impl *impl_ = nullptr;
};

}  // namespace lava::indexer
