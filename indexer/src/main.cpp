// lava-index: the per-user file index daemon.
//
// Serves `lava.index.Index` (idl/index.npidl) over NPRPC shared memory and
// publishes its reference at $XDG_RUNTIME_DIR/lava-index.ior. One per user:
// a second instance finds the lock taken and exits quietly, which is what
// makes it safe to start from every session's autostart.

#include "gen/index.hpp"
#include "indexer.hpp"
#include "store.hpp"

#include <nprpc/nprpc.hpp>

#include <fcntl.h>
#include <signal.h>
#include <sys/file.h>
#include <unistd.h>

#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <deque>
#include <fstream>
#include <memory>
#include <mutex>
#include <thread>

namespace {

using namespace lava::indexer;
namespace idl = lava::index;

std::string runtimeDir() {
  const char *dir = std::getenv("XDG_RUNTIME_DIR");
  return dir && *dir ? dir : "/tmp";
}

std::string referencePath() {
  if (const char *p = std::getenv("LAVA_INDEX_IOR"); p && *p) return p;
  return runtimeDir() + "/lava-index.ior";
}

int64_t nowSeconds() { return static_cast<int64_t>(std::time(nullptr)); }

/// One subscriber's change stream, written from a thread of its own.
///
/// The compositor's `StreamPump`, cut down to the one case here: a write into
/// a shared-memory ring blocks while the ring is full, and a client that
/// stopped reading must not stop the indexer thread. Coalescing, because
/// "something changed" twice is the same message as once — except that a
/// change to entries is never folded into a recent-only one.
class ChangeWatcher {
 public:
  explicit ChangeWatcher(nprpc::StreamWriter<idl::IndexChanged> &&writer)
      : writer_(std::move(writer)), worker_([this] { run(); }) {}

  ~ChangeWatcher() {
    {
      std::lock_guard lock(mutex_);
      stop_ = true;
    }
    wake_.notify_all();
    worker_.join();
  }

  void post(idl::IndexChanged value) {
    {
      std::lock_guard lock(mutex_);
      if (closed_) return;
      if (pending_) value.recentOnly = value.recentOnly && pending_->recentOnly;
      pending_ = value;
    }
    wake_.notify_one();
  }

  void close() {
    {
      std::lock_guard lock(mutex_);
      closed_ = true;
    }
    wake_.notify_all();
  }

  bool done() {
    std::lock_guard lock(mutex_);
    return closed_;
  }

 private:
  void run() {
    for (;;) {
      idl::IndexChanged value;
      {
        std::unique_lock lock(mutex_);
        wake_.wait(lock, [this] { return stop_ || closed_ || pending_; });
        if (stop_) return;
        if (closed_) {
          writer_.close();
          return;
        }
        value = *pending_;
        pending_.reset();
      }
      if (!writer_.write(value)) {
        std::lock_guard lock(mutex_);
        closed_ = true;
        return;
      }
    }
  }

  std::mutex mutex_;
  std::condition_variable wake_;
  std::optional<idl::IndexChanged> pending_;
  bool closed_ = false, stop_ = false;
  nprpc::StreamWriter<idl::IndexChanged> writer_;
  std::thread worker_;
};

class ChangeBroker {
 public:
  void subscribe(const std::shared_ptr<ChangeWatcher> &w) {
    std::lock_guard lock(mutex_);
    watchers_.push_back(w);
  }
  void unsubscribe(const std::shared_ptr<ChangeWatcher> &w) {
    std::lock_guard lock(mutex_);
    std::erase(watchers_, w);
  }
  void broadcast(bool recentOnly) {
    std::lock_guard lock(mutex_);
    idl::IndexChanged msg{};
    msg.serial = ++serial_;
    msg.recentOnly = recentOnly;
    std::erase_if(watchers_, [](const auto &w) { return w->done(); });
    for (const auto &w : watchers_) w->post(msg);
  }

