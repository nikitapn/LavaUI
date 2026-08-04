#include "window/app_window.hpp"

#include <algorithm>
#include <iostream>
#include <stdexcept>

#include "render/render_device.hpp"
#include "render/render_window.hpp"
#include "util/key_codes.hpp"

#define GLFW_INCLUDE_VULKAN
#include <GLFW/glfw3.h>
#if defined(CANVAS_HAVE_X11)
#define GLFW_EXPOSE_NATIVE_X11
#include <GLFW/glfw3native.h>
#endif

AppWindow::AppWindow(RenderDevice &device, uint32_t id, int width, int height,
                     const std::string &title)
  : id_{id}
{
  // Window creation lives here rather than in RenderWindow: these hints are
  // app policy, and a compositor handing us a surface from somewhere else
  // should not have to go through GLFW at all.
  glfwWindowHint(GLFW_CLIENT_API, GLFW_NO_API);
  glfwWindowHint(GLFW_RESIZABLE, GLFW_TRUE);
  // Prefer not stealing focus from an already-open window.
  glfwWindowHint(GLFW_FOCUS_ON_SHOW, GLFW_FALSE);
  // Created hidden and shown by setWindowVisible, so nothing is presented
  // before the first frame has been drawn into it.
  glfwWindowHint(GLFW_VISIBLE, GLFW_FALSE);

  glfw_ = glfwCreateWindow(width < 1 ? 1 : width, height < 1 ? 1 : height,
                           title.empty() ? "Canvas" : title.c_str(), nullptr,
                           nullptr);
  if (!glfw_) throw std::runtime_error("glfwCreateWindow failed");

  try {
    render_ = std::make_unique<RenderWindow>(device, glfw_);
  } catch (...) {
    glfwDestroyWindow(glfw_);
    glfw_ = nullptr;
    throw;
  }

  installGlfwCallbacks();
}

AppWindow::AppWindow(RenderDevice &device, uint32_t id, int width, int height)
  : id_{id}
{
  render_ = std::make_unique<RenderWindow>(
    device, static_cast<uint32_t>(width < 1 ? 1 : width),
    static_cast<uint32_t>(height < 1 ? 1 : height));
}

AppWindow::~AppWindow()
{
  // Renderer first: it holds a surface made from this GLFW window.
  render_.reset();
  if (glfw_) {
    glfwDestroyWindow(glfw_);
    glfw_ = nullptr;
  }
}

void AppWindow::initRenderers()
{
  render_->initRenderers();
}

canvas::DrawList AppWindow::currentDrawList() const
{
  return canvas::DrawList{
    .commands           = drawCmds_.data(),
    .commandCount       = drawCmdCount_,
    .glyphs             = drawGlyphs_.data(),
    .glyphCount         = drawGlyphCount_,
    .meshVertices       = drawMeshVerts_.data(),
    .meshVertexCount    = drawMeshVertCount_,
    .spatialVertices    = drawSpatialVerts_.data(),
    .spatialVertexCount = drawSpatialVertCount_,
  };
}

bool AppWindow::repaint()
{
  try {
    if (render_->resize()) {
      // Tell the producer so it re-lays-out and resubmits. Without this the
      // old fixed-size command list is presented into the new framebuffer.
      canvas::InputEvent ev;
      ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Resize);
      ev.x = static_cast<float>(render_->getExtent().width);
      ev.y = static_cast<float>(render_->getExtent().height);
      ev.button = 0;
      std::lock_guard lock(inputMu_);
      inputEvents_.push_back(ev);
    }

    stepSceneAnimations();

    if (arena_) {
      // A producer that has published nothing since the last repaint leaves
      // `arenaFrame_` alone, so a resize or an expose still redraws the frame
      // we are holding rather than an empty one.
      if (arena_->acquireFrame(arenaFrame_)) arenaHasFrame_ = true;
      if (!arenaHasFrame_) return true;
      render_->render(arenaFrame_);
      noteSceneResume();
      return true;
    }

    render_->render(currentDrawList());
    noteSceneResume();
    return true;
  } catch (std::exception &ex) {
    std::cerr << ex.what() << '\n';
    return false;
  }
}

