#include "indexer.hpp"

#include "mounts.hpp"
#include "store.hpp"
#include "xbel.hpp"

#include <dirent.h>
#include <fcntl.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/inotify.h>
#include <sys/stat.h>
#include <sys/timerfd.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <deque>
#include <fstream>
#include <mutex>
#include <optional>
#include <sstream>
#include <thread>
#include <unordered_map>

namespace lava::indexer {

namespace {

int64_t nowNs() {
  timespec ts{};
  clock_gettime(CLOCK_REALTIME, &ts);
  return static_cast<int64_t>(ts.tv_sec) * 1'000'000'000 + ts.tv_nsec;
}

using Clock = std::chrono::steady_clock;

// What a directory watch listens for. Not IN_MODIFY: it fires on every write
// of a file being written, and CLOSE_WRITE says the same thing once.
// IN_ATTRIB catches `touch`, and a size change made through truncate.
constexpr uint32_t kWatchMask = IN_CREATE | IN_DELETE | IN_MOVED_FROM | IN_MOVED_TO |
                                IN_CLOSE_WRITE | IN_ATTRIB | IN_DELETE_SELF | IN_ONLYDIR |
                                IN_DONT_FOLLOW | IN_EXCL_UNLINK;

// How long a write transaction stays open during a crawl before readers get
// to see what it found, and how long after a change the change is announced.
constexpr auto kCommitEvery = std::chrono::milliseconds(250);
constexpr int kNotifyAfterMs = 250;

std::optional<Row> statEntry(int dirfd, const char *name) {
  struct statx sx {};
  // DONT_SYNC: on FUSE (ntfs-3g) and network filesystems, a plain statx may
  // round-trip to the backing store for attributes the kernel already has.
  if (statx(dirfd, name, AT_SYMLINK_NOFOLLOW | AT_STATX_DONT_SYNC,
            STATX_TYPE | STATX_SIZE | STATX_MTIME | STATX_INO, &sx) != 0) {
    return std::nullopt;
  }
  Row row;
  row.name = name;
  if (S_ISDIR(sx.stx_mode)) row.kind = EntryKind::directory;
  else if (S_ISREG(sx.stx_mode)) row.kind = EntryKind::file;
  else if (S_ISLNK(sx.stx_mode)) row.kind = EntryKind::symlink;
  else return std::nullopt;  // fifos, sockets, devices: not files anybody searches for
  row.size = row.kind == EntryKind::file ? static_cast<int64_t>(sx.stx_size) : 0;
  row.mtimeNs = static_cast<int64_t>(sx.stx_mtime.tv_sec) * 1'000'000'000 + sx.stx_mtime.tv_nsec;
  row.ino = static_cast<int64_t>(sx.stx_ino);
  return row;
}

// A directory that is itself a mount point is listed but not entered: a root
// is one filesystem, the way `find -xdev` is. Whatever is mounted inside one
// can be a root of its own.
bool isMountRoot(int dirfd, const char *name) {
  struct statx sx {};
  if (statx(dirfd, name, AT_SYMLINK_NOFOLLOW | AT_STATX_DONT_SYNC, STATX_TYPE, &sx) != 0)
    return false;
  return (sx.stx_attributes_mask & STATX_ATTR_MOUNT_ROOT) &&
         (sx.stx_attributes & STATX_ATTR_MOUNT_ROOT);
}

bool sameMetadata(const Row &a, const Row &b) {
  return a.kind == b.kind && a.size == b.size && a.mtimeNs == b.mtimeNs && a.ino == b.ino;
}

}  // namespace

struct Indexer::Impl {
  Config config;
  std::string dbPath;
  ChangeFn onChange;

  std::thread thread;
  std::atomic<bool> stopping{false};
  int epollFd = -1, inotifyFd = -1, wakeFd = -1, timerFd = -1, mountsFd = -1;

  // ── shared with RPC threads ──
  mutable std::mutex mutex;
  std::vector<RootState> roots;  // guarded; the thread works on its own copy below
  struct Command {
    enum Kind { Rescan, Opened, Forget } kind;
    std::string a, b;
    std::vector<std::string> paths;
  };
  std::deque<Command> commands;
  bool settled = false;