 private:
  std::mutex mutex_;
  std::vector<std::shared_ptr<ChangeWatcher>> watchers_;
  uint32_t serial_ = 0;
};

idl::Hit toWire(Reader::Hit &&h) {
  idl::Hit out{};
  out.id = static_cast<uint64_t>(h.id);
  out.path = std::move(h.path);
  out.kind = static_cast<idl::EntryKind>(h.kind);
  out.size = static_cast<uint64_t>(h.size);
  out.mtime = h.mtimeSeconds;
  out.ext = std::move(h.ext);
  out.matchStart = h.matchStart;
  out.matchLength = h.matchLength;
  out.lastOpened = h.lastOpenedSeconds;
  return out;
}

class IndexServant final : public idl::IIndex_Servant {
 public:
  IndexServant(Indexer &indexer, ChangeBroker &broker, std::string dbPath)
      : indexer_(indexer), broker_(broker), dbPath_(std::move(dbPath)) {}

  idl::SearchResult Search(nprpc::flat::Span<char> query, idl::Category category,
                           uint32_t limit) override {
    idl::SearchResult out{};
    out.truncated = false;
    try {
      auto result = reader().search(std::string(query.begin(), query.end()),
                                    static_cast<Kind>(category), std::min(limit, 100u),
                                    nowSeconds());
      out.truncated = result.truncated;
      out.hits.reserve(result.hits.size());
      for (auto &h : result.hits) out.hits.push_back(toWire(std::move(h)));
    } catch (const std::exception &e) {
      // A search that fails is an empty result and a line on stderr, never
      // an exception at a client that is only typing.
      std::fprintf(stderr, "lava-index: search failed: %s\n", e.what());
    }
    return out;
  }

  std::vector<idl::Hit> Recent(uint32_t limit) override {
    std::vector<idl::Hit> out;
    try {
      std::vector<std::string> missing;
      auto hits = reader().recent(std::min(limit, 100u), missing);
      indexer_.forgetRecent(std::move(missing));
      for (auto &h : hits) out.push_back(toWire(std::move(h)));
    } catch (const std::exception &e) {
      std::fprintf(stderr, "lava-index: recent failed: %s\n", e.what());
    }
    return out;
  }

  void NoteOpened(nprpc::flat::Span<char> path, nprpc::flat::Span<char> appId) override {
    std::string p(path.begin(), path.end());
    if (p.empty() || p[0] != '/') return;
    indexer_.noteOpened(p, std::string(appId.begin(), appId.end()));
  }

  idl::IndexStatus Status() override {
    idl::IndexStatus out{};
    for (const RootState &r : indexer_.status()) {
      idl::RootStatus s{};
      s.path = r.path;
      s.online = r.online;
      s.watched = r.watched;
      s.scanning = r.scanning;
      try {
        s.entries = static_cast<uint64_t>(reader().countUnder(r.id));
      } catch (const std::exception &) {
        s.entries = 0;
      }
      s.lastReconcile = r.lastReconcileNs / 1'000'000'000;
      out.roots.push_back(std::move(s));
    }
    return out;
  }

  void Rescan(nprpc::flat::Span<char> path) override {
    const std::string p(path.begin(), path.end());
    if (!indexer_.requestRescan(p)) throw idl::RootNotFound(p);
  }

  nprpc::Task<> SubscribeChanges(
      nprpc::BidiStream<idl::IndexChangedAck, idl::IndexChanged> stream) override {
    auto watcher = std::make_shared<ChangeWatcher>(std::move(stream.writer));
    broker_.subscribe(watcher);
    try {
      while (auto ack = co_await stream.reader) {
        (void)ack;
      }
    } catch (...) {
      broker_.unsubscribe(watcher);
      watcher->close();
      throw;
    }
    broker_.unsubscribe(watcher);
    watcher->close();
    co_return;
  }

 private:
  // One read-only connection per RPC thread: SQLite connections are not to
  // be shared across threads, and a pool of them is a mutex this does not
  // need.
  Reader &reader() {
    thread_local std::unique_ptr<Reader> r;
    if (!r) r = std::make_unique<Reader>(dbPath_);
    return *r;
  }

  Indexer &indexer_;
  ChangeBroker &broker_;
  std::string dbPath_;
};

}  // namespace