/// Steps node animations and tells the producer where they got to.
///
/// Called once per repaint, before the frame is drawn, so the offsets the
/// composer reads are the ones this step produced.
/// Re-answers hover, repaints if it changed, and tells the producer.
///
/// One function because the three always go together: the tint the renderer
/// draws and the node id the producer is told must never be different
/// answers to the same question.
void AppWindow::noteSceneHover(float x, float y)
{
  if (!render_ || !render_->updateSceneHover(x, y)) return;
  internalRepaint_ = true;

  canvas::InputEvent ev;
  ev.kind   = static_cast<uint32_t>(canvas::InputEventKind::NodeHover);
  ev.button = static_cast<int32_t>(render_->hoveredSceneNode());
  std::lock_guard lock(inputMu_);
  // Against the back only. A run of hover changes as the pointer crosses a
  // list collapses to the newest, but one separated by a MouseDown survives
  // — that adjacency is what tells the producer which node a click was for.
  if (!inputEvents_.empty() && inputEvents_.back().kind == ev.kind) {
    inputEvents_.back() = ev;
  } else {
    inputEvents_.push_back(ev);
  }
}

bool AppWindow::scrollSceneUnclaimed(float dx, float dy)
{
  // The producer walked its own chain, found nothing that wanted this notch,
  // and handed it back. Everything it *might* have used is now known not to
  // want it, so the deference that made `scroll` decline no longer applies.
  if (!render_ || !render_->scrollSceneNode(pointerX_, pointerY_, dx, dy,
                                            /*ignoreWheelClaims=*/true))
    return false;
  internalRepaint_ = true;
  glfwPostEmptyEvent();
  return true;
}

/// Asks for one more frame when a publish gave a parked scroll room to move.
///
/// After the render, not before: the span that decides this arrives with the
/// list, and `stepSceneAnimations` has already run for this frame against the
/// previous one. Skipping the frame would leave the scroll stopped short of a
/// target the producer has since drawn the content for — which looks exactly
/// like a scroll that ignored half the flick.
void AppWindow::noteSceneResume()
{
  if (!render_ || !render_->takeSceneResume()) return;
  internalRepaint_ = true;
  glfwPostEmptyEvent();
}

void AppWindow::stepSceneAnimations()
{
  if (!render_) return;
  // Content scrolling under a stationary pointer changes what is beneath it
  // just as surely as moving the pointer does, so hover is re-answered every
  // frame and not only on motion.
  noteSceneHover(pointerX_, pointerY_);
  sceneMovedScratch_.clear();
  sceneFinishedScratch_.clear();
  const bool animating = render_->advanceSceneAnimations(
    glfwGetTime(), sceneMovedScratch_, sceneFinishedScratch_);

  if (!sceneMovedScratch_.empty()) {
    std::lock_guard lock(inputMu_);
    for (const auto &moved : sceneMovedScratch_) {
      canvas::InputEvent ev;
      ev.kind   = static_cast<uint32_t>(canvas::InputEventKind::NodeScroll);
      ev.button = static_cast<int32_t>(moved.id);
      ev.x      = moved.x;
      ev.y      = moved.y;
      // Coalesced per node: an animating scroll emits one of these per frame,
      // and only the newest position says anything the older ones did not.
      // Scanned rather than compared against the back of the queue, because
      // two nodes can be animating at once and would otherwise take turns
      // failing to coalesce.
      auto existing = std::find_if(
        inputEvents_.begin(), inputEvents_.end(),
        [&](const canvas::InputEvent &queued) {
          return queued.kind == ev.kind && queued.button == ev.button;
        });
      if (existing != inputEvents_.end()) {
        *existing = ev;
      } else {
        inputEvents_.push_back(ev);
      }
    }
  }

  if (!sceneFinishedScratch_.empty()) {
    std::lock_guard lock(inputMu_);
    for (const uint32_t id : sceneFinishedScratch_) {
      canvas::InputEvent ev;
      ev.kind   = static_cast<uint32_t>(
        canvas::InputEventKind::NodeAnimationDone);
      ev.button = static_cast<int32_t>(id);
      // Not coalesced, unlike `NodeScroll`. A position is a state and only
      // the newest one matters; an arrival is an event, and dropping it
      // loses the thing it was for.
      inputEvents_.push_back(ev);
    }
  }

  if (animating) {
    // An animation is a repaint nobody asked for, so nothing else will ask
    // for the next one. The flag makes the frame loop draw it; the empty
    // event stops the loop parking in `pumpEvents` before it does.
    internalRepaint_ = true;
    glfwPostEmptyEvent();
  }
}

