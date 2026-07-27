#include "render/text_widget.hpp"

#include <algorithm>
#include <cctype>
#include <climits>
#include <cmath>
#include <cstring>
#include <regex>
#include <utility>

#include "imgui.h"
#include "util/key_codes.hpp"

// ─── stb_textedit wiring ────────────────────────────────────────────────────

#define STB_TEXTEDIT_CHARTYPE char
#define STB_TEXTEDIT_POSITIONTYPE int
#define STB_TEXTEDIT_UNDOSTATECOUNT 99
#define STB_TEXTEDIT_UNDOCHARCOUNT 999

struct TextWidgetStbAccess {
  CanvasTextWidget* w = nullptr;
};

#define STB_TEXTEDIT_STRING TextWidgetStbAccess

#include "stb_textedit.h"

struct CanvasTextWidget::EditState {
  STB_TexteditState state{};
};

static int tw_string_len(TextWidgetStbAccess* obj) {
  return static_cast<int>(obj->w->mutableText().size());
}

static void tw_layout_row(StbTexteditRow* row, TextWidgetStbAccess* obj, int n) {
  CanvasTextWidget* w = obj->w;
  const std::string& s = w->mutableText();
  const int len = static_cast<int>(s.size());
  if (n < 0 || n > len) {
    row->num_chars = 0;
    row->x0 = row->x1 = 0;
    row->ymin = 0;
    row->ymax = w->lineHeight();
    row->baseline_y_delta = w->lineHeight();
    return;
  }

  int i = n;
  float width = 0.f;
  while (i < len && s[static_cast<size_t>(i)] != '\n') {
    width += w->charWidthAt(i);
    ++i;
  }
  int num = i - n;
  if (i < len && s[static_cast<size_t>(i)] == '\n') {
    ++num;
  }

  row->num_chars = num;
  row->x0 = 0.f;
  row->x1 = width;
  row->ymin = -2.f;
  row->ymax = w->lineHeight() - 2.f;
  row->baseline_y_delta = w->lineHeight();
}

static float tw_get_width(TextWidgetStbAccess* obj, int line_start, int char_index) {
  return obj->w->charWidthAt(line_start + char_index);
}

static int tw_key_to_text(int key) {
  if (key & 0x200000) return -1;
  if (key == '\n' || key == '\t') return key;
  if (key >= 32 && key < 127) return key;
  return -1;
}

static char tw_get_char(TextWidgetStbAccess* obj, int i) {
  return obj->w->mutableText()[static_cast<size_t>(i)];
}

static void tw_delete_chars(TextWidgetStbAccess* obj, int pos, int n) {
  auto& s = obj->w->mutableText();
  if (pos < 0 || n <= 0 || pos >= static_cast<int>(s.size())) return;
  n = std::min(n, static_cast<int>(s.size()) - pos);
  s.erase(static_cast<size_t>(pos), static_cast<size_t>(n));
  obj->w->notifyBufferChanged();
}

static int tw_insert_chars(TextWidgetStbAccess* obj, int pos, const char* chars, int n) {
  if (n <= 0 || !chars) return 0;
  auto& s = obj->w->mutableText();
  if (pos < 0) pos = 0;
  if (pos > static_cast<int>(s.size())) pos = static_cast<int>(s.size());
  constexpr int kMaxChars = 64 * 1024;
  if (static_cast<int>(s.size()) + n > kMaxChars) {
    n = kMaxChars - static_cast<int>(s.size());
    if (n <= 0) return 0;
  }
  s.insert(static_cast<size_t>(pos), chars, static_cast<size_t>(n));
  obj->w->notifyBufferChanged();
  return 1;
}

