#pragma once

// The smallest wrapper over the sqlite3 C API that keeps handles from
// leaking and errors from being ignored. Deliberately not an ORM: the daemon
// runs a dozen statements, each prepared once, and reading them as SQL is
// the point.

#include <sqlite3.h>

#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>

namespace lava::indexer {

class SqliteError : public std::runtime_error {
 public:
  using std::runtime_error::runtime_error;
};

class Stmt {
 public:
  Stmt() = default;
  Stmt(sqlite3 *db, std::string_view sql) : db_(db) {
    if (sqlite3_prepare_v3(db, sql.data(), static_cast<int>(sql.size()),
                           SQLITE_PREPARE_PERSISTENT, &stmt_, nullptr) != SQLITE_OK) {
      throw SqliteError(std::string("prepare: ") + sqlite3_errmsg(db) + " in: " +
                        std::string(sql));
    }
  }
  ~Stmt() { sqlite3_finalize(stmt_); }
  Stmt(const Stmt &) = delete;
  Stmt &operator=(const Stmt &) = delete;
  Stmt(Stmt &&o) noexcept : db_(o.db_), stmt_(o.stmt_) { o.stmt_ = nullptr; }
  Stmt &operator=(Stmt &&o) noexcept {
    if (this != &o) {
      sqlite3_finalize(stmt_);
      db_ = o.db_;
      stmt_ = o.stmt_;
      o.stmt_ = nullptr;
    }
    return *this;
  }

  /// Resets and clears bindings, so a statement reused in a loop never
  /// carries the last iteration's values into this one.
  Stmt &reset() {
    sqlite3_reset(stmt_);
    sqlite3_clear_bindings(stmt_);
    return *this;
  }

  Stmt &bind(int i, int64_t v) {
    check(sqlite3_bind_int64(stmt_, i, v));
    return *this;
  }
  Stmt &bind(int i, std::string_view v) {
    check(sqlite3_bind_text(stmt_, i, v.data(), static_cast<int>(v.size()),
                            SQLITE_TRANSIENT));
    return *this;
  }
  Stmt &bindNull(int i) {
    check(sqlite3_bind_null(stmt_, i));
    return *this;
  }

  /// Ends the statement without clearing its bindings. A statement left on
  /// a row keeps its read transaction open, and on a reader that pins the
  /// snapshot: every later query sees the database as it was then.
  void finish() { sqlite3_reset(stmt_); }

  /// True while there is a row to read.
  bool step() {
    const int rc = sqlite3_step(stmt_);
    if (rc == SQLITE_ROW) return true;
    if (rc == SQLITE_DONE) return false;
    throw SqliteError(std::string("step: ") + sqlite3_errmsg(db_));
  }

  /// Runs a statement that returns no rows.
  void run() {
    while (step()) {
    }
  }

  int64_t i64(int col) const { return sqlite3_column_int64(stmt_, col); }
  bool isNull(int col) const { return sqlite3_column_type(stmt_, col) == SQLITE_NULL; }
  std::string_view text(int col) const {
    const auto *p = reinterpret_cast<const char *>(sqlite3_column_text(stmt_, col));
    return p ? std::string_view(p, static_cast<size_t>(sqlite3_column_bytes(stmt_, col)))
             : std::string_view();
  }

 private:
  void check(int rc) {
    if (rc != SQLITE_OK) throw SqliteError(std::string("bind: ") + sqlite3_errmsg(db_));
  }

  sqlite3 *db_ = nullptr;
  sqlite3_stmt *stmt_ = nullptr;
};

class Db {
 public:
  Db() = default;
  Db(const std::string &path, bool readOnly) {
    const int flags = (readOnly ? SQLITE_OPEN_READONLY
                                : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) |
                      SQLITE_OPEN_NOMUTEX;
    if (sqlite3_open_v2(path.c_str(), &db_, flags, nullptr) != SQLITE_OK) {
      std::string msg = db_ ? sqlite3_errmsg(db_) : "out of memory";
      sqlite3_close(db_);
      db_ = nullptr;
      throw SqliteError("open " + path + ": " + msg);
    }
    // A reader can meet the writer mid-checkpoint; waiting a moment is
    // always better than failing a keystroke's search.
    sqlite3_busy_timeout(db_, 2000);
  }
  ~Db() { sqlite3_close_v2(db_); }
  Db(const Db &) = delete;
  Db &operator=(const Db &) = delete;
  Db(Db &&o) noexcept : db_(o.db_) { o.db_ = nullptr; }
  Db &operator=(Db &&o) noexcept {
    if (this != &o) {
      sqlite3_close_v2(db_);
      db_ = o.db_;
      o.db_ = nullptr;
    }
    return *this;
  }

  void exec(std::string_view sql) {
    char *err = nullptr;
    if (sqlite3_exec(db_, std::string(sql).c_str(), nullptr, nullptr, &err) != SQLITE_OK) {
      std::string msg = err ? err : "unknown";
      sqlite3_free(err);
      throw SqliteError("exec: " + msg);
    }
  }

  Stmt prepare(std::string_view sql) { return Stmt(db_, sql); }
  int64_t lastInsertId() const { return sqlite3_last_insert_rowid(db_); }
  int changes() const { return sqlite3_changes(db_); }
  sqlite3 *raw() const { return db_; }

 private:
  sqlite3 *db_ = nullptr;
};

}  // namespace lava::indexer