bool AppWindow::attachDrawArena(const std::string &id)
{
  auto arena = std::make_unique<canvas::ipc::DrawArena>();
  if (!arena->open(id)) return false;
  arena_         = std::move(arena);
  arenaHasFrame_ = false;
  arenaFrame_    = {};
  // Node ids are a producer's private numbering, so the scroll offsets held
  // against the old producer's ids mean nothing to the new one — and would
  // otherwise apply themselves to whatever happened to reuse an id.
  if (render_) render_->resetSceneState();
  std::cout << "Window " << id_ << " attached to draw arena '" << id
            << "' (generation " << arena_->generation() << ", "
            << arena_->mappedBytes() / 1024 << " KiB)\n";
  return true;
}

void AppWindow::detachDrawArena()
{
  if (!arena_) return;
  // The renderer may be one frame from presenting what this points into, so
  // drop the view before the mapping it refers to goes away.
  arenaFrame_    = {};
  arenaHasFrame_ = false;
  arena_.reset();
}

bool AppWindow::windowShouldClose() const
{
  return render_->windowShouldClose();
}

void AppWindow::requestClose() { render_->requestClose(); }

void AppWindow::setWindowFrame(int x, int y, int width, int height)
{
  render_->setWindowFrame(x, y, width, height);
}

void AppWindow::setWindowVisible(bool visible)
{
  render_->setWindowVisible(visible);
  visible_ = visible;
}

bool AppWindow::isIconified() const
{
  if (!glfw_) return false;
  return glfwGetWindowAttrib(glfw_, GLFW_ICONIFIED) != 0;
}

uint32_t AppWindow::x11WindowId() const
{
#if defined(CANVAS_HAVE_X11)
  if (!glfw_) return 0;
  if (glfwGetPlatform() != GLFW_PLATFORM_X11) return 0;
  return static_cast<uint32_t>(glfwGetX11Window(glfw_));
#else
  return 0;
#endif
}

void AppWindow::captureFrame(uint8_t *dst, size_t dstSize)
{
  render_->captureFrame(dst, dstSize);
}

bool AppWindow::capturePng(std::vector<uint8_t> &outPng, int x, int y, int w,
                           int h, int maxSide, int *outW, int *outH)
{
  return render_->capturePng(outPng, x, y, w, h, maxSide, outW, outH);
}

