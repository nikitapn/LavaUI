#include "control_plane.hpp"

#include <sys/eventfd.h>
#include <unistd.h>

#include <condition_variable>
#include <deque>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <thread>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

#include <wayland-server-core.h>

#include "gen/lava.hpp"
#include "render/draw_command.hpp"
#include "wlr.hpp"

namespace lava {
namespace {

/// The compositor's Wayland event loop, as somewhere work can be sent.
///
/// Nothing the compositor owns is thread-safe — wlroots least of all, and the
/// Vulkan device behind canvas not much more — so anything arriving on an RPC
/// thread has to reach the loop before it touches any of it. An eventfd
/// registered as a loop source is how: enqueue, write a byte, and the loop
/// wakes and drains.
///
/// The same shape as LavaUI's `MainQueue`, which
/// is not a coincidence — every one of those exists because a renderer's state
/// belongs to one thread and its inputs do not.
class LoopQueue {
 public:
  bool start(wl_event_loop *loop) {
    loopThread_ = std::this_thread::get_id();
    fd_ = ::eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (fd_ < 0) return false;
    source_ = wl_event_loop_add_fd(loop, fd_, WL_EVENT_READABLE, on_readable,
                                   this);
    return source_ != nullptr;
  }

  ~LoopQueue() {
    if (source_) wl_event_source_remove(source_);
    if (fd_ >= 0) ::close(fd_);
  }

  /// Safe from any thread.
  void post(std::function<void()> work) {
    {
      std::lock_guard lock(mutex_);
      pending_.push_back(std::move(work));
    }
    // Outside the lock: the write wakes the loop, and holding a lock across it
    // would let an RPC thread block on the loop's own use of the same lock.
    const uint64_t one = 1;
    [[maybe_unused]] ssize_t ignored = ::write(fd_, &one, sizeof(one));
  }

  bool onLoopThread() const {
    return std::this_thread::get_id() == loopThread_;
  }

 private:
  static int on_readable(int fd, uint32_t, void *data) {
    uint64_t count = 0;
    [[maybe_unused]] ssize_t ignored = ::read(fd, &count, sizeof(count));
    static_cast<LoopQueue *>(data)->drain();
    return 0;
  }

  void drain() {
    std::vector<std::function<void()>> work;
    {
      std::lock_guard lock(mutex_);
      work.swap(pending_);
    }
    // Outside the lock, so work that posts more work does not deadlock.
    for (auto &item : work) item();
  }

  int fd_ = -1;
  wl_event_source *source_ = nullptr;
  std::mutex mutex_;
  std::vector<std::function<void()>> pending_;
  std::thread::id loopThread_{};
};

/// One subscriber's outbound stream, with a thread of its own.
///
/// The rule this exists to enforce: **a client can only ever hurt itself**. A
/// write into a shared-memory ring waits when the ring is full, and a client
/// that has stopped reading — usually because it crashed a moment ago and its
/// session has not been reaped yet — never drains one. Anywhere that write
/// happens on a thread somebody else depends on, one dead shell stops the
/// desktop: on the Wayland loop it stops every client's calls, and on a broker
/// thread shared between subscribers it stops the *other* shells from being
/// told anything.
///
/// So every subscription owns a thread and a queue. `post` is what the rest of
/// the compositor calls, and it takes a lock, appends, and returns.
///
/// `Coalesce` says what to do when the queue is not empty: state messages —
/// the focused window, the window list — keep only the newest, because an
/// older one is simply wrong. Events do not merge, because each is a fact and
/// dropping one loses a keystroke.
template <typename T, bool Coalesce>
class StreamPump {
 public:
  explicit StreamPump(nprpc::StreamWriter<T> &&writer)
      : writer_(std::move(writer)), worker_([this] { run(); }) {}

  ~StreamPump() {
    {
      std::lock_guard lock(mutex_);
      stop_ = true;
    }
    wake_.notify_all();
    worker_.join();
  }

  StreamPump(const StreamPump &) = delete;
  StreamPump &operator=(const StreamPump &) = delete;

  /// Queues one message. Never writes, and therefore never blocks.
  void post(T value) {
    {
      std::lock_guard lock(mutex_);
      if (closed_) return;
      if constexpr (Coalesce) {
        queue_.clear();
      } else if (queue_.size() >= kMaxQueued) {
        // Deep enough that a busy frame never trims, shallow enough that a
        // client which stopped reading cannot cost real memory. The oldest
        // goes, because the newest events are the ones still worth having.
        queue_.pop_front();
      }
      queue_.push_back(std::move(value));
    }
    wake_.notify_one();
  }

  /// Ends the stream. Safe to call twice — a surface can end from either side.
  void close() {
    {
      std::lock_guard lock(mutex_);
      if (closed_) return;
      closed_ = true;
      queue_.clear();
    }
    wake_.notify_all();
  }

  bool done() {
    std::lock_guard lock(mutex_);
    return closed_ || writer_.is_done();
  }

 private:
  void run() {
    for (;;) {
      T value;
      {
        std::unique_lock lock(mutex_);
        wake_.wait(lock, [this] { return stop_ || closed_ || !queue_.empty(); });
        if (stop_) return;
        if (closed_) {
          // The writer is this thread's to touch, so the stream is finished
          // here rather than by whoever asked for it.
          writer_.close();
          return;
        }
        value = std::move(queue_.front());
        queue_.pop_front();
      }
      // Outside the lock and on nobody else's thread: a write that blocks here
      // delays this one subscriber and nothing else in the compositor.
      if (!writer_.write(value)) {
        // The transport refused it — a shared memory ring the client stopped
        // draining, or a session already gone. Either way this subscription
        // is over; carrying on would serialise frames into a wall and hold a
        // thread doing it. The broker notices via done() and drops us.
        std::lock_guard lock(mutex_);
        closed_ = true;
        queue_.clear();
        return;
      }
    }
  }

