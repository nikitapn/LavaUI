#pragma once

// The database, in two halves with different owners.
//
// `Store` is the writer: one connection, owned by the indexer thread, and
// every statement that changes a row lives here. `Reader` is what the RPC
// threads search with — read-only, one per thread, so a search never takes a
// lock against the crawl. WAL is what makes that legal: readers see the last
// committed snapshot while the writer carries on.

#include "ranking.hpp"
#include "sqlite.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

namespace lava::indexer {

/// Mirrors `lava.index.EntryKind`.
enum class EntryKind : uint32_t { file = 0, directory = 1, symlink = 2 };

struct Row {
  int64_t id = 0;
  std::string name;
  EntryKind kind = EntryKind::file;
  int64_t size = 0;
  int64_t mtimeNs = 0;
  int64_t ino = 0;
};

/// $XDG_DATA_HOME/lava/index.db, or LAVA_INDEX_DB.
std::string defaultDatabasePath();

class Store {
 public:
  /// Opens or creates the database. One written by a newer schema, or one
  /// that is not ours at all, is deleted and recreated: every row in it can
  /// be rebuilt from the disk, and refusing to start would leave the user
  /// with no search instead of a slow first one.
  explicit Store(const std::string &path);

  /// Makes `root` match the configured paths: adds new ones, and deletes the
  /// ones no longer configured along with every entry under them.
  /// Returns path → root id.
  std::unordered_map<std::string, int64_t> syncRoots(const std::vector<std::string> &paths);

  std::string rootFilesystem(int64_t root);
  void setRootFilesystem(int64_t root, const std::string &identity);
  void setReconciled(int64_t root, int64_t nowNs);
  /// Every entry under a root, for adopting a different disk.
  void clearRoot(int64_t root);

  /// The root's own directory row, created on first use.
  int64_t rootEntry(int64_t root, const std::string &rootPath);

  std::vector<Row> children(int64_t dir);
  std::optional<Row> lookup(int64_t dir, const std::string &name);
  int64_t insert(int64_t parent, int64_t root, const Row &row);
  void update(const Row &row);
  void remove(int64_t id);
  void move(int64_t id, int64_t newParent, const std::string &newName);
  /// The directory ids under `dir` (not including it), for dropping their
  /// watches before a delete cascades through them.
  std::vector<int64_t> descendantDirectories(int64_t dir);
  /// The absolute path of an entry, walking `parent` up.
  std::optional<std::string> pathOf(int64_t id);

  /// Records an open. `count` false for imports from xbel, which carry a
  /// time and no meaningful count.
  void noteOpened(const std::string &path, int64_t whenNs, const std::string &source,
                  bool count);
  void forgetRecent(const std::string &path);

  void begin() { db_.exec("BEGIN"); }
  void commit() { db_.exec("COMMIT"); }

 private:
  Db db_;
  Stmt children_, lookup_, insert_, update_, remove_, move_, parentOf_, rootPath_,
      noteOpened_, noteImported_, forgetRecent_;
};

/// The read side. Not thread-safe; one per thread.
class Reader {
 public:
  explicit Reader(const std::string &path);

  struct Hit {
    int64_t id = 0;
    std::string path;
    EntryKind kind = EntryKind::file;
    int64_t size = 0;
    int64_t mtimeSeconds = 0;
    std::string ext;
    uint32_t matchStart = 0;
    uint32_t matchLength = 0;
    int64_t lastOpenedSeconds = 0;
  };

  struct Result {
    std::vector<Hit> hits;
    bool truncated = false;
  };

  /// See `Index.Search` in idl/index.npidl.
  Result search(const std::string &query, Kind category, uint32_t limit, int64_t nowSeconds);

  /// The newest opens, newest first, with entry metadata where the path is
  /// indexed and a stat where it is not. Paths that are gone are returned in
  /// `missing` for the writer to prune — a reader cannot.
  std::vector<Hit> recent(uint32_t limit, std::vector<std::string> &missing);

  int64_t countUnder(int64_t root);

 private:
  struct Candidate {
    int64_t id, parent, root;
    std::string name;
    EntryKind kind;
    int64_t size, mtimeNs;
    std::string ext;
    NameScore score;
    double total = 0;
    std::string path;
    int depth = 0;
    int64_t lastOpened = 0;
  };

  // Resolves `c.path` and `c.depth`. Directories are cached per query: a page
  // of hits tends to share most of its ancestors.
  void resolvePath(Candidate &c, std::unordered_map<int64_t, std::string> &dirs);
  std::optional<int64_t> entryForPath(const std::string &path);
  /// Resets every statement, ending the read transaction. Called on the way
  /// out of each public method — see `Stmt::finish`.
  void release();

  Db db_;
  Stmt parent_, rootPath_, recent_, recentOf_, child_, rootFor_;
};

}  // namespace lava::indexer