void AppWindow::installGlfwCallbacks()
  {
    GLFWwindow *win = glfw_;
    if (!win) return;
    glfwSetWindowUserPointer(win, this);

    glfwSetCursorPosCallback(win, [](GLFWwindow *w, double x, double y) {
      auto *self = static_cast<AppWindow *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      self->pointerMove(static_cast<float>(x), static_cast<float>(y));
    });

    glfwSetMouseButtonCallback(win, [](GLFWwindow *w, int button, int action, int mods) {
      auto *self = static_cast<AppWindow *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      double x = 0, y = 0;
      glfwGetCursorPos(w, &x, &y);
      self->pointerButton(
        button, action == GLFW_PRESS, static_cast<float>(x), static_cast<float>(y), mods);
    });

    glfwSetKeyCallback(win, [](GLFWwindow *w, int key, int /*scancode*/, int action, int mods) {
      auto *self = static_cast<AppWindow *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      // GLFW action/mods already match our key_codes.hpp conventions.
      self->keyEvent(key, action, mods);
    });

    glfwSetScrollCallback(win, [](GLFWwindow *w, double dx, double dy) {
      auto *self = static_cast<AppWindow *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      self->scroll(static_cast<float>(dx), static_cast<float>(dy));
    });

    glfwSetCharCallback(win, [](GLFWwindow *w, unsigned int codepoint) {
      auto *self = static_cast<AppWindow *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      self->charInput(codepoint);
    });

    // Live drag-resize: notify Swift on every framebuffer change. Without this,
    // Resize was only enqueued inside repaint()→ensureFramebufferSize(), so the
    // idle loop (wait for events, no work → no repaint) never saw size changes
    // until something else dirtied the frame.
    glfwSetFramebufferSizeCallback(win, [](GLFWwindow *w, int width, int height) {
      auto *self = static_cast<AppWindow *>(glfwGetWindowUserPointer(w));
      if (!self || width < 1 || height < 1) return;
      canvas::InputEvent ev;
      ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Resize);
      ev.x = static_cast<float>(width);
      ev.y = static_cast<float>(height);
      ev.button = 0;
      {
        std::lock_guard lock(self->inputMu_);
        // Coalesce: keep only the latest size if several arrive before poll.
        if (!self->inputEvents_.empty() &&
            self->inputEvents_.back().kind ==
              static_cast<uint32_t>(canvas::InputEventKind::Resize)) {
          self->inputEvents_.back() = ev;
        } else {
          self->inputEvents_.push_back(ev);
        }
      }
    });

    // Damage / expose: compositor asks for a redraw (also fires after some
    // un-minimize paths). Pure redraw — swapchain size is unchanged.
    glfwSetWindowRefreshCallback(win, [](GLFWwindow *w) {
      auto *self = static_cast<AppWindow *>(glfwGetWindowUserPointer(w));
      if (!self) return;
      self->queueRefreshEvent();
    });

    // Minimize → restore: always force a present. Refresh alone is not
    // reliable on every WM; iconify(false) is the definitive un-minimize signal.
    glfwSetWindowIconifyCallback(win, [](GLFWwindow *w, int iconified) {
      auto *self = static_cast<AppWindow *>(glfwGetWindowUserPointer(w));
      if (!self || iconified) return;  // ignore going to tray
      self->queueRefreshEvent();
    });

    glfwSetDropCallback(win, [](GLFWwindow *w, int count, const char **paths) {
      auto *self = static_cast<AppWindow *>(glfwGetWindowUserPointer(w));
      if (!self || count <= 0) return;
      double x = 0, y = 0;
      glfwGetCursorPos(w, &x, &y);
      canvas::InputEvent ev;
      ev.kind = static_cast<uint32_t>(canvas::InputEventKind::FileDrop);
      ev.x = static_cast<float>(x);
      ev.y = static_cast<float>(y);
      ev.button = count;
      {
        std::lock_guard lock(self->inputMu_);
        // Overwritten by the next drop, same as every other "pull the
        // payload while handling this event" queue in this file — nothing
        // needs more than one pending drop at a time.
        self->droppedPaths_.assign(paths, paths + count);
        self->inputEvents_.push_back(ev);
      }
    });
  }

void AppWindow::queueRefreshEvent()
  {
    canvas::InputEvent ev;
    ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Refresh);
    ev.x = 0.f;
    ev.y = 0.f;
    ev.button = 0;
    std::lock_guard lock(inputMu_);
    // One is enough until the app paints again.
    if (!inputEvents_.empty() &&
        inputEvents_.back().kind ==
          static_cast<uint32_t>(canvas::InputEventKind::Refresh)) {
      return;
    }
    inputEvents_.push_back(ev);
  }

