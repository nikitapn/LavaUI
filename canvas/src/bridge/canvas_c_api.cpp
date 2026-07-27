#include "canvas_c_api.h"
#include "canvas_bridge.hpp"
#include "application.hpp"
#include "shell/model.hpp"
#include "window/canvas_window.hpp"

#include <cstring>
#include <iostream>
#include <memory>
#include <mutex>
#include <string>
#include <type_traits>
#include <vector>

// Two embedding modes, same process, no IPC:
//  - offscreen: CanvasBridge (readPixels into host UI) — smoke tests / legacy
//  - windowed:  CanvasWindowHost (GLFW + swapchain present thread)
struct CanvasContext {
  enum class Mode { Offscreen, Windowed };

  Mode mode = Mode::Offscreen;
  std::unique_ptr<CanvasBridge> bridge;
  std::unique_ptr<CanvasWindowHost> window;

  Application *app()
  {
    if (mode == Mode::Windowed) {
      return window ? window->app() : nullptr;
    }
    return bridge ? &bridge->rawApp() : nullptr;
  }

  // For offscreen, bridge owns Application without an extra mutex.
  // For windowed, lock the host mutex around every scene/API call.
  template <typename Fn>
  auto withApp(Fn &&fn) -> decltype(fn(*static_cast<Application *>(nullptr)))
  {
    if (mode == Mode::Windowed) {
      if (!window) {
        using R = decltype(fn(*static_cast<Application *>(nullptr)));
        if constexpr (std::is_void_v<R>) return;
        else return R{};
      }
      std::lock_guard lock(window->mutex());
      Application *a = window->app();
      if (!a) {
        using R = decltype(fn(*static_cast<Application *>(nullptr)));
        if constexpr (std::is_void_v<R>) return;
        else return R{};
      }
      return fn(*a);
    }
    if (!bridge) {
      using R = decltype(fn(*static_cast<Application *>(nullptr)));
      if constexpr (std::is_void_v<R>) return;
      else return R{};
    }
    return fn(bridge->rawApp());
  }
};

// --- Need rawApp on CanvasBridge: add it ---

CanvasContext *canvas_create(
  const char *assets_root, uint32_t width, uint32_t height)
{
  try {
    auto *ctx = new CanvasContext();
    ctx->mode = CanvasContext::Mode::Offscreen;
    ctx->bridge = std::make_unique<CanvasBridge>(
      assets_root ? std::string(assets_root) : std::string(), width, height);
    return ctx;
  } catch (const std::exception &ex) {
    std::cerr << "canvas_create: " << ex.what() << '\n';
    return nullptr;
  } catch (...) {
    std::cerr << "canvas_create: unknown exception\n";
    return nullptr;
  }
}

CanvasContext *canvas_create_window(
  const char *assets_root, uint32_t width, uint32_t height, const char *title)
{
  try {
    auto *ctx = new CanvasContext();
    ctx->mode = CanvasContext::Mode::Windowed;
    ctx->window = std::make_unique<CanvasWindowHost>();
    if (!ctx->window->open(
          assets_root ? std::string(assets_root) : std::string(),
          width, height,
          title ? title : "Canvas")) {
      delete ctx;
      return nullptr;
    }
    return ctx;
  } catch (const std::exception &ex) {
    std::cerr << "canvas_create_window: " << ex.what() << '\n';
    return nullptr;
  } catch (...) {
    std::cerr << "canvas_create_window: unknown exception\n";
    return nullptr;
  }
}

void canvas_destroy(CanvasContext *ctx)
{
  if (!ctx) return;
  if (ctx->window) {
    ctx->window->close();
  }
  delete ctx;
}

bool canvas_window_is_open(CanvasContext *ctx)
{
  return ctx && ctx->window && ctx->window->isOpen();
}

void canvas_window_set_frame(
  CanvasContext *ctx, int x, int y, int width, int height)
{
  if (!ctx || !ctx->window) return;
  ctx->window->setFrame(x, y, width, height);
}

void canvas_window_set_visible(CanvasContext *ctx, bool visible)
{
  if (!ctx || !ctx->window) return;
  ctx->window->setVisible(visible);
}

bool canvas_window_is_visible(CanvasContext *ctx)
{
  if (!ctx || !ctx->window) return false;
  return ctx->window->isVisible();
}

bool canvas_repaint(CanvasContext *ctx)
{
  if (!ctx) return false;
  // Windowed mode paints on its own thread; calling repaint from outside
  // is optional (e.g. after a scene change — next loop iteration also paints).
  if (ctx->mode == CanvasContext::Mode::Windowed) {
    return ctx->withApp([](Application &app) { return app.repaint(); });
  }
  return ctx->bridge && ctx->bridge->repaint();
}