  // ── indexer thread only ──
  std::optional<Store> store;
  struct Root {
    RootState state;
    std::string identity;    // the filesystem it was found on, this run
    bool readOnly = false;
    bool mismatched = false;  // a different filesystem is at the path
    bool pending = false;     // a reconcile is queued
  };
  std::vector<Root> live;
  std::deque<size_t> reconcileQueue;

  struct Watch {
    int64_t dir;
    size_t root;
  };
  std::unordered_map<int, Watch> byWd;
  std::unordered_map<int64_t, int> byDir;
  bool watchLimitReported = false;

  int xbelWd = -1;
  std::string xbelPath, xbelName;

  bool inTx = false;
  Clock::time_point txStarted;
  bool entriesChanged = false, recentChanged = false, timerArmed = false;
  Clock::time_point lastNotify;

  // ── lifecycle ──

  void run() {
    try {
      setup();
      loop();
    } catch (const std::exception &e) {
      std::fprintf(stderr, "lava-index: indexer thread stopped: %s\n", e.what());
    }
    if (inTx) {
      try {
        store->commit();
      } catch (...) {
      }
    }
  }

  void setup() {
    const auto ids = store->syncRoots(config.roots);
    for (const std::string &p : config.roots) {
      Root r;
      r.state.id = ids.at(p);
      r.state.path = p;
      live.push_back(std::move(r));
    }

    epollFd = epoll_create1(EPOLL_CLOEXEC);
    inotifyFd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    timerFd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    mountsFd = ::open("/proc/self/mountinfo", O_RDONLY | O_CLOEXEC);
    addToEpoll(inotifyFd, EPOLLIN);
    addToEpoll(wakeFd, EPOLLIN);
    addToEpoll(timerFd, EPOLLIN);
    // The mount table signals a change as an exceptional condition, not as
    // readable data: EPOLLPRI, the same way systemd watches it.
    if (mountsFd >= 0) addToEpoll(mountsFd, EPOLLPRI);

    xbelPath = defaultXbelPath();
    const size_t slash = xbelPath.rfind('/');
    xbelName = xbelPath.substr(slash + 1);
    // The directory, not the file: GTK replaces it by rename, and a watch on
    // the old inode would hear nothing after the first save.
    xbelWd = inotify_add_watch(inotifyFd, xbelPath.substr(0, slash).c_str(),
                               IN_CLOSE_WRITE | IN_MOVED_TO | IN_ONLYDIR);
    importXbel();

    checkRoots(true);
    publish();
  }

  void addToEpoll(int fd, uint32_t events) {
    epoll_event ev{};
    ev.events = events;
    ev.data.fd = fd;
    epoll_ctl(epollFd, EPOLL_CTL_ADD, fd, &ev);
  }

  void loop() {
    while (!stopping) {
      // Reconciles run between polls, one root at a time, so commands and
      // events get a look in between roots even when there are several.
      const bool busy = !reconcileQueue.empty();
      if (!busy) {
        std::lock_guard lock(mutex);
        settled = true;
      }
      epoll_event events[8];
      const int n = epoll_wait(epollFd, events, 8, busy ? 0 : -1);
      for (int i = 0; i < n; ++i) {
        const int fd = events[i].data.fd;
        if (fd == inotifyFd) readEvents();
        else if (fd == wakeFd) {
          uint64_t v;
          (void)::read(wakeFd, &v, sizeof v);
          drainCommands();
        } else if (fd == timerFd) {
          uint64_t v;
          (void)::read(timerFd, &v, sizeof v);
          timerArmed = false;
          announce();
        } else if (fd == mountsFd) {
          checkRoots(false);
        }
      }
      if (stopping) break;
      if (!reconcileQueue.empty()) {
        const size_t r = reconcileQueue.front();
        reconcileQueue.pop_front();
        reconcile(r);
      }
    }
  }

  // ── transactions and announcements ──

  void beginTx() {
    if (inTx) return;
    store->begin();
    inTx = true;
    txStarted = Clock::now();
  }

  void commitTx() {
    if (!inTx) return;
    store->commit();
    inTx = false;
  }

  // During a long walk: let readers see progress, and let a waiting client
  // hear about it, without giving up the walk.
  void maybeCommit() {
    if (!inTx || Clock::now() - txStarted < kCommitEvery) return;
    commitTx();
    beginTx();
    if (entriesChanged && Clock::now() - lastNotify > std::chrono::milliseconds(kNotifyAfterMs))
      announce();
  }

