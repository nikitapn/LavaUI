#include "bridge/swift_editor.hpp"

#include "bridge/canvas_engine.hpp"
#include "render/text_widget.hpp"
#include "shell/layout.hpp"

#include <cstring>
#include <iostream>
#include <string>
#include <vector>

namespace canvas {

struct SwiftEditor {
  Engine engine;
};

SwiftEditor *swiftEditorCreate(const char *assetsRoot, int width, int height,
                               const char *title)
{
  auto *self = new SwiftEditor();
  auto r = self->engine.openWindow(
    assetsRoot ? assetsRoot : "",
    static_cast<uint32_t>(width),
    static_cast<uint32_t>(height),
    title ? title : "FBD Editor");
  if (!r) {
    std::cerr << "swiftEditorCreate: " << r.error() << '\n';
    delete self;
    return nullptr;
  }
  self->engine.setWindowVisible(true);
  return self;
}

void swiftEditorDestroy(SwiftEditor *editor)
{
  delete editor;
}

bool swiftEditorIsOpen(const SwiftEditor *editor)
{
  return editor && editor->engine.isOpen();
}

void swiftEditorSetVisible(SwiftEditor *editor, bool visible)
{
  if (editor) editor->engine.setWindowVisible(visible);
}

void swiftEditorSetWorkspaceColumns(SwiftEditor *editor, int leftPanel,
                                    int centerPanel, int rightPanel,
                                    float leftWidth, float rightWidth)
{
  if (!editor) return;
  auto asPanel = [](int v) -> shell::PanelKind {
    switch (v) {
    case 0: return shell::PanelKind::ProjectTree;
    case 1: return shell::PanelKind::Diagram;
    case 2: return shell::PanelKind::Properties;
    case 3: return shell::PanelKind::Log;
    default: return shell::PanelKind::Diagram;
    }
  };
  editor->engine.setWorkspaceColumns(
    asPanel(leftPanel), asPanel(centerPanel), asPanel(rightPanel),
    leftWidth, rightWidth);
}

void swiftEditorSetProjectTree(SwiftEditor *editor, const char *const *ids,
                               const char *const *labels, const int *depths,
                               const bool *selected, int count)
{
  if (!editor || count < 0) return;
  std::vector<TreeItem> items;
  items.reserve(static_cast<size_t>(count));
  for (int i = 0; i < count; ++i) {
    TreeItem t;
    t.id = ids && ids[i] ? ids[i] : "";
    t.label = labels && labels[i] ? labels[i] : "";
    t.depth = depths ? depths[i] : 0;
    t.selected = selected ? selected[i] : false;
    items.push_back(std::move(t));
  }
  editor->engine.setProjectTree(std::move(items));
}

void swiftEditorSetProperties(SwiftEditor *editor, const char *const *keys,
                              const char *const *values, int count)
{
  if (!editor || count < 0) return;
  std::vector<PropertyItem> items;
  items.reserve(static_cast<size_t>(count));
  for (int i = 0; i < count; ++i) {
    PropertyItem p;
    p.key = keys && keys[i] ? keys[i] : "";
    p.value = values && values[i] ? values[i] : "";
    items.push_back(std::move(p));
  }
  editor->engine.setProperties(std::move(items));
}

int swiftEditorSelectedTreeId(const SwiftEditor *editor, char *buf, int cap)
{
  if (!editor) return 0;
  std::string id = editor->engine.selectedTreeId();
  if (buf && cap > 0) {
    const int n = static_cast<int>(id.size());
    const int copy = n < cap - 1 ? n : cap - 1;
    if (copy > 0) std::memcpy(buf, id.data(), static_cast<size_t>(copy));
    buf[copy] = '\0';
  }
  return static_cast<int>(id.size());
}

int swiftEditorAddRoundedRect(SwiftEditor *editor, float x, float y, float w,
                              float h, float r, float g, float b, float a)
{
  return editor
    ? editor->engine.addRoundedRect(x, y, w, h, r, g, b, a)
    : -1;
}

int swiftEditorAddCircle(SwiftEditor *editor, float cx, float cy, float radius,
                         float r, float g, float b, float a)
{
  return editor ? editor->engine.addCircle(cx, cy, radius, r, g, b, a) : -1;
}

int swiftEditorAddLine(SwiftEditor *editor, float x1, float y1, float x2,
                       float y2, float r, float g, float b, float a)
{
  return editor ? editor->engine.addLine(x1, y1, x2, y2, r, g, b, a) : -1;
}

int swiftEditorAddLabel(SwiftEditor *editor, const char *text, float x, float y,
                        float r, float g, float b)
{
  return editor
    ? editor->engine.addLabel(text ? text : "", x, y, r, g, b)
    : -1;
}

void swiftEditorClearShapes(SwiftEditor *editor)
{
  if (editor) editor->engine.clearShapes();
}

void swiftEditorClearLines(SwiftEditor *editor)
{
  if (editor) editor->engine.clearLines();
}

void swiftEditorClearLabels(SwiftEditor *editor)
{
  if (editor) editor->engine.clearLabels();
}

int swiftEditorAddTextWidget(SwiftEditor *editor, float x, float y, float w,
                             float h, const char *text, bool multiline)
{
  return editor
    ? editor->engine.addTextWidget(x, y, w, h, text ? text : "", multiline)
    : -1;
}

void swiftEditorSetTextWidgetFocused(SwiftEditor *editor, int id, bool focused)
{
  if (editor) editor->engine.setTextWidgetFocused(id, focused);
}

bool swiftEditorAddTextHighlight(SwiftEditor *editor, int id,
                                 const char *pattern, float r, float g, float b,
                                 float a, int priority)
{
  if (!editor || !pattern) return false;
  TextHighlightRule rule;
  rule.pattern = pattern;
  rule.r = r;
  rule.g = g;
  rule.b = b;
  rule.a = a;
  rule.priority = priority;
  return editor->engine.setTextWidgetHighlightRules(id, {rule});
}

void swiftEditorDiagramViewport(const SwiftEditor *editor, float *x, float *y,
                                float *w, float *h)
{
  if (!editor) return;
  auto r = editor->engine.diagramViewport();
  if (x) *x = r.x;
  if (y) *y = r.y;
  if (w) *w = r.w;
  if (h) *h = r.h;
}

void swiftEditorUiReset(SwiftEditor *editor)
{
  if (editor) editor->engine.uiReset();
}

void swiftEditorUiBegin(SwiftEditor *editor, int kind, int id, float flexGrow,
                        float flexShrink, float width, float height,
                        float padding)
{
  if (editor) {
    editor->engine.uiBegin(kind, id, flexGrow, flexShrink, width, height,
                           padding);
  }
}

void swiftEditorUiText(SwiftEditor *editor, int id, const char *text, float r,
                       float g, float b, bool clickable)
{
  if (editor) {
    editor->engine.uiText(id, text ? text : "", r, g, b, clickable);
  }
}

void swiftEditorUiEnd(SwiftEditor *editor)
{
  if (editor) editor->engine.uiEnd();
}

void swiftEditorUiCommit(SwiftEditor *editor)
{
  if (editor) editor->engine.uiCommit();
}

int swiftEditorUiPollEvent(SwiftEditor *editor, int *outWidgetId, int *outKind)
{
  if (!editor) return 0;
  int id = 0, kind = 0;
  if (!editor->engine.uiPollEvent(id, kind)) return 0;
  if (outWidgetId) *outWidgetId = id;
  if (outKind) *outKind = kind;
  return 1;
}

} // namespace canvas