  static constexpr size_t kMaxQueued = 4096;

  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<T> queue_;
  bool closed_ = false;
  bool stop_ = false;
  nprpc::StreamWriter<T> writer_;
  std::thread worker_;
};

/// One client's input subscription.
struct Subscriber {
  explicit Subscriber(nprpc::StreamWriter<InputEvent> &&w)
      : pump(std::move(w)) {}

  void send(const InputEvent &event) { pump.post(event); }
  void close() { pump.close(); }
  bool done() { return pump.done(); }

  StreamPump<InputEvent, false> pump;
};

using SubscriberPtr = std::shared_ptr<Subscriber>;

/// Fans one surface's input out to whoever is subscribed to it.
///
/// Per surface rather than one global broker: coordinates are surface-relative,
/// so an event only means anything alongside the surface it came from. A shared
/// one would have to stamp every event with a surface id and make every client
/// unpick it — paying on every client to undo a mixing that never needed to
/// happen.
class InputBroker {
 public:
  SubscriberPtr subscribe(uint32_t surfaceId, SubscriberPtr sub) {
    std::lock_guard lock(mutex_);
    subscribers_[surfaceId].push_back(sub);
    return sub;
  }

  void unsubscribe(uint32_t surfaceId, const SubscriberPtr &sub) {
    std::lock_guard lock(mutex_);
    auto it = subscribers_.find(surfaceId);
    if (it == subscribers_.end()) return;
    std::erase(it->second, sub);
    if (it->second.empty()) subscribers_.erase(it);
  }

  void broadcast(uint32_t surfaceId, InputEvent event) {
    std::vector<SubscriberPtr> targets;
    {
      std::lock_guard lock(mutex_);
      auto it = subscribers_.find(surfaceId);
      if (it == subscribers_.end()) return;
      event.serial = ++serial_;
      targets = it->second;
    }
    // This runs on the Wayland loop for every pointer motion, and every one of
    // these is a queue append — see `StreamPump`, which is where the promise
    // that it cannot block lives.
    for (const auto &sub : targets) sub->send(event);
  }

  void closeAll(uint32_t surfaceId) {
    std::vector<SubscriberPtr> targets;
    {
      std::lock_guard lock(mutex_);
      auto it = subscribers_.find(surfaceId);
      if (it == subscribers_.end()) return;
      targets = std::move(it->second);
      subscribers_.erase(it);
    }
    for (const auto &sub : targets) sub->close();
  }

 private:
  std::mutex mutex_;
  std::unordered_map<uint32_t, std::vector<SubscriberPtr>> subscribers_;
  /// Monotonic per compositor rather than per subscription. The client only
  /// uses it to say how far it has got, and a number that never repeats
  /// answers that just as well as one that restarts.
  uint32_t serial_ = 0;
};

/// One panel's "is anything in the way of me" subscription.
///
/// Remembers what it was last told, which is what turns a recompute on every
/// window move into a message only when the answer changes. The state lives
/// per subscriber rather than per panel because two subscribers to the same
/// panel may have joined at different times, and the one that joined second
/// has been told nothing yet.
struct AreaWatcher {
  explicit AreaWatcher(nprpc::StreamWriter<PanelArea> &&w)
      : pump(std::move(w)) {}

  /// Sends only what is news. True when something went out.
  bool sendIfChanged(bool covered) {
    if (sent && lastCovered == covered) return false;
    sent = true;
    lastCovered = covered;
    PanelArea area{};
    area.serial = ++serial;
    area.covered = covered;
    pump.post(area);
    return true;
  }

  void close() { pump.close(); }
  bool done() { return pump.done(); }

  // Coalescing, like every other state stream: if a client is slow, the
  // newest answer is the only one worth having.
  StreamPump<PanelArea, true> pump;
  uint32_t serial = 0;
  bool sent = false;
  bool lastCovered = false;
};

using AreaWatcherPtr = std::shared_ptr<AreaWatcher>;

/// Panel-area subscriptions, keyed by the panel they are about.
///
/// The same shape as `InputBroker` and for the same reason: this is the other
/// per-surface stream, and both are torn down by the surface going away.
class AreaBroker {
 public:
  void subscribe(uint32_t surfaceId, const AreaWatcherPtr &sub) {
    std::lock_guard lock(mutex_);
    subscribers_[surfaceId].push_back(sub);
  }

  void unsubscribe(uint32_t surfaceId, const AreaWatcherPtr &sub) {
    std::lock_guard lock(mutex_);
    auto it = subscribers_.find(surfaceId);
    if (it == subscribers_.end()) return;
    std::erase(it->second, sub);
    if (it->second.empty()) subscribers_.erase(it);
  }

  void closeAll(uint32_t surfaceId) {
    std::vector<AreaWatcherPtr> targets;
    {
      std::lock_guard lock(mutex_);
      auto it = subscribers_.find(surfaceId);
      if (it == subscribers_.end()) return;
      targets = std::move(it->second);
      subscribers_.erase(it);
    }
    for (const auto &sub : targets) sub->close();
  }

  /// Every subscribed panel, once each. The copy is what lets `answer` run
  /// outside the lock — it computes against the scene, and the scene is the
  /// loop's.
  std::vector<uint32_t> panels() {
    std::lock_guard lock(mutex_);
    std::vector<uint32_t> ids;
    ids.reserve(subscribers_.size());
    for (const auto &entry : subscribers_) ids.push_back(entry.first);
    return ids;
  }

  void tell(uint32_t surfaceId, bool covered) {
    std::vector<AreaWatcherPtr> targets;
    {
      std::lock_guard lock(mutex_);
      auto it = subscribers_.find(surfaceId);
      if (it == subscribers_.end()) return;
      targets = it->second;
    }
    for (const auto &sub : targets) sub->sendIfChanged(covered);
  }

 private:
  std::mutex mutex_;
  std::unordered_map<uint32_t, std::vector<AreaWatcherPtr>> subscribers_;
};

/// One panel's focus subscription.
struct FocusWatcher {
  explicit FocusWatcher(nprpc::StreamWriter<ActiveWindow> &&w)
      : pump(std::move(w)) {}