void AppWindow::pointerMove(float x, float y)
  {
    // Hover highlighting needs free motion too, not just drags — but motion
    // arrives per pixel and the queue is unbounded. Coalescing keeps at most
    // one pending move: consumers only ever want the latest position, and a
    // superseded one carries no information.
    // Kept because a wheel event carries no position of its own, and "which
    // node is under the pointer" is the only question that decides what a
    // scroll means.
    pointerX_ = x;
    pointerY_ = y;
    // Hover is the renderer's to answer: it has the pointer and the node
    // geometry, and the producer would only be recomputing what is already
    // known here — at the cost of a round trip and a whole re-emit per
    // motion event.
    noteSceneHover(x, y);

    canvas::InputEvent ev;
    ev.kind = static_cast<uint32_t>(canvas::InputEventKind::MouseMove);
    ev.x = x;
    ev.y = y;
    ev.button = pointerDown_ ? 1 : 0;  // so Swift can tell drag from hover
    {
      std::lock_guard lock(inputMu_);
      if (!inputEvents_.empty() &&
          inputEvents_.back().kind ==
            static_cast<uint32_t>(canvas::InputEventKind::MouseMove)) {
        inputEvents_.back() = ev;
      } else {
        inputEvents_.push_back(ev);
      }
    }
  }

  // mods is only ever non-zero from the live GLFW callback below — injected
  // clicks (Application::pointerButton, used by Swift/agent input) have no
  // modifier source and keep the 0 default.
void AppWindow::pointerButton(int button, bool pressed, float x, float y, int mods)
{
    // Queue raw input for Swift hit-testing (Phase 3+).
    if (button == MOUSE_BUTTON_1) {
      pointerDown_ = pressed;
      // Feedback is drawn here; the event still goes to the producer below.
      // Unlike a scroll this is not consumed — a press *means* something, and
      // only the producer knows what. The renderer paints it, it does not
      // interpret it.
      pointerX_ = x;
      pointerY_ = y;
      // Before the MouseDown is queued below, so the producer reads the two
      // in the order that pairs them: "this node", then "was clicked".
      noteSceneHover(x, y);
      if (render_ && render_->updateScenePress(pressed)) {
        internalRepaint_ = true;
      }
      canvas::InputEvent ev;
      ev.kind =
          static_cast<uint32_t>(pressed ? canvas::InputEventKind::MouseDown
                                        : canvas::InputEventKind::MouseUp);
      ev.x = x;
      ev.y = y;
      ev.button = button;
      ev.mods = mods;
      {
        std::lock_guard lock(inputMu_);
        inputEvents_.push_back(ev);
      }
    }

  }

void AppWindow::keyEvent(int key, int action, int mods)
  {
    // Only the modifiers are tracked: they are the one piece of key state a
    // later event (a wheel notch) has to consult. Everything else about a key
    // travels with its own event.
    if (action == ACTION_PRESS || action == ACTION_RELEASE) {
      const bool down = (action == ACTION_PRESS);
      if (key == GLFW_KEY_LEFT_SHIFT || key == GLFW_KEY_RIGHT_SHIFT) {
        shiftDown_ = down;
      }
      if (key == GLFW_KEY_LEFT_CONTROL || key == GLFW_KEY_RIGHT_CONTROL) {
        ctrlDown_ = down;
      }
    }

    // Forward to Swift (zoom, shortcuts). Use full GLFW key range.
    if (action == ACTION_PRESS || action == ACTION_REPEAT || action == ACTION_RELEASE) {
      canvas::InputEvent ev;
      ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Key);
      ev.button = key;
      ev.x = static_cast<float>(action);
      ev.y = static_cast<float>(mods);
      {
        std::lock_guard lock(inputMu_);
        inputEvents_.push_back(ev);
      }
    }

  }