  void markChanged(bool entries) {
    (entries ? entriesChanged : recentChanged) = true;
    if (timerArmed) return;
    itimerspec spec{};
    spec.it_value.tv_nsec = kNotifyAfterMs * 1'000'000;
    timerfd_settime(timerFd, 0, &spec, nullptr);
    timerArmed = true;
  }

  void announce() {
    if (!entriesChanged && !recentChanged) return;
    const bool recentOnly = !entriesChanged;
    entriesChanged = recentChanged = false;
    lastNotify = Clock::now();
    if (onChange) onChange(recentOnly);
  }

  void publish() {
    std::lock_guard lock(mutex);
    roots.clear();
    for (const Root &r : live) roots.push_back(r.state);
  }

  // ── roots and mounts ──

  void checkRoots(bool initial) {
    const std::vector<MountInfo> mounts = readMounts();
    for (size_t i = 0; i < live.size(); ++i) {
      Root &r = live[i];
      struct stat st {};
      const bool exists = ::stat(r.state.path.c_str(), &st) == 0 && S_ISDIR(st.st_mode) &&
                          ::access(r.state.path.c_str(), R_OK | X_OK) == 0;
      const MountInfo *m = mountFor(mounts, r.state.path);
      const std::string identity = m ? m->identity() : std::string();
      const bool readOnly = m && m->readOnly;
      const bool wasOnline = r.state.online, wasReadOnly = r.readOnly;

      if (!exists) {
        goOffline(i, "not there");
        continue;
      }
      const std::string stored = store->rootFilesystem(r.state.id);
      if (stored.empty()) {
        store->setRootFilesystem(r.state.id, identity);
      } else if (stored != identity) {
        if (!r.mismatched) {
          std::fprintf(stderr,
                       "lava-index: %s is on '%s' now, indexed from '%s'; leaving it offline "
                       "(an unmounted mount point looks like this — Rescan adopts a new disk)\n",
                       r.state.path.c_str(), identity.c_str(), stored.c_str());
        }
        r.mismatched = true;
        goOffline(i, nullptr);
        continue;
      }
      r.mismatched = false;
      r.identity = identity;
      r.readOnly = readOnly;
      r.state.online = true;
      const bool watch = !readOnly;
      if (!watch && r.state.watched) dropRootWatches(i);
      r.state.watched = watch;
      // A root that appeared, or changed between read-only and writable,
      // may have changed underneath us in ways no event reported.
      if (initial || !wasOnline || wasReadOnly != readOnly) queueReconcile(i);
    }
    publish();
  }

  void goOffline(size_t i, const char *why) {
    Root &r = live[i];
    if (r.state.online && why)
      std::fprintf(stderr, "lava-index: %s is offline (%s)\n", r.state.path.c_str(), why);
    dropRootWatches(i);
    r.state.online = false;
    r.state.watched = false;
  }

  void queueReconcile(size_t i) {
    if (live[i].pending) return;
    live[i].pending = true;
    reconcileQueue.push_back(i);
    std::lock_guard lock(mutex);
    settled = false;
  }

  // ── watches ──

  void addWatch(const std::string &path, int64_t dir, size_t root) {
    const int wd = inotify_add_watch(inotifyFd, path.c_str(), kWatchMask);
    if (wd < 0) {
      if (errno == ENOSPC && !watchLimitReported) {
        std::fprintf(stderr,
                     "lava-index: out of inotify watches at %s; raise "
                     "fs.inotify.max_user_watches. Changes below here are seen only on "
                     "the next reconcile\n",
                     path.c_str());
        watchLimitReported = true;
      }
      return;
    }
    // inotify hands back the same wd for the same inode; a directory reached
    // twice (a bind mount) keeps its latest identity.
    if (auto it = byWd.find(wd); it != byWd.end()) byDir.erase(it->second.dir);
    byWd[wd] = {dir, root};
    byDir[dir] = wd;
  }

  void dropWatch(int64_t dir) {
    auto it = byDir.find(dir);
    if (it == byDir.end()) return;
    inotify_rm_watch(inotifyFd, it->second);
    byWd.erase(it->second);
    byDir.erase(it);
  }