  void send(const ActiveWindow &window) { pump.post(window); }
  void close() { pump.close(); }
  bool done() { return pump.done(); }

  StreamPump<ActiveWindow, true> pump;
};

using FocusWatcherPtr = std::shared_ptr<FocusWatcher>;

/// One shell's window-list subscription.
struct ListWatcher {
  explicit ListWatcher(nprpc::StreamWriter<WindowList> &&w)
      : pump(std::move(w)) {}

  void send(const WindowList &list) { pump.post(list); }
  void close() { pump.close(); }
  bool done() { return pump.done(); }

  StreamPump<WindowList, true> pump;
};

using ListWatcherPtr = std::shared_ptr<ListWatcher>;

/// Everyone watching one fact about the whole desktop.
///
/// Focus and the window list are the same shape — one value, every subscriber
/// gets it, the newest wins — so they are the same class twice rather than two
/// classes that drift.
template <typename Watcher, typename Message>
class StateBroker {
 public:
  void subscribe(const std::shared_ptr<Watcher> &watcher) {
    std::lock_guard lock(mutex_);
    watchers_.push_back(watcher);
  }

  void unsubscribe(const std::shared_ptr<Watcher> &watcher) {
    std::lock_guard lock(mutex_);
    std::erase(watchers_, watcher);
  }

  void broadcast(const Message &message) {
    std::vector<std::shared_ptr<Watcher>> targets;
    {
      std::lock_guard lock(mutex_);
      std::erase_if(watchers_, [](const std::shared_ptr<Watcher> &w) {
        return w->done();
      });
      targets = watchers_;
    }
    for (const auto &watcher : targets) watcher->send(message);
  }

  bool empty() {
    std::lock_guard lock(mutex_);
    return watchers_.empty();
  }

 private:
  std::mutex mutex_;
  std::vector<std::shared_ptr<Watcher>> watchers_;
};

using FocusBroker = StateBroker<FocusWatcher, ActiveWindow>;
using ListBroker = StateBroker<ListWatcher, WindowList>;

struct ThemeWatcher {
  explicit ThemeWatcher(nprpc::StreamWriter<SystemTheme> &&w)
      : pump(std::move(w)) {}

  void send(const SystemTheme &theme) { pump.post(theme); }
  void close() { pump.close(); }
  bool done() { return pump.done(); }

  StreamPump<SystemTheme, true> pump;
};

using ThemeWatcherPtr = std::shared_ptr<ThemeWatcher>;
using ThemeBroker = StateBroker<ThemeWatcher, SystemTheme>;

/// The three names LavaUI actually has. Anything else is dark.
std::string canonicalThemeName(std::string_view name) {
  if (name == "light" || name == "nebula") return std::string(name);
  return "dark";
}

/// How the renderer names a file decoded at a given cap.
///
/// The same spelling `ImageStore.key` uses on the client, and deliberately so:
/// the two caches are separate, but a shared spelling is what lets a stall in
/// one be read against the other without translating.
std::string image_key(const std::string &path, uint32_t maxPixelSize) {
  // 0 is the native decode and keys on the bare path, so a caller that never
  // caps anything gets the path back unchanged.
  if (maxPixelSize == 0) return path;
  return path + "@" + std::to_string(maxPixelSize);
}

/// How bytes with no path are named: a hash of the content.
///
/// Derived from the bytes that arrived rather than taken from the caller. A
/// name is a claim about a namespace the compositor does not own — two clients
/// that both call their icon "logo" must not be handed each other's texture —
/// and the bytes are the one part of that claim it can check.
///
/// FNV-1a with the length mixed in, matching `ImageStore.contentKey` exactly,
/// so both sides of the same image agree on what it is called. A collision
/// means two unrelated images share a texture; it takes on the order of 2³²
/// distinct images in one session to become likely, which is why 64 bits is
/// enough for a desktop and would not be for an untrusted store.
std::string image_content_key(const uint8_t *bytes, size_t count,
                              uint32_t maxPixelSize) {
  uint64_t hash = 0xcbf2'9ce4'8422'2325ull;
  for (size_t i = 0; i < count; ++i) {
    hash ^= bytes[i];
    hash *= 0x0000'0100'0000'01b3ull;
  }
  char hex[17];
  std::snprintf(hex, sizeof(hex), "%llx",
                static_cast<unsigned long long>(hash));
  return "mem:" + std::string(hex) + "-" + std::to_string(count) + "-" +
         std::to_string(maxPixelSize);
}

InputEvent make_event(uint32_t kind, float x, float y, int32_t button,
                      int32_t mods) {
  InputEvent event{};
  event.kind = kind;
  event.x = x;
  event.y = y;
  event.button = button;
  event.mods = mods;
  return event;
}

class CompositorImpl final : public ICompositor_Servant {
 public:
  CompositorImpl(CompositorHost &host, LoopQueue &loop, InputBroker &broker,
                 FocusBroker &focus, ListBroker &windows, ThemeBroker &theme,
                 AreaBroker &areas)
      : host_(host), loop_(loop), broker_(broker), focus_(focus),
        windows_(windows), theme_(theme), areas_(areas) {}

  // ─── Resources ───────────────────────────────────────────────────────────

  uint32_t RegisterFont(nprpc::flat::Span<char> path, uint32_t pixelSize26_6,
                        uint32_t faceIndex, uint32_t rasterFlags) override {
    const std::string file{path};
    const int id =
        host_.registerFont(file, pixelSize26_6, faceIndex, rasterFlags);
    if (id < 0) throw FontNotFound(file);
    wlr_log(WLR_INFO, "font %d: %.2fpx face %u flags 0x%x '%s'", id,
            static_cast<double>(pixelSize26_6) / 64.0, faceIndex, rasterFlags,
            file.c_str());
    return static_cast<uint32_t>(id);
  }