#define STB_TEXTEDIT_STRINGLEN(obj) tw_string_len(obj)
#define STB_TEXTEDIT_LAYOUTROW(r, obj, n) tw_layout_row(r, obj, n)
#define STB_TEXTEDIT_GETWIDTH(obj, n, i) tw_get_width(obj, n, i)
#define STB_TEXTEDIT_KEYTOTEXT(k) tw_key_to_text(k)
#define STB_TEXTEDIT_GETCHAR(obj, i) tw_get_char(obj, i)
#define STB_TEXTEDIT_NEWLINE '\n'
#define STB_TEXTEDIT_DELETECHARS(obj, i, n) tw_delete_chars(obj, i, n)
#define STB_TEXTEDIT_INSERTCHARS(obj, i, c, n) tw_insert_chars(obj, i, c, n)

#define STB_TEXTEDIT_K_SHIFT 0x400000
#define STB_TEXTEDIT_K_LEFT 0x200000
#define STB_TEXTEDIT_K_RIGHT 0x200001
#define STB_TEXTEDIT_K_UP 0x200002
#define STB_TEXTEDIT_K_DOWN 0x200003
#define STB_TEXTEDIT_K_PGUP 0x200004
#define STB_TEXTEDIT_K_PGDOWN 0x200005
#define STB_TEXTEDIT_K_LINESTART 0x200006
#define STB_TEXTEDIT_K_LINEEND 0x200007
#define STB_TEXTEDIT_K_TEXTSTART 0x200008
#define STB_TEXTEDIT_K_TEXTEND 0x200009
#define STB_TEXTEDIT_K_DELETE 0x20000A
#define STB_TEXTEDIT_K_BACKSPACE 0x20000B
#define STB_TEXTEDIT_K_UNDO 0x20000C
#define STB_TEXTEDIT_K_REDO 0x20000D
#define STB_TEXTEDIT_K_WORDLEFT 0x20000E
#define STB_TEXTEDIT_K_WORDRIGHT 0x20000F
#define STB_TEXTEDIT_IS_SPACE(ch) (std::isspace(static_cast<unsigned char>(ch)) != 0)

#define STB_TEXTEDIT_IMPLEMENTATION
#include "stb_textedit.h"

// ─── helpers ────────────────────────────────────────────────────────────────

namespace {

uint32_t color_u32(float r, float g, float b, float a) {
  auto ch = [](float v) -> int {
    return std::clamp(static_cast<int>(v * 255.f + 0.5f), 0, 255);
  };
  return IM_COL32(ch(r), ch(g), ch(b), ch(a));
}

constexpr uint32_t kDefaultText = IM_COL32(220, 220, 220, 255);
constexpr uint32_t kBg = IM_COL32(30, 32, 40, 240);
constexpr uint32_t kBgFocused = IM_COL32(36, 40, 52, 250);
constexpr uint32_t kBorder = IM_COL32(80, 85, 100, 255);
constexpr uint32_t kBorderFocused = IM_COL32(90, 140, 255, 255);
constexpr uint32_t kSelection = IM_COL32(60, 100, 200, 120);
constexpr uint32_t kCaret = IM_COL32(230, 230, 240, 255);

// Extra GLFW-style keys not listed in key_codes.hpp yet.
constexpr int KEY_ENTER = 257;
constexpr int KEY_BACKSPACE = 259;
constexpr int KEY_DELETE = 261;
constexpr int KEY_HOME = 268;
constexpr int KEY_END = 269;
constexpr int KEY_PAGE_UP = 266;
constexpr int KEY_PAGE_DOWN = 267;
constexpr int KEY_Z = 90;
constexpr int KEY_Y = 89;

TextWidgetStbAccess access(CanvasTextWidget* w) {
  TextWidgetStbAccess a;
  a.w = w;
  return a;
}

} // namespace

// ─── CanvasTextWidget ───────────────────────────────────────────────────────

CanvasTextWidget::CanvasTextWidget() {
  edit_ = new EditState();
  stb_textedit_initialize_state(&edit_->state, multiline ? 0 : 1);
}

CanvasTextWidget::~CanvasTextWidget() {
  clearRules();
  delete edit_;
  edit_ = nullptr;
}