  void dropRootWatches(size_t root) {
    for (auto it = byWd.begin(); it != byWd.end();) {
      if (it->second.root == root) {
        inotify_rm_watch(inotifyFd, it->first);
        byDir.erase(it->second.dir);
        it = byWd.erase(it);
      } else {
        ++it;
      }
    }
  }

  // Removes a row, and first the watches of every directory the delete will
  // cascade through — the kernel would drop them too, but only once the
  // directories are really gone, and a moved-away tree is not gone.
  void removeEntry(const Row &row) {
    if (row.kind == EntryKind::directory) {
      for (int64_t d : store->descendantDirectories(row.id)) dropWatch(d);
      dropWatch(row.id);
    }
    store->remove(row.id);
    entriesChanged = true;
  }

  // ── the walk ──

  /// Lists one directory and makes its rows match. New and still-present
  /// subdirectories are appended to `next` to be walked in turn.
  void syncDirectory(size_t root, int64_t dir, const std::string &path,
                     std::vector<std::pair<int64_t, std::string>> &next) {
    const int fd = ::open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return;  // unreadable or gone: its parent's listing decides
    DIR *d = fdopendir(fd);
    if (d == nullptr) {
      ::close(fd);
      return;
    }
    std::unordered_map<std::string, Row> existing;
    for (Row &r : store->children(dir)) existing.emplace(r.name, std::move(r));

    const int64_t rootId = live[root].state.id;
    while (dirent *de = readdir(d)) {
      const char *name = de->d_name;
      if (std::strcmp(name, ".") == 0 || std::strcmp(name, "..") == 0) continue;
      if (config.excluded(name)) continue;
      std::optional<Row> disk = statEntry(fd, name);
      if (!disk) continue;
      int64_t id;
      auto it = existing.find(disk->name);
      if (it == existing.end()) {
        id = store->insert(dir, rootId, *disk);
        entriesChanged = true;
      } else if (it->second.kind != disk->kind) {
        removeEntry(it->second);
        existing.erase(it);
        id = store->insert(dir, rootId, *disk);
      } else {
        id = it->second.id;
        if (!sameMetadata(it->second, *disk)) {
          disk->id = id;
          store->update(*disk);
          entriesChanged = true;
        }
        existing.erase(it);
      }
      if (disk->kind == EntryKind::directory && !isMountRoot(fd, name))
        next.emplace_back(id, path + "/" + disk->name);
    }
    closedir(d);
    // What is left was in the index and is not on disk.
    for (auto &[name, row] : existing) removeEntry(row);
  }

  /// Walks a tree from `dir` down, watching each directory before listing it
  /// so nothing created in between is missed.
  void walk(size_t root, int64_t dir, const std::string &path) {
    std::vector<std::pair<int64_t, std::string>> stack{{dir, path}};
    while (!stack.empty() && !stopping) {
      auto [id, p] = std::move(stack.back());
      stack.pop_back();
      if (live[root].state.watched) addWatch(p, id, root);
      syncDirectory(root, id, p, stack);
      maybeCommit();
    }
  }

  void reconcile(size_t i) {
    Root &r = live[i];
    r.pending = false;
    if (!r.state.online) return;
    r.state.scanning = true;
    publish();
    const auto started = Clock::now();
    beginTx();
    const int64_t top = store->rootEntry(r.state.id, r.state.path);
    walk(i, top, r.state.path);
    if (!stopping) {
      r.state.lastReconcileNs = nowNs();
      store->setReconciled(r.state.id, r.state.lastReconcileNs);
    }
    commitTx();
    r.state.scanning = false;
    publish();
    if (entriesChanged) markChanged(true);
    std::fprintf(stderr, "lava-index: reconciled %s in %.2f s\n", r.state.path.c_str(),
                 std::chrono::duration<double>(Clock::now() - started).count());
  }

  // ── inotify ──

  struct Event {
    int wd;
    uint32_t mask;
    uint32_t cookie;
    std::string name;
  };