int canvas_add_rect(
  CanvasContext *ctx,
  float x, float y, float width, float height,
  float r, float g, float b, float a)
{
  if (!ctx) return -1;
  return ctx->withApp([&](Application &app) {
    return app.addRect(x, y, width, height, r, g, b, a);
  });
}

void canvas_update_rect(
  CanvasContext *ctx, int id,
  float x, float y, float width, float height,
  float r, float g, float b, float a)
{
  if (!ctx) return;
  ctx->withApp([&](Application &app) {
    app.updateRect(id, x, y, width, height, r, g, b, a);
  });
}

int canvas_add_rounded_rect(
  CanvasContext *ctx,
  float x, float y, float width, float height,
  float r, float g, float b, float a)
{
  if (!ctx) return -1;
  return ctx->withApp([&](Application &app) {
    return app.addRoundedRect(x, y, width, height, r, g, b, a);
  });
}

int canvas_add_circle(
  CanvasContext *ctx,
  float center_x, float center_y, float radius,
  float r, float g, float b, float a)
{
  if (!ctx) return -1;
  return ctx->withApp([&](Application &app) {
    return app.addCircle(center_x, center_y, radius, r, g, b, a);
  });
}

void canvas_remove_shape(CanvasContext *ctx, int id)
{
  if (!ctx) return;
  ctx->withApp([&](Application &app) { app.removeShape(id); });
}

void canvas_clear_shapes(CanvasContext *ctx)
{
  if (!ctx) return;
  ctx->withApp([&](Application &app) { app.clearShapes(); });
}

int canvas_add_line(
  CanvasContext *ctx,
  float x1, float y1, float x2, float y2,
  float r, float g, float b, float a)
{
  if (!ctx) return -1;
  return ctx->withApp([&](Application &app) {
    return app.addLine(x1, y1, x2, y2, r, g, b, a);
  });
}

void canvas_remove_line(CanvasContext *ctx, int id)
{
  if (!ctx) return;
  ctx->withApp([&](Application &app) { app.removeLine(id); });
}

void canvas_clear_lines(CanvasContext *ctx)
{
  if (!ctx) return;
  ctx->withApp([&](Application &app) { app.clearLines(); });
}

int canvas_add_label(
  CanvasContext *ctx,
  const char *text, float x, float y,
  float r, float g, float b)
{
  if (!ctx) return -1;
  return ctx->withApp([&](Application &app) {
    return app.addLabel(text ? std::string(text) : std::string(), x, y, r, g, b);
  });
}

void canvas_remove_label(CanvasContext *ctx, int id)
{
  if (!ctx) return;
  ctx->withApp([&](Application &app) { app.removeLabel(id); });
}

void canvas_clear_labels(CanvasContext *ctx)
{
  if (!ctx) return;
  ctx->withApp([&](Application &app) { app.clearLabels(); });
}

int canvas_add_text_widget(
  CanvasContext *ctx,
  float x, float y, float width, float height,
  const char *text, bool multiline)
{
  if (!ctx) return -1;
  return ctx->withApp([&](Application &app) {
    return app.addTextWidget(
      x, y, width, height, text ? std::string(text) : std::string(), multiline);
  });
}

void canvas_set_text_widget_rect(
  CanvasContext *ctx, int id,
  float x, float y, float width, float height)
{
  if (!ctx) return;
  ctx->withApp([&](Application &app) {
    app.setTextWidgetRect(id, x, y, width, height);
  });
}

void canvas_set_text_widget_text(CanvasContext *ctx, int id, const char *text)
{
  if (!ctx) return;
  ctx->withApp([&](Application &app) {
    app.setTextWidgetText(id, text ? std::string(text) : std::string());
  });
}

int canvas_get_text_widget_text(
  CanvasContext *ctx, int id, char *out, size_t cap)
{
  if (!ctx) return 0;
  std::string text = ctx->withApp([&](Application &app) {
    return app.getTextWidgetText(id);
  });
  if (out && cap > 0) {
    size_t n = text.size();
    size_t copy = n < (cap - 1) ? n : (cap - 1);
    if (copy > 0) std::memcpy(out, text.data(), copy);
    out[copy] = '\0';
  }
  return static_cast<int>(text.size());
}

bool canvas_set_text_widget_highlight_rules(
  CanvasContext *ctx, int id,
  const CanvasHighlightRule *rules, int count)
{
  if (!ctx) return false;
  std::vector<TextHighlightRule> converted;
  if (rules && count > 0) {
    converted.reserve(static_cast<size_t>(count));
    for (int i = 0; i < count; ++i) {
      TextHighlightRule r;
      r.pattern = rules[i].pattern ? rules[i].pattern : "";
      r.r = rules[i].r;
      r.g = rules[i].g;
      r.b = rules[i].b;
      r.a = rules[i].a;
      r.priority = rules[i].priority;
      r.capture_group = rules[i].capture_group;
      converted.push_back(std::move(r));
    }
  }
  return ctx->withApp([&](Application &app) {
    return app.setTextWidgetHighlightRules(id, converted);
  });
}