CanvasTextWidget::CanvasTextWidget(CanvasTextWidget&& other) noexcept
  : x(other.x), y(other.y), w(other.w), h(other.h),
    multiline(other.multiline), focused(other.focused), changed(other.changed),
    text_(std::move(other.text_)),
    edit_(other.edit_),
    rules_(std::move(other.rules_)),
    runs_(std::move(other.runs_)),
    font_(other.font_),
    font_size_(other.font_size_),
    line_height_(other.line_height_),
    pad_(other.pad_),
    scroll_x_(other.scroll_x_),
    scroll_y_(other.scroll_y_),
    caret_blink_(other.caret_blink_),
    mouse_down_(other.mouse_down_)
{
  other.edit_ = nullptr;
  other.rules_.clear();
}

CanvasTextWidget& CanvasTextWidget::operator=(CanvasTextWidget&& other) noexcept {
  if (this == &other) return *this;
  clearRules();
  delete edit_;

  x = other.x;
  y = other.y;
  w = other.w;
  h = other.h;
  multiline = other.multiline;
  focused = other.focused;
  changed = other.changed;
  text_ = std::move(other.text_);
  edit_ = other.edit_;
  rules_ = std::move(other.rules_);
  runs_ = std::move(other.runs_);
  font_ = other.font_;
  font_size_ = other.font_size_;
  line_height_ = other.line_height_;
  pad_ = other.pad_;
  scroll_x_ = other.scroll_x_;
  scroll_y_ = other.scroll_y_;
  caret_blink_ = other.caret_blink_;
  mouse_down_ = other.mouse_down_;

  other.edit_ = nullptr;
  other.rules_.clear();
  return *this;
}

void CanvasTextWidget::clearRules() {
  for (auto& r : rules_) {
    delete static_cast<std::regex*>(r.regex);
    r.regex = nullptr;
  }
  rules_.clear();
}

void CanvasTextWidget::setText(std::string text) {
  if (text.size() > 64 * 1024) {
    text.resize(64 * 1024);
  }
  text_ = std::move(text);
  if (edit_) {
    stb_textedit_initialize_state(&edit_->state, multiline ? 0 : 1);
  }
  scroll_x_ = scroll_y_ = 0.f;
  rehighlight();
}

bool CanvasTextWidget::setHighlightRules(const std::vector<TextHighlightRule>& rules) {
  clearRules();
  bool ok = true;
  for (const auto& rule : rules) {
    CompiledRule compiled;
    compiled.pattern = rule.pattern;
    compiled.color = color_u32(rule.r, rule.g, rule.b, rule.a);
    compiled.priority = rule.priority;
    compiled.capture_group = rule.capture_group;
    try {
      compiled.regex = new std::regex(
        rule.pattern, std::regex::ECMAScript | std::regex::optimize);
      rules_.push_back(std::move(compiled));
    } catch (const std::regex_error&) {
      ok = false;
    }
  }
  rehighlight();
  return ok;
}

void CanvasTextWidget::notifyBufferChanged() {
  changed = true;
  rehighlight();
  caret_blink_ = 0.f;
}