void AppWindow::setViewTransform(float zoom, float panX, float panY)
  {
    viewZoom_ = zoom > 0.f ? zoom : 1.f;
    viewPanX_ = panX;
    viewPanY_ = panY;
    render_->setViewTransform(viewZoom_, viewPanX_, viewPanY_);
  }

void AppWindow::textInput(const std::string &utf8)
  {
    // Agent / synthetic path: expand UTF-8 into one Text event per codepoint
    // (same queue as GLFW char callback → charInput).
    size_t i = 0;
    while (i < utf8.size()) {
      unsigned char c = static_cast<unsigned char>(utf8[i]);
      uint32_t cp = 0;
      size_t n = 0;
      if (c < 0x80) {
        cp = c;
        n = 1;
      } else if ((c & 0xE0) == 0xC0 && i + 1 < utf8.size()) {
        cp = (c & 0x1F) << 6 | (static_cast<unsigned char>(utf8[i + 1]) & 0x3F);
        n = 2;
      } else if ((c & 0xF0) == 0xE0 && i + 2 < utf8.size()) {
        cp = (c & 0x0F) << 12 |
             (static_cast<unsigned char>(utf8[i + 1]) & 0x3F) << 6 |
             (static_cast<unsigned char>(utf8[i + 2]) & 0x3F);
        n = 3;
      } else if ((c & 0xF8) == 0xF0 && i + 3 < utf8.size()) {
        cp = (c & 0x07) << 18 |
             (static_cast<unsigned char>(utf8[i + 1]) & 0x3F) << 12 |
             (static_cast<unsigned char>(utf8[i + 2]) & 0x3F) << 6 |
             (static_cast<unsigned char>(utf8[i + 3]) & 0x3F);
        n = 4;
      } else {
        ++i;
        continue;
      }
      charInput(cp);
      i += n;
    }
  }

void AppWindow::scroll(float dx, float dy)
  {
    // Offered to the scene graph first. If a node took it, the wheel moved a
    // subtree the renderer owns and the producer is not involved at all —
    // not told, not woken, not waited for. That is the whole point of a
    // retained tree: this window can scroll while the process that drew it
    // is stopped.
    if (render_ && render_->scrollSceneNode(pointerX_, pointerY_, dx, dy)) {
      internalRepaint_ = true;
      return;
    }

    canvas::InputEvent ev;
    ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Scroll);
    ev.x = dx;
    ev.y = dy;
    // Modifiers travel with the event so Ctrl+wheel can be distinguished
    // without Swift tracking key state itself.
    int mods = 0;
    if (shiftDown_) mods |= 0x0001;
    if (ctrlDown_) mods |= 0x0002;
    ev.button = mods;
    {
      std::lock_guard lock(inputMu_);
      // Coalesce: only the accumulated delta matters, and a wheel can emit
      // faster than the frame loop consumes.
      if (!inputEvents_.empty() &&
          inputEvents_.back().kind ==
            static_cast<uint32_t>(canvas::InputEventKind::Scroll)) {
        inputEvents_.back().x += ev.x;
        inputEvents_.back().y += ev.y;
      } else {
        inputEvents_.push_back(ev);
      }
    }
  }

  /// Queues one committed character for Swift. This is the only reliable
  /// source of "what did the user type": key codes are physical and say
  /// nothing about layout, dead keys, or shift state.
void AppWindow::charInput(unsigned int codepoint)
  {
    canvas::InputEvent ev;
    ev.kind = static_cast<uint32_t>(canvas::InputEventKind::Text);
    ev.button = static_cast<int32_t>(codepoint);
    {
      std::lock_guard lock(inputMu_);
      inputEvents_.push_back(ev);
    }
  }