  ImageInfo RegisterImage(nprpc::flat::Span<char> path,
                          uint32_t maxPixelSize) override {
    const std::string file{path};
    const std::string key = image_key(file, maxPixelSize);
    if (const ImageInfo *known = sharedImage(key)) return *known;

    uint32_t width = 0, height = 0;
    const int id = host_.registerImage(key, file, maxPixelSize, width, height);
    if (id <= 0) throw ImageNotFound(file);
    return keepImage(key, static_cast<uint32_t>(id), width, height);
  }

  ImageInfo RegisterImageData(nprpc::flat::Span<uint8_t> bytes,
                              uint32_t maxPixelSize) override {
    const auto *data = static_cast<const uint8_t *>(bytes.data());
    const std::string key = image_content_key(data, bytes.size(), maxPixelSize);
    if (const ImageInfo *known = sharedImage(key)) return *known;

    uint32_t width = 0, height = 0;
    const int id = host_.registerImageData(key, data, bytes.size(),
                                           maxPixelSize, width, height);
    // No path to name, so name what there is: the client knows which call it
    // made, but not that the bytes rather than the transfer were the problem.
    if (id <= 0) {
      throw ImageNotFound("<" + std::to_string(bytes.size()) +
                          " bytes in memory>");
    }
    return keepImage(key, static_cast<uint32_t>(id), width, height);
  }

  void ReleaseImage(uint32_t id) override {
    // An id this compositor never handed out, or has already released, is a
    // client that lost track rather than an error — see the IDL.
    auto keyIt = imageKeys_.find(id);
    if (keyIt == imageKeys_.end()) return;
    const std::string key = keyIt->second;

    // Counted here, because the registration above hands two clients the same
    // id without uploading twice — so the engine's own refcount saw one user
    // where there are two, and the first release would free a texture the
    // second is still drawing. Sharing between clients is the compositor's
    // business, not the engine's, so the count belongs on this side.
    //
    // A client that registers twice and releases once leaks its texture until
    // the session ends. That is the safe direction to be wrong in; fixing it
    // properly needs per-client accounting, and this call carries no client.
    auto userIt = imageUsers_.find(key);
    if (userIt != imageUsers_.end() && --userIt->second > 0) return;

    imageUsers_.erase(key);
    imageIds_.erase(key);
    imageKeys_.erase(keyIt);
    host_.releaseImage(key);
  }

  // ─── Surfaces ────────────────────────────────────────────────────────────

  uint32_t CreateSurface(nprpc::flat::Span<char> arenaId, uint32_t width,
                         uint32_t height, nprpc::flat::Span<char> title,
                         WindowFrame frame,
                         nprpc::flat::Span<char> appId) override {
    const std::string arena{arenaId};
    const uint32_t id = host_.createSurface(arena, width, height,
                                            std::string{title},
                                            frame == WindowFrame::server,
                                            std::string{appId});
    if (id == 0) throw ArenaNotFound(arena);
    return id;
  }

  uint32_t CreatePanel(nprpc::flat::Span<char> arenaId, PanelEdge edge,
                       uint32_t thickness, nprpc::flat::Boolean reserve,
                       nprpc::flat::Span<char> title,
                       nprpc::flat::Span<char> appId) override {
    const std::string arena{arenaId};
    const uint32_t id =
        host_.createPanel(arena, static_cast<uint32_t>(edge), thickness,
                          static_cast<bool>(reserve), std::string{title},
                          std::string{appId});
    if (id == 0) throw ArenaNotFound(arena);
    return id;
  }

  void DestroySurface(uint32_t surfaceId) override {
    if (!host_.destroySurface(surfaceId)) throw SurfaceNotFound(surfaceId);
    broker_.closeAll(surfaceId);
  }

  void BeginMove(uint32_t surfaceId) override {
    if (!host_.beginMove(surfaceId)) throw SurfaceNotFound(surfaceId);
  }

  bool ToggleMaximize(uint32_t surfaceId) override {
    bool maximized = false;
    if (!host_.toggleMaximize(surfaceId, maximized)) {
      throw SurfaceNotFound(surfaceId);
    }
    return maximized;
  }

  void Minimize(uint32_t surfaceId) override {
    if (!host_.minimize(surfaceId)) throw SurfaceNotFound(surfaceId);
  }

  void SetMinSize(uint32_t surfaceId, uint32_t minWidth,
                  uint32_t minHeight) override {
    if (!host_.setMinSize(surfaceId, minWidth, minHeight)) {
      throw SurfaceNotFound(surfaceId);
    }
  }

  void SetPanelThickness(uint32_t surfaceId, uint32_t thickness,
                         uint32_t reserved) override {
    if (!host_.setPanelThickness(surfaceId, thickness, reserved)) {
      throw SurfaceNotFound(surfaceId);
    }
  }

  Appearance GetAppearance() override {
    Appearance out{};
    host_.appearance(out.cornerRadius, out.shadowBlur, out.shadowOpacity,
                     out.shadowOffsetY);
    return out;
  }

  // ─── Settings ────────────────────────────────────────────────────────────
  //
  // Every setter applies first and saves second, and raises only if the save
  // failed — so a client that catches `SettingsWriteFailed` knows the change
  // is on screen and will not be next time, which is a different sentence
  // from "nothing happened".

  void SetAppearance(flat::Appearance_Direct appearance) override {
    std::string error;
    host_.updateAppearance(appearance.cornerRadius(), appearance.shadowBlur(),
                        appearance.shadowOpacity(), appearance.shadowOffsetY(),
                        error);
    if (!error.empty()) throw SettingsWriteFailed(host_.configPath(), error);
  }

  Wallpaper GetWallpaper() override {
    Wallpaper out{};
    host_.background(out.mode, out.color, out.path, out.fit);
    return out;
  }

  void SetWallpaper(flat::Wallpaper_Direct wallpaper) override {
    std::string pictureError;
    std::string error;
    host_.updateBackground(std::string{wallpaper.mode()}, wallpaper.color(),
                           std::string{wallpaper.path()},
                           std::string{wallpaper.fit()}, pictureError, error);
    // Order matters. A picture that could not be read means nothing happened
    // at all, so that is the report — raising the save failure instead would
    // tell the user their new wallpaper is up and merely unsaved, which is
    // the opposite of what is on screen.
    if (!pictureError.empty()) {
      throw WallpaperUnreadable(std::string{wallpaper.path()}, pictureError);
    }
    if (!error.empty()) throw SettingsWriteFailed(host_.configPath(), error);
  }