  void readEvents() {
    std::vector<Event> batch;
    alignas(inotify_event) char buf[64 * 1024];
    for (;;) {
      const ssize_t n = ::read(inotifyFd, buf, sizeof buf);
      if (n <= 0) break;
      for (ssize_t at = 0; at < n;) {
        const auto *ev = reinterpret_cast<const inotify_event *>(buf + at);
        batch.push_back({ev->wd, ev->mask, ev->cookie, ev->len ? std::string(ev->name) : ""});
        at += static_cast<ssize_t>(sizeof(inotify_event) + ev->len);
      }
    }
    if (!batch.empty()) applyEvents(batch);
  }

  void applyEvents(const std::vector<Event> &batch) {
    beginTx();
    struct From {
      int64_t dir;
      std::string name;
      size_t root;
    };
    std::unordered_map<uint32_t, From> movedFrom;
    bool xbelDirty = false;

    for (const Event &ev : batch) {
      if (ev.mask & IN_Q_OVERFLOW) {
        std::fprintf(stderr, "lava-index: inotify queue overflowed; reconciling\n");
        for (size_t i = 0; i < live.size(); ++i)
          if (live[i].state.watched) queueReconcile(i);
        continue;
      }
      if (ev.wd == xbelWd && ev.name == xbelName) xbelDirty = true;
      auto w = byWd.find(ev.wd);
      if (w == byWd.end()) continue;
      if (ev.mask & IN_IGNORED) {
        byDir.erase(w->second.dir);
        byWd.erase(w);
        continue;
      }
      const auto [dir, root] = w->second;
      if (ev.mask & IN_DELETE_SELF) {
        // A root's own directory going is a mount-table question; anything
        // deeper is handled by its parent's IN_DELETE.
        continue;
      }
      if (ev.name.empty() || config.excluded(ev.name)) continue;

      if (ev.mask & IN_MOVED_FROM) {
        movedFrom[ev.cookie] = {dir, ev.name, root};
        continue;
      }
      if (ev.mask & IN_MOVED_TO) {
        if (auto from = movedFrom.extract(ev.cookie); !from.empty()) {
          const From &f = from.mapped();
          if (f.root == root) {
            if (auto row = store->lookup(f.dir, f.name)) {
              if (auto there = store->lookup(dir, ev.name); there && there->id != row->id)
                removeEntry(*there);
              store->move(row->id, dir, ev.name);
              entriesChanged = true;
              // Metadata can change with a rename (ctime aside, a file
              // replaced by rename-over is a different file).
              refresh(root, dir, ev.name);
              continue;
            }
          } else if (auto row = store->lookup(f.dir, f.name)) {
            // Between roots: the subtree's `root` column is wrong wholesale.
            // Rare enough to pay for as a delete and a fresh walk.
            removeEntry(*row);
          }
        }
        refresh(root, dir, ev.name);
        continue;
      }
      if (ev.mask & IN_DELETE) {
        if (auto row = store->lookup(dir, ev.name)) removeEntry(*row);
        continue;
      }
      if (ev.mask & (IN_CREATE | IN_CLOSE_WRITE | IN_ATTRIB)) refresh(root, dir, ev.name);
    }
    // A move whose other half never arrived left the watched trees.
    for (auto &[cookie, f] : movedFrom) {
      if (auto row = store->lookup(f.dir, f.name)) removeEntry(*row);
    }
    if (xbelDirty) importXbel();
    commitTx();
    if (entriesChanged) markChanged(true);
  }

