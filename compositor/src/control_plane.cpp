#include "control_plane.hpp"

#include <sys/eventfd.h>
#include <unistd.h>

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
  CompositorImpl(CompositorHost &host, LoopQueue &loop, InputBroker &broker)
      : host_(host), loop_(loop), broker_(broker) {}

  // ─── Resources ───────────────────────────────────────────────────────────

  uint32_t RegisterFont(nprpc::flat::Span<char> path, float pixelSize) override {
    const std::string file{path};
    const int id = host_.registerFont(file, pixelSize);
    if (id < 0) throw FontNotFound(file);
    return static_cast<uint32_t>(id);
  }

  // Images are not wired through yet. Raising is the honest answer — a client
  // gets a typed refusal at the call rather than a texture id that resolves to
  // nothing at draw time.
  ImageInfo RegisterImage(nprpc::flat::Span<char> path, uint32_t) override {
    throw ImageNotFound(std::string{path});
  }

  ImageInfo RegisterImageData(nprpc::flat::Span<uint8_t>, uint32_t) override {
    throw ImageNotFound("<bytes>");
  }

  void ReleaseImage(uint32_t) override {}

  // ─── Surfaces ────────────────────────────────────────────────────────────

  uint32_t CreateSurface(nprpc::flat::Span<char> arenaId, uint32_t width,
                         uint32_t height,
                         nprpc::flat::Span<char> title) override {
    const std::string arena{arenaId};
    const uint32_t id =
        host_.createSurface(arena, width, height, std::string{title});
    if (id == 0) throw ArenaNotFound(arena);
    return id;
  }

  void DestroySurface(uint32_t surfaceId) override {
    if (!host_.destroySurface(surfaceId)) throw SurfaceNotFound(surfaceId);
    broker_.closeAll(surfaceId);
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

  CompositorHost &host_;
  LoopQueue &loop_;
  InputBroker &broker_;
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

    servant_ = std::make_unique<CompositorImpl>(host, queue_, broker_);
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

 private:
  LoopQueue queue_;
  InputBroker broker_;
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