void CanvasTextWidget::rehighlight() {
  runs_.clear();
  if (text_.empty()) return;

  const int n = static_cast<int>(text_.size());
  std::vector<uint32_t> colors(static_cast<size_t>(n), kDefaultText);
  std::vector<int> prios(static_cast<size_t>(n), INT_MIN);

  for (const auto& rule : rules_) {
    if (!rule.regex) continue;
    const auto& re = *static_cast<std::regex*>(rule.regex);
    try {
      auto begin = std::sregex_iterator(text_.begin(), text_.end(), re);
      auto endIt = std::sregex_iterator();
      for (auto it = begin; it != endIt; ++it) {
        const std::smatch& m = *it;
        int s = 0, e = 0;
        if (rule.capture_group > 0
            && rule.capture_group < static_cast<int>(m.size())
            && m[static_cast<size_t>(rule.capture_group)].matched) {
          s = static_cast<int>(m.position(static_cast<size_t>(rule.capture_group)));
          e = s + static_cast<int>(m.length(static_cast<size_t>(rule.capture_group)));
        } else {
          s = static_cast<int>(m.position());
          e = s + static_cast<int>(m.length());
        }
        s = std::max(0, s);
        e = std::min(n, e);
        for (int i = s; i < e; ++i) {
          if (rule.priority >= prios[static_cast<size_t>(i)]) {
            prios[static_cast<size_t>(i)] = rule.priority;
            colors[static_cast<size_t>(i)] = rule.color;
          }
        }
      }
    } catch (const std::regex_error&) {
    }
  }

  int runStart = 0;
  uint32_t runColor = colors[0];
  for (int i = 1; i < n; ++i) {
    if (colors[static_cast<size_t>(i)] != runColor) {
      runs_.push_back({runStart, i, runColor});
      runStart = i;
      runColor = colors[static_cast<size_t>(i)];
    }
  }
  runs_.push_back({runStart, n, runColor});
}

bool CanvasTextWidget::hitTest(float mx, float my) const {
  return mx >= x && my >= y && mx < x + w && my < y + h;
}

float CanvasTextWidget::charWidthAt(int index) const {
  if (index < 0 || index >= static_cast<int>(text_.size())) return 0.f;
  const char c = text_[static_cast<size_t>(index)];
  if (c == '\n') return 0.f;
  if (c == '\t') {
    const float space = font_
      ? font_->CalcTextSizeA(font_size_, FLT_MAX, 0.f, " ").x
      : font_size_ * 0.5f;
    return space * 4.f;
  }
  if (font_) {
    char buf[2] = {c, 0};
    return font_->CalcTextSizeA(font_size_, FLT_MAX, 0.f, buf, buf + 1).x;
  }
  return font_size_ * 0.5f;
}

void CanvasTextWidget::onMouseDown(float mx, float my) {
  focused = true;
  mouse_down_ = true;
  caret_blink_ = 0.f;
  auto a = access(this);
  stb_textedit_click(&a, &edit_->state, mx - contentX(), my - contentY());
}

void CanvasTextWidget::onMouseDrag(float mx, float my) {
  if (!mouse_down_ || !focused) return;
  auto a = access(this);
  stb_textedit_drag(&a, &edit_->state, mx - contentX(), my - contentY());
  ensureCaretVisible();
}

void CanvasTextWidget::onMouseUp(float /*mx*/, float /*my*/) {
  mouse_down_ = false;
}

void CanvasTextWidget::onKey(int key, int action, int mods) {
  if (!focused || !edit_) return;
  if (action != ACTION_PRESS && action != ACTION_REPEAT) return;

  const bool shift = (mods & 0x1) != 0;
  const bool ctrl = (mods & 0x2) != 0;
  int stbKey = 0;

  if (key == KEY_LEFT) stbKey = STB_TEXTEDIT_K_LEFT;
  else if (key == KEY_RIGHT) stbKey = STB_TEXTEDIT_K_RIGHT;
  else if (key == KEY_UP) stbKey = STB_TEXTEDIT_K_UP;
  else if (key == KEY_DOWN) stbKey = STB_TEXTEDIT_K_DOWN;
  else if (key == KEY_ESCAPE) {
    focused = false;
    return;
  } else if (key == KEY_BACKSPACE) stbKey = STB_TEXTEDIT_K_BACKSPACE;
  else if (key == KEY_DELETE) stbKey = STB_TEXTEDIT_K_DELETE;
  else if (key == KEY_HOME) stbKey = ctrl ? STB_TEXTEDIT_K_TEXTSTART : STB_TEXTEDIT_K_LINESTART;
  else if (key == KEY_END) stbKey = ctrl ? STB_TEXTEDIT_K_TEXTEND : STB_TEXTEDIT_K_LINEEND;
  else if (key == KEY_PAGE_UP) stbKey = STB_TEXTEDIT_K_PGUP;
  else if (key == KEY_PAGE_DOWN) stbKey = STB_TEXTEDIT_K_PGDOWN;
  else if (key == KEY_ENTER) {
    if (!multiline) return;
    auto a = access(this);
    const char nl = '\n';
    stb_textedit_paste(&a, &edit_->state, const_cast<char*>(&nl), 1);
    ensureCaretVisible();
    return;
  } else if (ctrl && key == KEY_Z) {
    stbKey = shift ? STB_TEXTEDIT_K_REDO : STB_TEXTEDIT_K_UNDO;
  } else if (ctrl && key == KEY_Y) {
    stbKey = STB_TEXTEDIT_K_REDO;
  } else if (ctrl && key == KEY_A) {
    edit_->state.select_start = 0;
    edit_->state.select_end = static_cast<int>(text_.size());
    edit_->state.cursor = edit_->state.select_end;
    return;
  } else {
    return;
  }

  if (shift) stbKey |= STB_TEXTEDIT_K_SHIFT;

  auto a = access(this);
  stb_textedit_key(&a, &edit_->state, stbKey);
  ensureCaretVisible();
}

