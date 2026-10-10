#include "store.hpp"

#include "schema_sql.hpp"  // generated from schema.sql: `kSchemaSql`

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <map>
#include <sys/stat.h>

namespace lava::indexer {

namespace {

constexpr int64_t kSchemaVersion = 1;

// How many FTS matches are scored per query. Enough that the best few of a
// broad query are almost always among them; small enough that scoring stays
// well under a millisecond. A query that hits the cap reports `truncated`.
constexpr int64_t kCandidates = 2000;

int64_t userVersion(Db &db) {
  Stmt s = db.prepare("PRAGMA user_version");
  return s.step() ? s.i64(0) : 0;
}

void connectionPragmas(Db &db) {
  // Per connection, not stored in the file: without it the cascades in the
  // schema are silently not run.
  db.exec("PRAGMA foreign_keys = ON");
  db.exec("PRAGMA synchronous = NORMAL");
}

// An FTS5 string literal: double quotes, with embedded ones doubled. Inside
// one, nothing the user typed is syntax — `-`, `*` and `AND` are just text.
std::string ftsString(const std::string &term) {
  std::string out = "\"";
  for (char c : term) {
    if (c == '"') out += "\"\"";
    else out += c;
  }
  out += '"';
  return out;
}

size_t utf8Length(const std::string &s) {
  size_t n = 0;
  for (unsigned char c : s) n += (c & 0xC0) != 0x80;
  return n;
}

std::string categoryFilter(Kind category) {
  if (category == Kind::folders) return " AND e.kind = 1";
  const auto &exts = extensionsOf(category);
  if (exts.empty()) return {};
  std::string sql = " AND e.ext IN (";
  for (size_t i = 0; i < exts.size(); ++i) {
    if (i) sql += ',';
    sql += '\'';
    sql += exts[i];  // fixed lowercase literals from ranking.cpp, never input
    sql += '\'';
  }
  return sql + ")";
}

}  // namespace

std::string defaultDatabasePath() {
  if (const char *p = std::getenv("LAVA_INDEX_DB"); p && *p) return p;
  const char *xdg = std::getenv("XDG_DATA_HOME");
  const char *home = std::getenv("HOME");
  const std::string base =
      (xdg && *xdg) ? std::string(xdg) : std::string(home ? home : "") + "/.local/share";
  return base + "/lava/index.db";
}

// ── Store ──────────────────────────────────────────────────────────────────

Store::Store(const std::string &path) {
  std::filesystem::create_directories(std::filesystem::path(path).parent_path());
  db_ = Db(path, false);
  int64_t version = 0;
  try {
    version = userVersion(db_);
  } catch (const SqliteError &) {
    version = -1;  // not a database at all
  }
  if (version != 0 && version != kSchemaVersion) {
    std::fprintf(stderr, "lava-index: %s is schema %lld, want %lld; rebuilding\n",
                 path.c_str(), static_cast<long long>(version),
                 static_cast<long long>(kSchemaVersion));
    db_ = Db();
    for (const char *suffix : {"", "-wal", "-shm"}) std::remove((path + suffix).c_str());
    db_ = Db(path, false);
    version = 0;
  }
  if (version == 0) db_.exec(kSchemaSql);
  connectionPragmas(db_);

  children_ = db_.prepare(
      "SELECT id, name, kind, size, mtime_ns, ino FROM entry WHERE parent = ?1");
  lookup_ = db_.prepare(
      "SELECT id, name, kind, size, mtime_ns, ino FROM entry WHERE parent = ?1 AND name = ?2");
  insert_ = db_.prepare(
      "INSERT INTO entry(parent, root, name, kind, size, mtime_ns, ext, ino) "
      "VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)");
  update_ = db_.prepare(
      "UPDATE entry SET kind = ?2, size = ?3, mtime_ns = ?4, ino = ?5 WHERE id = ?1");
  remove_ = db_.prepare("DELETE FROM entry WHERE id = ?1");
  move_ = db_.prepare("UPDATE entry SET parent = ?2, name = ?3, ext = ?4 WHERE id = ?1");
  parentOf_ = db_.prepare("SELECT parent, name, root FROM entry WHERE id = ?1");
  rootPath_ = db_.prepare("SELECT path FROM root WHERE id = ?1");
  noteOpened_ = db_.prepare(
      "INSERT INTO recent(path, last_open_ns, open_count, source) VALUES (?1, ?2, 1, ?3) "
      "ON CONFLICT(path) DO UPDATE SET last_open_ns = max(last_open_ns, excluded.last_open_ns), "
      "open_count = open_count + 1, source = excluded.source");
  // An import says when, not how often, and the same file is re-imported on
  // every change to the xbel — counting it would count the file's rewrites.
  noteImported_ = db_.prepare(
      "INSERT INTO recent(path, last_open_ns, open_count, source) VALUES (?1, ?2, 1, ?3) "
      "ON CONFLICT(path) DO UPDATE SET last_open_ns = excluded.last_open_ns, "
      "source = excluded.source WHERE excluded.last_open_ns > last_open_ns");
  forgetRecent_ = db_.prepare("DELETE FROM recent WHERE path = ?1");
}

std::unordered_map<std::string, int64_t> Store::syncRoots(const std::vector<std::string> &paths) {
  std::unordered_map<std::string, int64_t> out;
  begin();
  {
    Stmt all = db_.prepare("SELECT id, path FROM root");
    std::vector<int64_t> stale;
    while (all.step()) {
      const std::string p(all.text(1));
      if (std::find(paths.begin(), paths.end(), p) == paths.end()) stale.push_back(all.i64(0));
      else out[p] = all.i64(0);
    }
    Stmt del = db_.prepare("DELETE FROM root WHERE id = ?1");
    for (int64_t id : stale) del.reset().bind(1, id).run();
    Stmt add = db_.prepare("INSERT INTO root(path) VALUES (?1)");
    for (const std::string &p : paths) {
      if (out.count(p)) continue;
      add.reset().bind(1, p).run();
      out[p] = db_.lastInsertId();
    }
  }
  commit();
  return out;
}

std::string Store::rootFilesystem(int64_t root) {
  Stmt s = db_.prepare("SELECT filesystem FROM root WHERE id = ?1");
  s.bind(1, root);
  return s.step() ? std::string(s.text(0)) : std::string();
}

void Store::setRootFilesystem(int64_t root, const std::string &identity) {
  db_.prepare("UPDATE root SET filesystem = ?2 WHERE id = ?1").bind(1, root).bind(2, identity).run();
}

void Store::setReconciled(int64_t root, int64_t nowNs) {
  db_.prepare("UPDATE root SET last_reconcile_ns = ?2 WHERE id = ?1")
      .bind(1, root)
      .bind(2, nowNs)
      .run();
}

void Store::clearRoot(int64_t root) {
  db_.prepare("DELETE FROM entry WHERE root = ?1").bind(1, root).run();
}

int64_t Store::rootEntry(int64_t root, const std::string &rootPath) {
  Stmt find = db_.prepare("SELECT id FROM entry WHERE root = ?1 AND parent IS NULL");
  find.bind(1, root);
  if (find.step()) return find.i64(0);
  const size_t slash = rootPath.rfind('/');
  Row row;
  row.name = slash == std::string::npos ? rootPath : rootPath.substr(slash + 1);
  row.kind = EntryKind::directory;
  insert_.reset().bindNull(1).bind(2, root).bind(3, row.name).bind(4, 1).bind(5, 0).bind(6, 0)
      .bind(7, "").bind(8, 0).run();
  return db_.lastInsertId();
}

namespace {
Row readRow(const Stmt &s) {
  Row r;
  r.id = s.i64(0);
  r.name = std::string(s.text(1));
  r.kind = static_cast<EntryKind>(s.i64(2));
  r.size = s.i64(3);
  r.mtimeNs = s.i64(4);
  r.ino = s.i64(5);
  return r;
}
}  // namespace

std::vector<Row> Store::children(int64_t dir) {
  std::vector<Row> out;
  children_.reset().bind(1, dir);
  while (children_.step()) out.push_back(readRow(children_));
  return out;
}

std::optional<Row> Store::lookup(int64_t dir, const std::string &name) {
  lookup_.reset().bind(1, dir).bind(2, name);
  if (!lookup_.step()) return std::nullopt;
  Row row = readRow(lookup_);
  lookup_.finish();
  return row;
}

int64_t Store::insert(int64_t parent, int64_t root, const Row &row) {
  insert_.reset()
      .bind(1, parent)
      .bind(2, root)
      .bind(3, row.name)
      .bind(4, static_cast<int64_t>(row.kind))
      .bind(5, row.size)
      .bind(6, row.mtimeNs)
      .bind(7, row.kind == EntryKind::directory ? std::string() : extensionOf(row.name))
      .bind(8, row.ino)
      .run();
  return db_.lastInsertId();
}

void Store::update(const Row &row) {
  update_.reset()
      .bind(1, row.id)
      .bind(2, static_cast<int64_t>(row.kind))
      .bind(3, row.size)
      .bind(4, row.mtimeNs)
      .bind(5, row.ino)
      .run();
}

void Store::remove(int64_t id) { remove_.reset().bind(1, id).run(); }

void Store::move(int64_t id, int64_t newParent, const std::string &newName) {
  move_.reset().bind(1, id).bind(2, newParent).bind(3, newName).bind(4, extensionOf(newName)).run();
}

std::vector<int64_t> Store::descendantDirectories(int64_t dir) {
  Stmt s = db_.prepare(
      "WITH RECURSIVE d(id) AS (SELECT id FROM entry WHERE parent = ?1 AND kind = 1 "
      "UNION ALL SELECT e.id FROM entry e JOIN d ON e.parent = d.id WHERE e.kind = 1) "
      "SELECT id FROM d");
  s.bind(1, dir);
  std::vector<int64_t> out;
  while (s.step()) out.push_back(s.i64(0));
  return out;
}

std::optional<std::string> Store::pathOf(int64_t id) {
  std::vector<std::string> parts;
  int64_t cur = id;
  for (int guard = 0; guard < 4096; ++guard) {
    parentOf_.reset().bind(1, cur);
    if (!parentOf_.step()) return std::nullopt;
    if (parentOf_.isNull(0)) {
      const int64_t root = parentOf_.i64(2);
      rootPath_.reset().bind(1, root);
      if (!rootPath_.step()) return std::nullopt;
      std::string path(rootPath_.text(0));
      rootPath_.finish();
      parentOf_.finish();
      for (auto it = parts.rbegin(); it != parts.rend(); ++it) path += "/" + *it;
      return path;
    }
    parts.emplace_back(parentOf_.text(1));
    cur = parentOf_.i64(0);
  }
  parentOf_.finish();
  return std::nullopt;
}

void Store::noteOpened(const std::string &path, int64_t whenNs, const std::string &source,
                       bool count) {
  Stmt &s = count ? noteOpened_ : noteImported_;
  s.reset().bind(1, path).bind(2, whenNs).bind(3, source).run();
}

void Store::forgetRecent(const std::string &path) { forgetRecent_.reset().bind(1, path).run(); }

// ── Reader ─────────────────────────────────────────────────────────────────

Reader::Reader(const std::string &path) : db_(path, true) {
  parent_ = db_.prepare("SELECT parent, name, root FROM entry WHERE id = ?1");
  rootPath_ = db_.prepare("SELECT path FROM root WHERE id = ?1");
  recent_ = db_.prepare("SELECT path, last_open_ns FROM recent ORDER BY last_open_ns DESC LIMIT ?1");
  recentOf_ = db_.prepare("SELECT last_open_ns FROM recent WHERE path = ?1");
  child_ = db_.prepare(
      "SELECT id, kind, size, mtime_ns, ext FROM entry WHERE parent = ?1 AND name = ?2");
  rootFor_ = db_.prepare(
      "SELECT r.id, r.path, e.id FROM root r JOIN entry e ON e.root = r.id AND e.parent IS NULL");
}

void Reader::resolvePath(Candidate &c, std::unordered_map<int64_t, std::string> &dirs) {
  std::vector<std::pair<int64_t, std::string>> chain;  // (dir id, name), leaf-most first
  int64_t cur = c.parent;
  std::string base;
  int depth = 0;
  for (int guard = 0; guard < 4096; ++guard) {
    if (auto it = dirs.find(cur); it != dirs.end()) {
      base = it->second;
      break;
    }
    parent_.reset().bind(1, cur);
    if (!parent_.step()) break;
    if (parent_.isNull(0)) {
      rootPath_.reset().bind(1, parent_.i64(2));
      if (rootPath_.step()) base = std::string(rootPath_.text(0));
      dirs[cur] = base;
      break;
    }
    chain.emplace_back(cur, std::string(parent_.text(1)));
    cur = parent_.i64(0);
  }
  // Fill the cache on the way back down, so siblings and cousins stop early.
  for (auto it = chain.rbegin(); it != chain.rend(); ++it) {
    base += "/" + it->second;
    dirs[it->first] = base;
  }
  c.path = base + "/" + c.name;
  for (char ch : c.path) depth += ch == '/';
  c.depth = depth;
}

void Reader::release() {
  for (Stmt *s : {&parent_, &rootPath_, &recent_, &recentOf_, &child_, &rootFor_}) s->finish();
}

Reader::Result Reader::search(const std::string &query, Kind category, uint32_t limit,
                              int64_t nowSeconds) {
  struct Release {
    Reader &r;
    ~Release() { r.release(); }
  } releaseOnExit{*this};
  Result result;
  const std::vector<std::string> terms = splitQuery(query);
  if (terms.empty() || limit == 0) return result;

  std::vector<std::string> longTerms, shortTerms;
  for (const auto &t : terms) (utf8Length(t) >= 3 ? longTerms : shortTerms).push_back(t);

  const std::string columns =
      "SELECT e.id, e.parent, e.root, e.name, e.kind, e.size, e.mtime_ns, e.ext ";
  std::string sql;
  Stmt stmt;
  if (!longTerms.empty()) {
    std::string match;
    for (const auto &t : longTerms) {
      if (!match.empty()) match += " AND ";
      match += ftsString(t);
    }
    sql = columns +
          "FROM entry_fts JOIN entry e ON e.id = entry_fts.rowid "
          "WHERE entry_fts MATCH ?1 AND e.parent IS NOT NULL" +
          categoryFilter(category) + " LIMIT ?2";
    stmt = db_.prepare(sql);
    stmt.bind(1, match).bind(2, kCandidates);
  } else {
    // Nothing a trigram index can answer: a prefix range on the folded name,
    // which `entry_by_name_nocase` serves. A one-letter query is a prefix
    // match by necessity, and also by intent — nobody types "a" meaning
    // "every name with an a in it".
    const std::string lo = shortTerms.front();
    std::string hi = lo;
    hi.back() = static_cast<char>(hi.back() + 1);
    sql = columns +
          "FROM entry e WHERE e.name COLLATE NOCASE >= ?1 AND e.name COLLATE NOCASE < ?2 "
          "AND e.parent IS NOT NULL" +
          categoryFilter(category) + " LIMIT ?3";
    stmt = db_.prepare(sql);
    stmt.bind(1, lo).bind(2, hi).bind(3, kCandidates);
  }

  std::vector<Candidate> candidates;
  while (stmt.step()) {
    Candidate c{};
    c.id = stmt.i64(0);
    c.parent = stmt.i64(1);
    c.root = stmt.i64(2);
    c.name = std::string(stmt.text(3));
    c.kind = static_cast<EntryKind>(stmt.i64(4));
    c.size = stmt.i64(5);
    c.mtimeNs = stmt.i64(6);
    c.ext = std::string(stmt.text(7));
    c.score = scoreName(c.name, terms);
    // FTS checked the long terms; the short ones are this loop's to check.
    const std::string folded = foldAscii(c.name);
    bool keep = true;
    for (const auto &t : shortTerms) keep = keep && folded.find(t) != std::string::npos;
    if (!keep) continue;
    c.total = c.score.score;
    candidates.push_back(std::move(c));
  }
  result.truncated = static_cast<int64_t>(candidates.size()) >= kCandidates;

  // Paths and recency only for the front of the field: resolving a path is a
  // few lookups, and doing it for two thousand names nobody will see is the
  // whole cost of a query.
  auto byScore = [](const Candidate &a, const Candidate &b) {
    if (a.total != b.total) return a.total > b.total;
    return a.name < b.name;
  };
  const size_t front = std::min<size_t>(candidates.size(), static_cast<size_t>(limit) * 3);
  std::partial_sort(candidates.begin(), candidates.begin() + static_cast<long>(front),
                    candidates.end(), byScore);
  if (candidates.size() > limit) result.truncated = true;
  candidates.resize(front);

  std::unordered_map<int64_t, std::string> dirs;
  for (Candidate &c : candidates) {
    resolvePath(c, dirs);
    recentOf_.reset().bind(1, c.path);
    if (recentOf_.step()) c.lastOpened = recentOf_.i64(0) / 1'000'000'000;
    c.total += contextBoost(nowSeconds, c.lastOpened, c.depth, c.kind == EntryKind::directory);
  }
  std::sort(candidates.begin(), candidates.end(), byScore);
  if (candidates.size() > limit) candidates.resize(limit);

  for (Candidate &c : candidates) {
    Hit h;
    h.id = c.id;
    h.path = std::move(c.path);
    h.kind = c.kind;
    h.size = c.size;
    h.mtimeSeconds = c.mtimeNs / 1'000'000'000;
    h.ext = std::move(c.ext);
    h.matchStart = c.score.matched ? c.score.matchStart : 0;
    h.matchLength = c.score.matched ? c.score.matchLength : 0;
    h.lastOpenedSeconds = c.lastOpened;
    result.hits.push_back(std::move(h));
  }
  return result;
}

std::optional<int64_t> Reader::entryForPath(const std::string &path) {
  // The deepest root containing the path, then one lookup per component.
  int64_t entry = 0;
  size_t used = 0;
  rootFor_.reset();
  while (rootFor_.step()) {
    const std::string_view root = rootFor_.text(1);
    const bool inside = path.size() > root.size() && path.compare(0, root.size(), root) == 0 &&
                        path[root.size()] == '/';
    if (inside && root.size() > used) {
      used = root.size();
      entry = rootFor_.i64(2);
    }
  }
  if (used == 0) return std::nullopt;
  size_t at = used + 1;
  while (at <= path.size()) {
    size_t slash = path.find('/', at);
    if (slash == std::string::npos) slash = path.size();
    child_.reset().bind(1, entry).bind(2, std::string_view(path).substr(at, slash - at));
    if (!child_.step()) return std::nullopt;
    entry = child_.i64(0);
    at = slash + 1;
  }
  return entry;
}

std::vector<Reader::Hit> Reader::recent(uint32_t limit, std::vector<std::string> &missing) {
  struct Release {
    Reader &r;
    ~Release() { r.release(); }
  } releaseOnExit{*this};
  std::vector<Hit> out;
  std::vector<std::pair<std::string, int64_t>> rows;
  recent_.reset().bind(1, static_cast<int64_t>(limit) * 2 + 8);
  while (recent_.step()) rows.emplace_back(std::string(recent_.text(0)), recent_.i64(1));

  for (auto &[path, openedNs] : rows) {
    if (out.size() >= limit) break;
    Hit h;
    h.path = path;
    h.lastOpenedSeconds = openedNs / 1'000'000'000;
    const size_t slash = path.rfind('/');
    const std::string name = slash == std::string::npos ? path : path.substr(slash + 1);
    if (auto id = entryForPath(path)) {
      // Indexed: answer from the row, even when its disk is unmounted right
      // now — the Windows partition's files are still worth listing.
      h.id = *id;
      h.kind = static_cast<EntryKind>(child_.i64(1));
      h.size = child_.i64(2);
      h.mtimeSeconds = child_.i64(3) / 1'000'000'000;
      h.ext = std::string(child_.text(4));
    } else {
      struct stat st {};
      if (::stat(path.c_str(), &st) != 0) {
        missing.push_back(path);
        continue;
      }
      h.kind = S_ISDIR(st.st_mode) ? EntryKind::directory : EntryKind::file;
      h.size = S_ISDIR(st.st_mode) ? 0 : st.st_size;
      h.mtimeSeconds = st.st_mtim.tv_sec;
      h.ext = S_ISDIR(st.st_mode) ? std::string() : extensionOf(name);
    }
    out.push_back(std::move(h));
  }
  return out;
}

int64_t Reader::countUnder(int64_t root) {
  Stmt s = db_.prepare("SELECT count(*) FROM entry WHERE root = ?1 AND parent IS NOT NULL");
  s.bind(1, root);
  return s.step() ? s.i64(0) : 0;
}

}  // namespace lava::indexer