  SystemTheme GetSystemTheme() override { return currentTheme(); }

  void SetSystemTheme(flat::SystemTheme_Direct theme) override {
    const std::string name = canonicalThemeName(std::string{theme.name()});
    std::string error;
    host_.updateSystemTheme(name, error);
    if (!error.empty()) throw SettingsWriteFailed(host_.configPath(), error);
  }

  nprpc::Task<> SubscribeSystemTheme(
      nprpc::BidiStream<ThemeAck, SystemTheme> stream) override {
    auto watcher = std::make_shared<ThemeWatcher>(std::move(stream.writer));
    theme_.subscribe(watcher);
    watcher->send(currentTheme());
    try {
      while (auto ack = co_await stream.reader) {
        (void)ack;
      }
    } catch (...) {
      theme_.unsubscribe(watcher);
      watcher->close();
      throw;
    }
    theme_.unsubscribe(watcher);
    watcher->close();
    co_return;
  }

  SystemTheme currentTheme() const {
    SystemTheme out{};
    std::string name;
    host_.systemTheme(name);
    out.name = canonicalThemeName(name);
    return out;
  }

  KeyboardSettings GetKeyboard() override {
    CompositorHost::KeyboardState state;
    host_.keyboardSettings(state);
    KeyboardSettings out{};
    out.layout = state.layout;
    out.variant = state.variant;
    out.options = state.options;
    out.model = state.model;
    out.rules = state.rules;
    out.repeatRate = state.repeatRate;
    out.repeatDelay = state.repeatDelay;
    out.modKey = state.modKey;
    return out;
  }

  void SetKeyboard(flat::KeyboardSettings_Direct settings) override {
    CompositorHost::KeyboardState state;
    state.layout = std::string{settings.layout()};
    state.variant = std::string{settings.variant()};
    state.options = std::string{settings.options()};
    state.model = std::string{settings.model()};
    state.rules = std::string{settings.rules()};
    state.repeatRate = settings.repeatRate();
    state.repeatDelay = settings.repeatDelay();
    state.modKey = std::string{settings.modKey()};

    std::string error;
    host_.setKeyboardSettings(state, error);
    if (!error.empty()) throw SettingsWriteFailed(host_.configPath(), error);
  }

  std::vector<KeyboardLayout> ListKeyboardLayouts() override {
    std::vector<CompositorHost::LayoutEntry> entries;
    host_.keyboardLayouts(entries);

    std::vector<KeyboardLayout> out;
    out.reserve(entries.size());
    for (const auto &entry : entries) {
      KeyboardLayout layout{};
      layout.code = entry.code;
      layout.variant = entry.variant;
      layout.description = entry.description;
      out.push_back(std::move(layout));
    }
    return out;
  }

  std::vector<KeyBinding> ListKeyBindings() override {
    std::vector<CompositorHost::BindingEntry> entries;
    host_.keyBindings(entries);

    std::vector<KeyBinding> out;
    out.reserve(entries.size());
    for (const auto &entry : entries) {
      KeyBinding binding{};
      binding.modifiers = entry.modifiers;
      binding.key = entry.key;
      binding.action = entry.action;
      binding.description = entry.description;
      out.push_back(std::move(binding));
    }
    return out;
  }

  std::vector<OutputInfo> ListOutputs() override {
    std::vector<CompositorHost::OutputEntry> entries;
    host_.outputList(entries);

    std::vector<OutputInfo> out;
    out.reserve(entries.size());
    for (const auto &entry : entries) {
      OutputInfo info{};
      info.name = entry.name;
      info.description = entry.description;
      info.enabled = entry.enabled;
      info.x = entry.x;
      info.y = entry.y;
      info.width = entry.width;
      info.height = entry.height;
      info.refresh = entry.refresh;
      info.scale = entry.scale;
      info.transform = entry.transform;
      out.push_back(std::move(info));
    }
    return out;
  }

  std::vector<OutputMode> ListOutputModes(
      nprpc::flat::Span<char> name) override {
    const std::string connector{name};
    std::vector<CompositorHost::ModeEntry> entries;
    if (!host_.outputModes(connector, entries)) {
      throw OutputNotFound(connector);
    }

    std::vector<OutputMode> out;
    out.reserve(entries.size());
    for (const auto &entry : entries) {
      OutputMode mode{};
      mode.width = entry.width;
      mode.height = entry.height;
      mode.refresh = entry.refresh;
      mode.current = entry.current;
      mode.preferred = entry.preferred;
      out.push_back(mode);
    }
    return out;
  }

  void SetOutput(flat::OutputRequest_Direct request) override {
    CompositorHost::OutputChange change;
    change.name = std::string{request.name()};
    change.enabled = static_cast<bool>(request.enabled());
    change.width = request.width();
    change.height = request.height();
    change.refresh = request.refresh();
    change.scale = request.scale();
    change.x = request.x();
    change.y = request.y();
    change.transform = request.transform();

    std::string error;
    if (!host_.setOutput(change, error)) throw OutputNotFound(change.name);
    if (!error.empty()) throw SettingsWriteFailed(host_.configPath(), error);
  }

  void ActivateWindow(uint32_t surfaceId) override {
    if (!host_.activateWindow(surfaceId)) throw SurfaceNotFound(surfaceId);
  }

  void SetInputRegion(uint32_t surfaceId, int32_t x, int32_t y, uint32_t w,
                      uint32_t h) override {
    if (!host_.setInputRegion(surfaceId, x, y, w, h)) {
      throw SurfaceNotFound(surfaceId);
    }
  }

  void SetCursor(uint32_t surfaceId, CursorShape shape) override {
    // Unreliable: there is no reply, so nothing to raise into. A surface that
    // has gone is a client whose window closed while the pointer was on it,
    // which is ordinary rather than exceptional.
    host_.setCursor(surfaceId, static_cast<uint32_t>(shape));
  }

