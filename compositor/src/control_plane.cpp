#include "control_plane.hpp"

#include <sys/eventfd.h>
#include <unistd.h>

#include <condition_variable>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <thread>
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
/// The same shape as LavaUI's `MainQueue` and `ArenaDemo`'s `LoopQueue`, which
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

/// One client's input subscription.
///
/// The writer is pushed to from the loop thread and closed from wherever the
/// stream ends, so it carries its own lock. `active` is what makes closing
/// twice — which happens routinely, since a surface can end from either side —
/// a no-op rather than a use-after-close.
struct Subscriber {
  explicit Subscriber(nprpc::StreamWriter<InputEvent> &&w)
      : writer(std::move(w)) {}

  void send(const InputEvent &event) {
    std::lock_guard lock(mutex);
    if (!active) return;
    writer.write(event);
  }

  void close() {
    std::lock_guard lock(mutex);
    if (!active) return;
    active = false;
    writer.close();
  }

  std::mutex mutex;
  bool active = true;
  nprpc::StreamWriter<InputEvent> writer;
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
    // Outside the lock: a write can block on flow control, and holding the
    // map's lock across it would stall every other surface's input too.
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

/// One panel's focus subscription.
///
/// The same shape as `Subscriber` and for the same reasons — pushed to from
/// the loop thread, closed from wherever the stream ends — but a different
/// type, because it carries a different message and there is nothing to gain
/// from making one class that carries either.
struct FocusWatcher {
  explicit FocusWatcher(nprpc::StreamWriter<ActiveWindow> &&w)
      : writer(std::move(w)) {}

  void send(const ActiveWindow &window) {
    std::lock_guard lock(mutex);
    if (!active) return;
    writer.write(window);
  }

  void close() {
    std::lock_guard lock(mutex);
    if (!active) return;
    active = false;
    writer.close();
  }

  std::mutex mutex;
  bool active = true;
  nprpc::StreamWriter<ActiveWindow> writer;
};

using FocusWatcherPtr = std::shared_ptr<FocusWatcher>;

/// Everyone watching the focus.
///
/// Not per surface, unlike input: focus is one fact about the whole session,
/// and a panel wants the changes rather than the changes *of* some window it
/// named. There are normally zero or one of these.
///
/// Writes happen on a thread of this broker's own, and that is the important
/// part rather than an implementation detail. Focus changes on the Wayland
/// loop — including when a *panel* dies, which destroys its surface and moves
/// focus — and writing to a subscriber that has just stopped reading can
/// block on a full ring buffer. On the loop thread that is the whole
/// compositor stopping: every client's calls time out because the panel that
/// crashed is not draining a stream. Here it is one idle thread waiting for a
/// session that is about to be reaped.
///
/// The queue holds one value, not a log. Focus is a state — the newest answer
/// makes every older one wrong — so a panel that was slow gets what is true
/// now rather than a replay of what it missed.
class FocusBroker {
 public:
  FocusBroker() : worker_([this] { run(); }) {}

  ~FocusBroker() {
    {
      std::lock_guard lock(mutex_);
      stop_ = true;
    }
    wake_.notify_all();
    worker_.join();
  }

  void subscribe(const FocusWatcherPtr &watcher) {
    std::lock_guard lock(mutex_);
    watchers_.push_back(watcher);
  }

  void unsubscribe(const FocusWatcherPtr &watcher) {
    std::lock_guard lock(mutex_);
    std::erase(watchers_, watcher);
  }

  void broadcast(const ActiveWindow &window) {
    {
      std::lock_guard lock(mutex_);
      pending_ = window;
      hasPending_ = true;
    }
    wake_.notify_one();
  }