int main(int argc, char **argv) {
  for (int i = 1; i < argc; ++i) {
    const std::string a = argv[i];
    if (a == "--help" || a == "-h") {
      std::printf(
          "usage: lava-index\n"
          "  config   %s\n"
          "  database %s\n"
          "  ior      %s\n"
          "env: LAVA_INDEX_CONFIG, LAVA_INDEX_DB, LAVA_INDEX_IOR\n",
          defaultConfigPath().c_str(), defaultDatabasePath().c_str(), referencePath().c_str());
      return 0;
    }
  }

  // One daemon per user. The lock lives as long as the process, and the
  // kernel drops it when the process dies, however it dies.
  const std::string iorPath = referencePath();
  const std::string lockPath = iorPath + ".lock";
  const int lockFd = ::open(lockPath.c_str(), O_RDWR | O_CREAT | O_CLOEXEC, 0600);
  if (lockFd < 0 || ::flock(lockFd, LOCK_EX | LOCK_NB) != 0) {
    std::fprintf(stderr, "lava-index: already running (%s is locked)\n", lockPath.c_str());
    return 0;
  }

  // Blocked before any thread exists, so every thread inherits the mask and
  // only `sigwait` below ever sees these.
  sigset_t signals;
  sigemptyset(&signals);
  sigaddset(&signals, SIGINT);
  sigaddset(&signals, SIGTERM);
  pthread_sigmask(SIG_BLOCK, &signals, nullptr);

  const std::string configPath = defaultConfigPath();
  const std::string dbPath = defaultDatabasePath();
  Config config = loadConfig(configPath);
  std::fprintf(stderr, "lava-index: %zu roots, database %s\n", config.roots.size(),
               dbPath.c_str());
  for (const auto &r : config.roots) std::fprintf(stderr, "lava-index:   %s\n", r.c_str());

  ChangeBroker broker;
  Indexer indexer(std::move(config), dbPath,
                  [&broker](bool recentOnly) { broker.broadcast(recentOnly); }, configPath);
  try {
    indexer.start();
  } catch (const std::exception &e) {
    std::fprintf(stderr, "lava-index: cannot open the index: %s\n", e.what());
    return 1;
  }

  nprpc::Rpc *rpc = nprpc::RpcBuilder().set_log_level(nprpc::LogLevel::warn).build();
  if (rpc == nullptr) {
    std::fprintf(stderr, "lava-index: could not build the RPC runtime\n");
    return 1;
  }
  rpc->start_thread_pool(4);
  // No executor: calls run on the pool, off the transport thread. A search
  // is milliseconds and must not hold up the ring every client shares.
  nprpc::Poa *poa = rpc->create_poa()
                        .with_max_objects(1)
                        .with_lifespan(nprpc::PoaPolicy::Lifespan::Persistent)
                        .with_object_id_policy(nprpc::PoaPolicy::ObjectIdPolicy::UserSupplied)
                        .with_transport_affinity(
                            nprpc::PoaPolicy::TransportAffinity::NeverBlockTransport)
                        .build();
  if (poa == nullptr) {
    std::fprintf(stderr, "lava-index: could not create a POA\n");
    return 1;
  }
  IndexServant servant(indexer, broker, dbPath);
  const nprpc::ObjectId oid =
      poa->activate_object_with_id(0, &servant, nprpc::ObjectActivationFlags::shm);

  // Written beside and renamed over, so a client never reads half a line.
  {
    const std::string tmp = iorPath + ".tmp";
    std::ofstream file(tmp, std::ios::trunc);
    file << oid.to_string();
    file.close();
    if (!file || std::rename(tmp.c_str(), iorPath.c_str()) != 0) {
      std::fprintf(stderr, "lava-index: cannot write %s\n", iorPath.c_str());
      return 1;
    }
  }
  std::fprintf(stderr, "lava-index: listening, reference at %s\n", iorPath.c_str());

  int sig = 0;
  sigwait(&signals, &sig);
  std::fprintf(stderr, "lava-index: stopping\n");
  std::remove(iorPath.c_str());
  rpc->destroy();
  indexer.stop();
  return 0;
}