  nprpc::Task<> SubscribePanelArea(
      uint32_t surfaceId,
      nprpc::BidiStream<PanelAreaAck, PanelArea> stream) override {
    if (!host_.surfaceExists(surfaceId)) throw SurfaceNotFound(surfaceId);

    auto watcher = std::make_shared<AreaWatcher>(std::move(stream.writer));
    areas_.subscribe(surfaceId, watcher);
    // The answer at subscription, so a dock that starts on an empty desktop
    // shows itself on its first frame rather than after the first window
    // happens to move.
    watcher->sendIfChanged(host_.panelCovered(surfaceId));

    try {
      while (auto ack = co_await stream.reader) {
        (void)ack;
      }
    } catch (...) {
      areas_.unsubscribe(surfaceId, watcher);
      watcher->close();
      throw;
    }
    areas_.unsubscribe(surfaceId, watcher);
    watcher->close();
    co_return;
  }

  nprpc::Task<> SubscribeWindows(
      nprpc::BidiStream<WindowListAck, WindowList> stream) override {
    auto watcher = std::make_shared<ListWatcher>(std::move(stream.writer));
    windows_.subscribe(watcher);

    // The state at subscription: a dock that started after the windows did
    // would otherwise be empty until somebody opened or closed one.
    watcher->send(currentList());

    try {
      while (auto ack = co_await stream.reader) {
        (void)ack;
      }
    } catch (...) {
      windows_.unsubscribe(watcher);
      watcher->close();
      throw;
    }
    windows_.unsubscribe(watcher);
    watcher->close();
    co_return;
  }

  /// The window list as it is right now, in wire form.
  WindowList currentList() const {
    WindowList out{};
    std::vector<CompositorHost::WindowEntry> entries;
    host_.windowList(out.currentWorkspace, entries);
    out.windows.reserve(entries.size());
    for (const auto &entry : entries) {
      WindowInfo info{};
      info.surfaceId = entry.surfaceId;
      info.title = entry.title;
      info.appId = entry.appId;
      info.workspace = entry.workspace;
      info.minimized = entry.minimized;
      info.focused = entry.focused;
      out.windows.push_back(std::move(info));
    }
    return out;
  }

  nprpc::Task<> SubscribeActiveWindow(
      nprpc::BidiStream<FocusAck, ActiveWindow> stream) override {
    auto watcher = std::make_shared<FocusWatcher>(std::move(stream.writer));
    focus_.subscribe(watcher);

    // The state at subscription, before any change. A panel that started after
    // the windows did would otherwise show nothing until the user next clicked
    // something — which, on a desktop that is already sitting still, is a
    // global menu that appears to be broken.
    ActiveWindow current{};
    host_.activeWindow(current.surfaceId, current.title, current.menuService,
                       current.menuObjectPath);
    watcher->send(current);

    try {
      // The panel saying which window it is showing. Nothing here needs the
      // number yet; reading is what keeps flow control moving and what ends
      // this loop when the panel goes away.
      while (auto ack = co_await stream.reader) {
        (void)ack;
      }
    } catch (...) {
      focus_.unsubscribe(watcher);
      watcher->close();
      throw;
    }
    focus_.unsubscribe(watcher);
    watcher->close();
    co_return;
  }

  void Present(uint32_t surfaceId) override { host_.present(surfaceId); }

  void Heartbeat(uint32_t surfaceId) override { host_.heartbeat(surfaceId); }

  void ScrollUnclaimed(uint32_t surfaceId, float dx, float dy) override {
    host_.scrollUnclaimed(surfaceId, dx, dy);
  }

  // ─── Input ───────────────────────────────────────────────────────────────

  nprpc::Task<> SubscribeInput(
      uint32_t surfaceId,
      nprpc::BidiStream<InputAck, InputEvent> stream) override {
    // Before touching the stream, so an unknown surface is a typed exception
    // at the call rather than an abort one chunk later — by which point the
    // caller has built a subscription around something that never existed.
    if (!host_.surfaceExists(surfaceId)) throw SurfaceNotFound(surfaceId);

    auto sub = std::make_shared<Subscriber>(std::move(stream.writer));
    broker_.subscribe(surfaceId, sub);

    // The opening `Resize`. Without it a client can only learn its size by
    // waiting for the user to drag a border, and draws at a guessed size until
    // then — which is the black margin this interface exists to remove.
    float width = 0.f, height = 0.f;
    host_.surfaceSize(surfaceId, width, height);
    sub->send(make_event(static_cast<uint32_t>(canvas::InputEventKind::Resize),
                         width, height, 0, 0));

    try {
      // Acks are the client saying how far it has got. Nothing here needs the
      // number yet; reading the stream is what keeps flow control moving and
      // what makes the loop end when the client goes away.
      while (auto ack = co_await stream.reader) {
        (void)ack;
      }
    } catch (...) {
      finish(surfaceId, sub);
      throw;
    }
    finish(surfaceId, sub);
    co_return;
  }

  std::vector<std::string> TakeDroppedPaths(uint32_t surfaceId) override {
    if (!host_.surfaceExists(surfaceId)) throw SurfaceNotFound(surfaceId);
    return {};
  }

  Capture CaptureSurface(uint32_t surfaceId, int32_t x, int32_t y, int32_t w,
                         int32_t h, int32_t maxSide) override {
    if (!host_.surfaceExists(surfaceId)) throw SurfaceNotFound(surfaceId);
    Capture out{};
    if (!host_.captureSurface(surfaceId, x, y, w, h, maxSide, out.png,
                              out.width, out.height)) {
      throw CaptureFailed(surfaceId);
    }
    return out;
  }

  // ─── Clipboard ───────────────────────────────────────────────────────────

  std::string GetClipboard(uint32_t surfaceId) override {
    if (!host_.surfaceExists(surfaceId)) throw SurfaceNotFound(surfaceId);
    return host_.clipboardText();
  }