void canvas_set_text_widget_focused(CanvasContext *ctx, int id, bool focused)
{
  if (!ctx) return;
  ctx->withApp([&](Application &app) { app.setTextWidgetFocused(id, focused); });
}

bool canvas_is_text_widget_focused(CanvasContext *ctx, int id)
{
  if (!ctx) return false;
  return ctx->withApp([&](Application &app) {
    return app.isTextWidgetFocused(id);
  });
}

bool canvas_text_widget_changed(CanvasContext *ctx, int id)
{
  if (!ctx) return false;
  return ctx->withApp([&](Application &app) {
    return app.textWidgetChanged(id);
  });
}

void canvas_remove_text_widget(CanvasContext *ctx, int id)
{
  if (!ctx) return;
  ctx->withApp([&](Application &app) { app.removeTextWidget(id); });
}

bool canvas_wants_animation(CanvasContext *ctx)
{
  if (!ctx) return false;
  return ctx->withApp([&](Application &app) { return app.wantsAnimation(); });
}

void canvas_set_project_tree(
  CanvasContext *ctx, const CanvasTreeItem *items, int count)
{
  if (!ctx) return;
  std::vector<canvas::TreeItem> converted;
  if (items && count > 0) {
    converted.reserve(static_cast<size_t>(count));
    for (int i = 0; i < count; ++i) {
      canvas::TreeItem t;
      t.id = items[i].id ? items[i].id : "";
      t.label = items[i].label ? items[i].label : "";
      t.depth = items[i].depth;
      t.selected = items[i].selected;
      converted.push_back(std::move(t));
    }
  }
  ctx->withApp([&](Application &app) {
    app.setProjectTree(std::move(converted));
  });
}

void canvas_set_properties(
  CanvasContext *ctx, const CanvasPropertyItem *items, int count)
{
  if (!ctx) return;
  std::vector<canvas::PropertyItem> converted;
  if (items && count > 0) {
    converted.reserve(static_cast<size_t>(count));
    for (int i = 0; i < count; ++i) {
      canvas::PropertyItem p;
      p.key = items[i].key ? items[i].key : "";
      p.value = items[i].value ? items[i].value : "";
      converted.push_back(std::move(p));
    }
  }
  ctx->withApp([&](Application &app) {
    app.setProperties(std::move(converted));
  });
}

int canvas_selected_tree_id(CanvasContext *ctx, char *out, size_t cap)
{
  if (!ctx) return 0;
  std::string id = ctx->withApp(
    [](Application &app) { return app.selectedTreeId(); });
  if (out && cap > 0) {
    size_t n = id.size();
    size_t copy = n < (cap - 1) ? n : (cap - 1);
    if (copy > 0) std::memcpy(out, id.data(), copy);
    out[copy] = '\0';
  }
  return static_cast<int>(id.size());
}

void canvas_diagram_viewport(
  CanvasContext *ctx, float *x, float *y, float *w, float *h)
{
  if (!ctx) return;
  shell::Rect r = ctx->withApp(
    [](Application &app) { return app.diagramViewport(); });
  if (x) *x = r.x;
  if (y) *y = r.y;
  if (w) *w = r.w;
  if (h) *h = r.h;
}

void canvas_pointer_move(CanvasContext *ctx, float x, float y)
{
  if (!ctx) return;
  // Windowed mode gets input from GLFW; bridge is for offscreen embeds.
  if (ctx->mode == CanvasContext::Mode::Windowed) return;
  ctx->withApp([&](Application &app) { app.pointerMove(x, y); });
}

void canvas_pointer_button(
  CanvasContext *ctx, int button, bool pressed, float x, float y)
{
  if (!ctx) return;
  if (ctx->mode == CanvasContext::Mode::Windowed) return;
  ctx->withApp([&](Application &app) {
    app.pointerButton(button, pressed, x, y);
  });
}

void canvas_key_event(CanvasContext *ctx, int key, int action, int mods)
{
  if (!ctx) return;
  if (ctx->mode == CanvasContext::Mode::Windowed) return;
  ctx->withApp([&](Application &app) { app.keyEvent(key, action, mods); });
}

void canvas_text_input(CanvasContext *ctx, const char *utf8)
{
  if (!ctx || !utf8) return;
  if (ctx->mode == CanvasContext::Mode::Windowed) return;
  ctx->withApp([&](Application &app) { app.textInput(utf8); });
}

void canvas_read_pixels(CanvasContext *ctx, uint8_t *dst, size_t dst_size)
{
  if (!ctx) return;
  if (ctx->mode == CanvasContext::Mode::Windowed) {
    // No readback on the windowed hot path.
    return;
  }
  if (ctx->bridge) ctx->bridge->readPixels(dst, dst_size);
}