void CanvasTextWidget::onTextInput(const char* utf8) {
  if (!focused || !edit_ || !utf8 || !*utf8) return;
  auto a = access(this);
  const int len = static_cast<int>(std::strlen(utf8));
  stb_textedit_paste(&a, &edit_->state, const_cast<char*>(utf8), len);
  ensureCaretVisible();
}

void CanvasTextWidget::ensureCaretVisible() {
  if (!edit_) return;
  float cx = 0.f, cy = 0.f;
  int i = 0;
  const int caret = edit_->state.cursor;
  const int len = static_cast<int>(text_.size());
  while (i < len) {
    StbTexteditRow row{};
    auto a = access(this);
    tw_layout_row(&row, &a, i);
    if (row.num_chars <= 0) break;
    if (caret < i + row.num_chars || i + row.num_chars >= len) {
      cx = 0.f;
      for (int k = i; k < caret && k < i + row.num_chars; ++k) {
        if (text_[static_cast<size_t>(k)] == '\n') break;
        cx += charWidthAt(k);
      }
      break;
    }
    cy += line_height_;
    i += row.num_chars;
  }

  const float viewW = std::max(1.f, w - pad_ * 2.f);
  const float viewH = std::max(1.f, h - pad_ * 2.f);
  if (cx - scroll_x_ < 0.f) scroll_x_ = cx;
  if (cx - scroll_x_ > viewW - 4.f) scroll_x_ = cx - viewW + 4.f;
  if (cy - scroll_y_ < 0.f) scroll_y_ = cy;
  if (cy - scroll_y_ > viewH - line_height_) scroll_y_ = cy - viewH + line_height_;
  if (scroll_x_ < 0.f) scroll_x_ = 0.f;
  if (scroll_y_ < 0.f) scroll_y_ = 0.f;
}