  void SetClipboard(uint32_t surfaceId, nprpc::flat::Span<char> text) override {
    if (!host_.surfaceExists(surfaceId)) throw SurfaceNotFound(surfaceId);
    host_.setClipboardText(std::string(text.begin(), text.end()));
  }

  std::string GetPrimarySelection(uint32_t surfaceId) override {
    if (!host_.surfaceExists(surfaceId)) throw SurfaceNotFound(surfaceId);
    return host_.primarySelectionText();
  }

  void SetPrimarySelection(uint32_t surfaceId,
                           nprpc::flat::Span<char> text) override {
    if (!host_.surfaceExists(surfaceId)) throw SurfaceNotFound(surfaceId);
    host_.setPrimarySelectionText(std::string(text.begin(), text.end()));
  }

  std::vector<uint8_t> GetClipboardPng(uint32_t surfaceId) override {
    if (!host_.surfaceExists(surfaceId)) throw SurfaceNotFound(surfaceId);
    return host_.clipboardPng();
  }

 private:
  /// The subscription is the surface's lease.
  ///
  /// When the stream ends — the client closed it, the client died, the user
  /// closed the window — the surface goes with it. Tying the two together is
  /// what stops a crashed client from leaving a window on screen that nothing
  /// will ever draw into again.
  ///
  /// Posted rather than called: a coroutine resumes on whichever thread
  /// delivered the chunk that ended it, and destroying a surface touches the
  /// scene graph.
  void finish(uint32_t surfaceId, const SubscriberPtr &sub) {
    broker_.unsubscribe(surfaceId, sub);
    sub->close();
    loop_.post([this, surfaceId] { host_.destroySurface(surfaceId); });
  }

  /// What `key` was registered as, if anything, counting one more user.
  ///
  /// Idempotent per key, answered without a decode and without leaving the
  /// loop. Not just an optimisation: a desktop's second client asking for an
  /// asset the first already has is the normal case, and it should cost a
  /// lookup.
  const ImageInfo *sharedImage(const std::string &key) {
    auto it = imageIds_.find(key);
    if (it == imageIds_.end()) return nullptr;
    ++imageUsers_[key];
    return &it->second;
  }

  /// Records a freshly uploaded texture and returns what the client is told.
  ImageInfo keepImage(const std::string &key, uint32_t id, uint32_t width,
                      uint32_t height) {
    ImageInfo info;
    info.id = id;
    info.width = width;
    info.height = height;
    imageIds_[key] = info;
    ++imageUsers_[key];
    // Keyed by the id the client will use, so `ReleaseImage` needs no
    // agreement between the two sides about how a cache key is spelled.
    imageKeys_[id] = key;
    wlr_log(WLR_INFO, "image %u: %ux%u '%s'", id, width, height, key.c_str());
    return info;
  }

  CompositorHost &host_;
  LoopQueue &loop_;
  InputBroker &broker_;
  FocusBroker &focus_;
  ListBroker &windows_;
  ThemeBroker &theme_;
  AreaBroker &areas_;

  /// Registered images, three ways round: what a key resolves to, how many
  /// clients hold it, and which key an id came from. No lock, unlike
  /// `InputBroker` — every method that touches these is dispatched onto the
  /// loop by the POA, and a lock would suggest otherwise.
  std::unordered_map<std::string, ImageInfo> imageIds_;
  std::unordered_map<std::string, uint32_t> imageUsers_;
  std::unordered_map<uint32_t, std::string> imageKeys_;
};

class ControlPlaneImpl final : public ControlPlane {
 public:
  ~ControlPlaneImpl() override {
    if (rpc_) rpc_->destroy();
    // The path we published, not the one `referencePath()` would compute now:
    // a compositor must never unlink another session's reference, and the
    // only way to be sure is to remember what we wrote.
    if (!publishedPath_.empty()) std::remove(publishedPath_.c_str());
  }

  bool start(wl_event_loop *loop, CompositorHost &host) {
    if (!queue_.start(loop)) {
      wlr_log(WLR_ERROR, "control plane: could not add a loop source");
      return false;
    }

    // Two shared-memory rings per client, resident for as long as the window
    // is open, so this is what a window costs before it has drawn anything.
    // Almost everything here is tiny — input events, Present, heartbeats, a
    // window list — and would be happy with the 1 MiB default; `CaptureSurface`
    // is the exception, returning a whole window as a PNG in one reply, and a
    // ring that cannot carry one turns the agent's screenshot into a timeout.
    // So: sized for the one big message rather than for the traffic, and the
    // day captures travel in their own segment this can drop back.
    rpc_ = nprpc::RpcBuilder()
               .set_log_level(nprpc::LogLevel::warn)
               .shm_channel_sizes(4 * 1024 * 1024, 3 * 1024 * 1024)
               .build();
    if (rpc_ == nullptr) {
      wlr_log(WLR_ERROR, "control plane: could not build the RPC runtime");
      return false;
    }
    // One thread per concurrent client conversation, plus room for the input
    // streams, which live as long as their surfaces do.
    rpc_->start_thread_pool(4);

    // Servants land on the compositor's loop, not on the shared-memory ring
    // thread. This is the rule "anything touching the scene runs on the loop"
    // expressed once, as a property of the POA, instead of as something every
    // servant method has to remember — and forgetting it would mean touching
    // wlroots from an RPC thread, which fails late and nowhere near the
    // mistake.
    //
    // It also frees the ring immediately: `CreateSurface` brings up a canvas
    // window and is not a microsecond-scale call like the rest of this
    // interface.
    nprpc::DispatchExecutor executor{};
    executor.ctx = &queue_;
    executor.post = [](void *ctx, nprpc::DispatchExecutor::WorkFn fn,
                       void *arg) {
      static_cast<LoopQueue *>(ctx)->post([fn, arg] { fn(arg); });
    };
    executor.is_running_on = [](void *ctx) {
      return static_cast<LoopQueue *>(ctx)->onLoopThread();
    };

    poa_ = rpc_->create_poa()
               .with_max_objects(8)
               .with_lifespan(nprpc::PoaPolicy::Lifespan::Persistent)
               .with_object_id_policy(nprpc::PoaPolicy::ObjectIdPolicy::UserSupplied)
               .with_dispatch_executor(executor)
               .build();
    if (poa_ == nullptr) {
      wlr_log(WLR_ERROR, "control plane: could not create a POA");
      return false;
    }

    host_ = &host;
    servant_ = std::make_unique<CompositorImpl>(host, queue_, broker_, focus_,
                                                windows_, theme_, areas_);
    const nprpc::ObjectId oid = poa_->activate_object_with_id(
        0, servant_.get(), nprpc::ObjectActivationFlags::shm);

    // The reference as a string: everything a client needs to reach this
    // object, shared-memory endpoint included, on one line of text. A file
    // rather than a nameserver because this is one machine and one desktop
    // session, and requiring a separate process to start first would be a
    // deployment step in exchange for nothing.
    const std::string path = ControlPlane::referencePath();
    std::ofstream file(path, std::ios::trunc);
    if (!file) {
      wlr_log(WLR_ERROR, "control plane: cannot write '%s'", path.c_str());
      return false;
    }
    file << oid.to_string();
    file.close();
    publishedPath_ = path;

    wlr_log(WLR_INFO, "control plane: listening, reference at %s", path.c_str());
    return true;
  }