  /// Makes one name's row match the disk: insert, update, or remove.
  /// A new directory is walked, which also puts watches on it.
  void refresh(size_t root, int64_t dir, const std::string &name) {
    const std::optional<std::string> dirPath = store->pathOf(dir);
    if (!dirPath) return;
    const int fd = ::open(dirPath->c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    std::optional<Row> disk = fd >= 0 ? statEntry(fd, name.c_str()) : std::nullopt;
    const bool mountRoot = fd >= 0 && disk && isMountRoot(fd, name.c_str());
    if (fd >= 0) ::close(fd);
    std::optional<Row> row = store->lookup(dir, name);

    if (!disk) {
      if (row) removeEntry(*row);
      return;
    }
    if (row && row->kind != disk->kind) {
      removeEntry(*row);
      row.reset();
    }
    int64_t id;
    if (row) {
      id = row->id;
      if (!sameMetadata(*row, *disk)) {
        disk->id = id;
        store->update(*disk);
        entriesChanged = true;
      }
    } else {
      id = store->insert(dir, live[root].state.id, *disk);
      entriesChanged = true;
    }
    // Walked even when it was already known: a directory moved in from
    // outside every watched tree arrives with contents nobody has listed.
    if (disk->kind == EntryKind::directory && !mountRoot && !byDir.count(id))
      walk(root, id, *dirPath + "/" + name);
  }

  // ── recent ──

  void importXbel() {
    std::ifstream in(xbelPath);
    if (!in) return;
    std::stringstream text;
    text << in.rdbuf();
    const bool own = !inTx;
    if (own) beginTx();
    for (const RecentFile &f : parseXbel(text.str())) store->noteOpened(f.path, f.lastOpenNs, "xbel", false);
    if (own) commitTx();
    markChanged(false);
  }

  void drainCommands() {
    std::deque<Command> work;
    {
      std::lock_guard lock(mutex);
      work.swap(commands);
    }
    if (work.empty()) return;
    beginTx();
    for (Command &c : work) {
      switch (c.kind) {
        case Command::Rescan:
          for (size_t i = 0; i < live.size(); ++i) {
            if (live[i].state.path != c.a) continue;
            // An explicit rescan is the user saying "this is the disk now".
            if (live[i].mismatched) {
              std::fprintf(stderr, "lava-index: adopting the filesystem now at %s\n",
                           c.a.c_str());
              store->clearRoot(live[i].state.id);
              store->setRootFilesystem(live[i].state.id, "");
              entriesChanged = true;
            }
          }
          break;
        case Command::Opened:
          store->noteOpened(c.a, nowNs(), c.b, true);
          markChanged(false);
          break;
        case Command::Forget:
          for (const auto &p : c.paths) store->forgetRecent(p);
          markChanged(false);
          break;
      }
    }
    commitTx();
    // After the commit: a cleared root's identity is re-read from disk here.
    for (const Command &c : work) {
      if (c.kind != Command::Rescan) continue;
      checkRoots(false);
      for (size_t i = 0; i < live.size(); ++i)
        if (live[i].state.path == c.a) queueReconcile(i);
    }
    if (entriesChanged) markChanged(true);
  }

  void post(Command c) {
    {
      std::lock_guard lock(mutex);
      commands.push_back(std::move(c));
    }
    const uint64_t one = 1;
    (void)::write(wakeFd, &one, sizeof one);
  }
};

Indexer::Indexer(Config config, std::string dbPath, ChangeFn onChange) : impl_(new Impl) {
  impl_->config = std::move(config);
  impl_->dbPath = std::move(dbPath);
  impl_->onChange = std::move(onChange);
}

Indexer::~Indexer() {
  stop();
  for (int fd : {impl_->epollFd, impl_->inotifyFd, impl_->wakeFd, impl_->timerFd,
                 impl_->mountsFd}) {
    if (fd >= 0) ::close(fd);
  }
  delete impl_;
}

void Indexer::start() {
  impl_->store.emplace(impl_->dbPath);
  impl_->wakeFd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  impl_->thread = std::thread([this] { impl_->run(); });
}

void Indexer::stop() {
  if (!impl_->thread.joinable()) return;
  impl_->stopping = true;
  const uint64_t one = 1;
  (void)::write(impl_->wakeFd, &one, sizeof one);
  impl_->thread.join();
}

bool Indexer::requestRescan(const std::string &path) {
  const std::string root = normalizeRoot(path);
  {
    std::lock_guard lock(impl_->mutex);
    bool known = false;
    for (const auto &r : impl_->roots) known = known || r.path == root;
    if (!known) return false;
  }
  impl_->post({Impl::Command::Rescan, root, {}, {}});
  return true;
}

void Indexer::noteOpened(const std::string &path, const std::string &appId) {
  impl_->post({Impl::Command::Opened, path, appId, {}});
}

void Indexer::forgetRecent(std::vector<std::string> paths) {
  if (paths.empty()) return;
  impl_->post({Impl::Command::Forget, {}, {}, std::move(paths)});
}

std::vector<RootState> Indexer::status() const {
  std::lock_guard lock(impl_->mutex);
  return impl_->roots;
}

bool Indexer::idle() const {
  std::lock_guard lock(impl_->mutex);
  return impl_->settled;
}

}  // namespace lava::indexer