std::string AppWindow::clipboardText() const
  {
    if (!render_->isWindowed() || !glfw_) return {};
    const char *s = glfwGetClipboardString(glfw_);
    return s ? std::string(s) : std::string{};
  }

void AppWindow::setClipboardText(const std::string &text)
  {
    if (!render_->isWindowed() || !glfw_) return;
    glfwSetClipboardString(glfw_, text.c_str());
  }

void AppWindow::readPixels(uint8_t *dst, size_t dstSize)
  {
    render_->readPixels(dst, dstSize);
  }

void AppWindow::submitDrawList(const canvas::DrawCommand *cmds, size_t cmdCount,
                      const canvas::GlyphInstance *glyphs, size_t glyphCount,
                      const canvas::MeshVertex *meshVerts, size_t meshVertCount,
                      const canvas::SpatialVertex *spatialVerts, size_t spatialVertCount)
  {
    drawCmds_.assign(cmds, cmds + cmdCount);
    drawGlyphs_.assign(glyphs, glyphs + glyphCount);
    drawMeshVerts_.assign(meshVerts, meshVerts + meshVertCount);
    drawSpatialVerts_.assign(spatialVerts, spatialVerts + spatialVertCount);
    drawCmdCount_ = cmdCount;
    drawGlyphCount_ = glyphCount;
    drawMeshVertCount_ = meshVertCount;
    drawSpatialVertCount_ = spatialVertCount;
  }

void AppWindow::ensureDrawListCapacity(size_t cmdCapacity, size_t glyphCapacity,
                              size_t meshVertCapacity, size_t spatialVertCapacity)
  {
    if (drawCmds_.size() < cmdCapacity) drawCmds_.resize(cmdCapacity);
    if (drawGlyphs_.size() < glyphCapacity) drawGlyphs_.resize(glyphCapacity);
    if (drawMeshVerts_.size() < meshVertCapacity) {
      drawMeshVerts_.resize(meshVertCapacity);
    }
    if (drawSpatialVerts_.size() < spatialVertCapacity) {
      drawSpatialVerts_.resize(spatialVertCapacity);
    }
  }

void AppWindow::commitDrawList(size_t cmdCount, size_t glyphCount, size_t meshVertCount,
                      size_t spatialVertCount)
  {
    drawCmdCount_ = std::min(cmdCount, drawCmds_.size());
    drawGlyphCount_ = std::min(glyphCount, drawGlyphs_.size());
    drawMeshVertCount_ = std::min(meshVertCount, drawMeshVerts_.size());
    drawSpatialVertCount_ = std::min(spatialVertCount, drawSpatialVerts_.size());
  }

bool AppWindow::pollInputEvent(canvas::InputEvent &out)
  {
    std::lock_guard lock(inputMu_);
    if (inputEvents_.empty()) return false;
    out = inputEvents_.front();
    inputEvents_.pop_front();
    return true;
  }

int AppWindow::pendingDroppedFileCount()
  {
    std::lock_guard lock(inputMu_);
    return static_cast<int>(droppedPaths_.size());
  }

std::string AppWindow::pendingDroppedFile(int index)
  {
    std::lock_guard lock(inputMu_);
    if (index < 0 || static_cast<size_t>(index) >= droppedPaths_.size()) return {};
    return droppedPaths_[index];
  }

void AppWindow::framebufferSize(float &outW, float &outH) const
  {
    // Prefer the *live* GLFW size so the Swift safety net sees drag-resize
    // before ensureFramebufferSize() updates the swapchain extent.
    if (render_->isWindowed() && glfw_) {
      int fbW = 0, fbH = 0;
      glfwGetFramebufferSize(glfw_, &fbW, &fbH);
      if (fbW >= 1 && fbH >= 1) {
        outW = static_cast<float>(fbW);
        outH = static_cast<float>(fbH);
        return;
      }
    }
    const auto e = render_->getExtent();
    outW = static_cast<float>(e.width);
    outH = static_cast<float>(e.height);
}