void CanvasTextWidget::draw(
  ImDrawList* drawList, ImFont* font, float fontSize, float deltaTime)
{
  if (!drawList) return;
  font_ = font;
  font_size_ = fontSize > 0.f ? fontSize : ImGui::GetFontSize();
  line_height_ = font_size_ + 2.f;

  if (focused) {
    caret_blink_ += deltaTime;
  }

  const ImVec2 p0(x, y);
  const ImVec2 p1(x + w, y + h);
  drawList->AddRectFilled(p0, p1, focused ? kBgFocused : kBg, 3.f);
  drawList->AddRect(p0, p1, focused ? kBorderFocused : kBorder, 3.f);

  drawList->PushClipRect(
    ImVec2(x + 1.f, y + 1.f), ImVec2(x + w - 1.f, y + h - 1.f), true);

  const float baseX = contentX();
  const float baseY = contentY();

  // Selection
  if (edit_ && edit_->state.select_start != edit_->state.select_end) {
    int sel_a = edit_->state.select_start;
    int sel_b = edit_->state.select_end;
    if (sel_a > sel_b) std::swap(sel_a, sel_b);

    int i = 0;
    float rowY = baseY;
    const int len = static_cast<int>(text_.size());
    while (i < len) {
      StbTexteditRow row{};
      auto a = access(this);
      tw_layout_row(&row, &a, i);
      if (row.num_chars <= 0) break;
      const int rowEnd = i + row.num_chars;
      const int s = std::max(sel_a, i);
      const int e = std::min(sel_b, rowEnd);
      if (s < e) {
        float x0 = baseX;
        for (int k = i; k < s; ++k) {
          if (text_[static_cast<size_t>(k)] == '\n') break;
          x0 += charWidthAt(k);
        }
        float x1 = x0;
        for (int k = s; k < e; ++k) {
          if (text_[static_cast<size_t>(k)] == '\n') break;
          x1 += charWidthAt(k);
        }
        if (x1 <= x0) x1 = x0 + 3.f;
        drawList->AddRectFilled(
          ImVec2(x0, rowY),
          ImVec2(x1, rowY + line_height_),
          kSelection);
      }
      rowY += line_height_;
      i = rowEnd;
    }
  }

  // Colored text, line by line
  {
    int i = 0;
    float rowY = baseY;
    const int len = static_cast<int>(text_.size());
    while (true) {
      if (i > len) break;
      const int lineStart = i;
      int lineEnd = i;
      while (lineEnd < len && text_[static_cast<size_t>(lineEnd)] != '\n') {
        ++lineEnd;
      }

      float penX = baseX;
      int pos = lineStart;
      auto drawSlice = [&](int from, int to, uint32_t col) {
        if (from >= to) return;
        const char* start = text_.data() + from;
        const char* end = text_.data() + to;
        if (font_) {
          drawList->AddText(font_, font_size_, ImVec2(penX, rowY), col, start, end);
        } else {
          drawList->AddText(ImVec2(penX, rowY), col, start, end);
        }
        for (int k = from; k < to; ++k) penX += charWidthAt(k);
      };

      if (runs_.empty()) {
        drawSlice(lineStart, lineEnd, kDefaultText);
      } else {
        for (const auto& run : runs_) {
          const int from = std::max(run.start, lineStart);
          const int to = std::min(run.end, lineEnd);
          if (from >= to) continue;
          while (pos < from) {
            penX += charWidthAt(pos);
            ++pos;
          }
          drawSlice(from, to, run.color);
          pos = to;
        }
        while (pos < lineEnd) {
          drawSlice(pos, pos + 1, kDefaultText);
          ++pos;
        }
      }

      if (lineEnd >= len) break;
      i = lineEnd + 1;
      rowY += line_height_;
      if (i == lineStart) break;
    }
  }

  // Caret
  if (focused && edit_ && std::fmod(caret_blink_, 1.0f) < 0.5f) {
    float cx = baseX;
    float cy = baseY;
    int i = 0;
    const int caret = edit_->state.cursor;
    const int len = static_cast<int>(text_.size());
    while (i < len) {
      StbTexteditRow row{};
      auto a = access(this);
      tw_layout_row(&row, &a, i);
      if (row.num_chars <= 0) break;
      if (caret <= i + row.num_chars) {
        for (int k = i; k < caret && k < i + row.num_chars; ++k) {
          if (text_[static_cast<size_t>(k)] == '\n') break;
          cx += charWidthAt(k);
        }
        break;
      }
      cy += line_height_;
      i += row.num_chars;
    }
    drawList->AddLine(
      ImVec2(cx, cy), ImVec2(cx, cy + line_height_ - 2.f), kCaret, 1.0f);
  }

  drawList->PopClipRect();
}