 private:
  void run() {
    for (;;) {
      ActiveWindow window{};
      std::vector<FocusWatcherPtr> targets;
      {
        std::unique_lock lock(mutex_);
        wake_.wait(lock, [this] { return stop_ || hasPending_; });
        if (stop_) return;
        window = pending_;
        hasPending_ = false;
        // A panel whose stream has ended is a writer nothing will ever read.
        std::erase_if(watchers_, [](const FocusWatcherPtr &w) {
          return w->writer.is_done();
        });
        targets = watchers_;
      }
      // Outside the lock: a write can block, and a subscription arriving
      // meanwhile must not wait behind it.
      for (const auto &watcher : targets) watcher->send(window);
    }
  }

  std::mutex mutex_;
  std::condition_variable wake_;
  std::vector<FocusWatcherPtr> watchers_;
  ActiveWindow pending_{};
  bool hasPending_ = false;
  bool stop_ = false;
  std::thread worker_;
};

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
                 FocusBroker &focus)
      : host_(host), loop_(loop), broker_(broker), focus_(focus) {}

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
                         WindowFrame frame) override {
    const std::string arena{arenaId};
    const uint32_t id = host_.createSurface(arena, width, height,
                                            std::string{title},
                                            frame == WindowFrame::server);
    if (id == 0) throw ArenaNotFound(arena);
    return id;
  }

  uint32_t CreatePanel(nprpc::flat::Span<char> arenaId, PanelEdge edge,
                       uint32_t thickness, nprpc::flat::Boolean reserve,
                       nprpc::flat::Span<char> title) override {
    const std::string arena{arenaId};
    const uint32_t id =
        host_.createPanel(arena, static_cast<uint32_t>(edge), thickness,
                          static_cast<bool>(reserve), std::string{title});
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

  void SetPanelThickness(uint32_t surfaceId, uint32_t thickness,
                         uint32_t reserved) override {
    if (!host_.setPanelThickness(surfaceId, thickness, reserved)) {
      throw SurfaceNotFound(surfaceId);
    }
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
    host_.activeWindow(current.surfaceId, current.title);
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
    return {};
  }

  void SetClipboard(uint32_t surfaceId, nprpc::flat::Span<char>) override {
    if (!host_.surfaceExists(surfaceId)) throw SurfaceNotFound(surfaceId);
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
    std::remove(ControlPlane::referencePath().c_str());
  }

  bool start(wl_event_loop *loop, CompositorHost &host) {
    if (!queue_.start(loop)) {
      wlr_log(WLR_ERROR, "control plane: could not add a loop source");
      return false;
    }

    rpc_ = nprpc::RpcBuilder().set_log_level(nprpc::LogLevel::warn).build();
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

    servant_ = std::make_unique<CompositorImpl>(host, queue_, broker_, focus_);
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

    wlr_log(WLR_INFO, "control plane: listening, reference at %s", path.c_str());
    return true;
  }

  void postInput(uint32_t surfaceId, uint32_t kind, float x, float y,
                 int32_t button, int32_t mods) override {
    broker_.broadcast(surfaceId, make_event(kind, x, y, button, mods));
  }

  void surfaceGone(uint32_t surfaceId) override {
    broker_.closeAll(surfaceId);
  }

  void postActiveWindow(uint32_t surfaceId,
                        const std::string &title) override {
    ActiveWindow window{};
    window.surfaceId = surfaceId;
    window.title = title;
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
  nprpc::Rpc *rpc_ = nullptr;
  nprpc::Poa *poa_ = nullptr;
  std::unique_ptr<CompositorImpl> servant_;
};

}  // namespace

std::string ControlPlane::referencePath() {
  const char *dir = std::getenv("XDG_RUNTIME_DIR");
  return std::string(dir ? dir : "/tmp") + "/lava-compositor.ior";
}

std::unique_ptr<ControlPlane> ControlPlane::start(wl_event_loop *loop,
                                                  CompositorHost &host) {
  auto self = std::make_unique<ControlPlaneImpl>();
  if (!self->start(loop, host)) return nullptr;
  return self;
}

}  // namespace lava