  void postInput(uint32_t surfaceId, uint32_t kind, float x, float y,
                 int32_t button, int32_t mods) override {
    broker_.broadcast(surfaceId, make_event(kind, x, y, button, mods));
  }

  void surfaceGone(uint32_t surfaceId) override {
    broker_.closeAll(surfaceId);
    // A panel's area subscription dies with the panel, the same way its input
    // stream does — and it is the only thing that ends this stream from the
    // compositor's side, since nothing else is watching for the client.
    areas_.closeAll(surfaceId);
  }

  void postPanelAreas() override {
    // Nothing subscribed is the common case — no dock, or a dock that has not
    // asked — and it costs one empty vector.
    for (uint32_t id : areas_.panels()) {
      areas_.tell(id, host_->panelCovered(id));
    }
  }

  void postWindowList() override {
    // Nothing to build when nobody is listening: a desktop with no dock and no
    // task list should not pay for a snapshot on every focus change.
    if (windows_.empty()) return;
    WindowList list = servant_->currentList();
    // Monotonic, so a shell's ack names the snapshot it drew — the same
    // contract `InputEvent.serial` has.
    list.serial = ++listSerial_;
    windows_.broadcast(list);
  }

  void postSystemTheme() override {
    if (theme_.empty()) return;
    SystemTheme theme = servant_->currentTheme();
    theme.serial = ++themeSerial_;
    theme_.broadcast(theme);
  }

  void postActiveWindow(uint32_t surfaceId, const std::string &title,
                        const std::string &menuService,
                        const std::string &menuObjectPath) override {
    ActiveWindow window{};
    window.surfaceId = surfaceId;
    window.title = title;
    window.menuService = menuService;
    window.menuObjectPath = menuObjectPath;
    // Queued, never written from here. Two things go wrong when the loop
    // thread does the writing itself, and both were seen: focus changes
    // *inside* an RPC dispatch (`CreateSurface` focuses the window it just
    // opened) re-enter the RPC layer the loop is already running under, and a
    // subscriber that has stopped reading — the panel process dying is the
    // ordinary way — blocks the write on a full buffer. Either one stops the
    // compositor answering anybody. See `FocusBroker`.
    focus_.broadcast(window);
  }

 private:
  LoopQueue queue_;
  InputBroker broker_;
  FocusBroker focus_;
  ListBroker windows_;
  ThemeBroker theme_;
  AreaBroker areas_;
  CompositorHost *host_ = nullptr;
  uint32_t listSerial_ = 0;
  uint32_t themeSerial_ = 0;
  nprpc::Rpc *rpc_ = nullptr;
  nprpc::Poa *poa_ = nullptr;
  std::unique_ptr<CompositorImpl> servant_;
  std::string publishedPath_;
};

}  // namespace

std::string ControlPlane::sessionId() {
  // The Wayland socket names the session, so it names the control plane too.
  //
  // Nothing else has to be configured for that to work: `main` publishes
  // `WAYLAND_DISPLAY` before this runs, and every process started from inside
  // the session inherits it — which is exactly the set of processes that
  // should reach *this* compositor. A nested one, started from a terminal in
  // an existing session, gets its own socket from
  // `wl_display_add_socket_auto` and therefore its own name here, without
  // being told it is nested.
  const char *display = std::getenv("WAYLAND_DISPLAY");
  if (display == nullptr || *display == '\0') return "default";
  // The protocol allows an absolute path. The last component still names the
  // socket, and it is the only part that can go in a filename.
  std::string_view name{display};
  if (const auto slash = name.rfind('/'); slash != std::string_view::npos) {
    name.remove_prefix(slash + 1);
  }
  return std::string(name);
}

std::string ControlPlane::referencePath() {
  // One name per session, not per machine. Two compositors sharing
  // `XDG_RUNTIME_DIR` is the ordinary case while developing one — a nested
  // session inside the live one — and with a single well-known name the
  // second to start owns the file: every client launched afterwards connects
  // to it, including the clients of the session that was already running, and
  // the file is deleted out from under that session when the nested one ends.
  if (const char *forced = std::getenv("LAVA_COMPOSITOR_IOR")) {
    if (*forced != '\0') return forced;
  }
  const char *dir = std::getenv("XDG_RUNTIME_DIR");
  return std::string(dir ? dir : "/tmp") + "/lava-compositor-" + sessionId() +
         ".ior";
}

std::unique_ptr<ControlPlane> ControlPlane::start(wl_event_loop *loop,
                                                  CompositorHost &host) {
  auto self = std::make_unique<ControlPlaneImpl>();
  if (!self->start(loop, host)) return nullptr;
  return self;
}

}  // namespace lava
