#pragma once

// Free-function C++ API designed for Swift C++ interop.
// (Classes without copy/move are not imported by Swift — see
//  "record is not automatically available" diagnostics.)

#include <cstdint>

namespace canvas {

/// Opaque editor handle (Swift imports this as an opaque pointer type).
struct SwiftEditor;

SwiftEditor *swiftEditorCreate(const char *assetsRoot, int width, int height,
                               const char *title);
void swiftEditorDestroy(SwiftEditor *editor);
bool swiftEditorIsOpen(const SwiftEditor *editor);
void swiftEditorSetVisible(SwiftEditor *editor, bool visible);

/// Panel ids: 0=tree, 1=diagram, 2=properties, 3=log.
void swiftEditorSetWorkspaceColumns(SwiftEditor *editor, int leftPanel,
                                    int centerPanel, int rightPanel,
                                    float leftWidth, float rightWidth);

void swiftEditorSetProjectTree(SwiftEditor *editor, const char *const *ids,
                               const char *const *labels, const int *depths,
                               const bool *selected, int count);

void swiftEditorSetProperties(SwiftEditor *editor, const char *const *keys,
                              const char *const *values, int count);

int swiftEditorSelectedTreeId(const SwiftEditor *editor, char *buf, int cap);

int swiftEditorAddRoundedRect(SwiftEditor *editor, float x, float y, float w,
                              float h, float r, float g, float b, float a);
int swiftEditorAddCircle(SwiftEditor *editor, float cx, float cy, float radius,
                         float r, float g, float b, float a);
int swiftEditorAddLine(SwiftEditor *editor, float x1, float y1, float x2,
                       float y2, float r, float g, float b, float a);
int swiftEditorAddLabel(SwiftEditor *editor, const char *text, float x, float y,
                        float r, float g, float b);
void swiftEditorClearShapes(SwiftEditor *editor);
void swiftEditorClearLines(SwiftEditor *editor);
void swiftEditorClearLabels(SwiftEditor *editor);

int swiftEditorAddTextWidget(SwiftEditor *editor, float x, float y, float w,
                             float h, const char *text, bool multiline);
void swiftEditorSetTextWidgetFocused(SwiftEditor *editor, int id, bool focused);
bool swiftEditorAddTextHighlight(SwiftEditor *editor, int id,
                                 const char *pattern, float r, float g, float b,
                                 float a, int priority);

void swiftEditorDiagramViewport(const SwiftEditor *editor, float *x, float *y,
                                float *w, float *h);

// ─── Declarative UI builder (commit replaces chrome when DiagramHost present)
// kind: 0=Row, 1=Column, 3=Spacer, 4=DiagramHost  (Text uses uiText)
// width/height < 0 → auto. Events: poll returns 1 if event; kind 0=Click.
void swiftEditorUiReset(SwiftEditor *editor);
void swiftEditorUiBegin(SwiftEditor *editor, int kind, int id, float flexGrow,
                        float flexShrink, float width, float height,
                        float padding);
void swiftEditorUiText(SwiftEditor *editor, int id, const char *text, float r,
                       float g, float b, bool clickable);
void swiftEditorUiEnd(SwiftEditor *editor);
void swiftEditorUiCommit(SwiftEditor *editor);
/// Returns 1 if an event was written to outWidgetId/outKind, else 0.
int swiftEditorUiPollEvent(SwiftEditor *editor, int *outWidgetId, int *outKind);

} // namespace canvas
