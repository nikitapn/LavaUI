#include "lava_pdf.h"

// By full path, both of them. poppler-cpp and poppler-glib each ship a
// `poppler-page.h` and a `poppler-document.h`, and both directories are on
// the include path, so a bare name means whichever pkg-config listed first.
// Their own includes are quoted, which resolve beside the including file.
#include <poppler/cpp/poppler-document.h>
#include <poppler/cpp/poppler-global.h>
#include <poppler/cpp/poppler-page-renderer.h>
#include <poppler/cpp/poppler-page.h>
#include <poppler/glib/poppler.h>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

struct LavaPDFDocument {
  std::mutex lock;
  std::string path;
  std::string password;
  std::unique_ptr<poppler::document> document;
  /// The glib handle, for the outline and links — opened the first time
  /// either is asked for, because a document only being rendered (every
  /// worker's) never needs it.
  PopplerDocument *glib = nullptr;
  bool glibTried = false;

  ~LavaPDFDocument() {
    if (glib != nullptr) g_object_unref(glib);
  }

  PopplerDocument *glibDocument() {
    if (glibTried) return glib;
    glibTried = true;
    GError *error = nullptr;
    gchar *uri = g_filename_to_uri(path.c_str(), nullptr, &error);
    if (uri != nullptr) {
      glib = poppler_document_new_from_file(
          uri, password.empty() ? nullptr : password.c_str(), &error);
      g_free(uri);
    }
    if (error != nullptr) g_error_free(error);
    return glib;
  }
  /// Created on first use and kept: a page is cheap to keep and not free to
  /// make, and a viewer asks for the same few over and over.
  std::vector<std::unique_ptr<poppler::page>> pages;

  poppler::page *page(int index) {
    if (index < 0 || index >= static_cast<int>(pages.size())) return nullptr;
    auto &slot = pages[static_cast<size_t>(index)];
    if (!slot) slot.reset(document->create_page(index));
    return slot.get();
  }
};

namespace {

/// Quarter turns the page's own /Rotate asks for.
int quarterTurns(const poppler::page &page) {
  switch (page.orientation()) {
    case poppler::page::landscape: return 1;
    case poppler::page::upside_down: return 2;
    case poppler::page::seascape: return 3;
    case poppler::page::portrait: break;
  }
  return 0;
}

/// Poppler reports what it thinks of every damaged file on stderr, and a
/// viewer opening a folder of downloads would print pages of it. Quiet unless
/// asked for.
void silencePoppler() {
  static std::once_flag once;
  std::call_once(once, [] {
    if (std::getenv("LAVA_PDF_DEBUG") != nullptr) return;
    poppler::set_debug_error_function([](const std::string &, void *) {},
                                      nullptr);
  });
}

}  // namespace

extern "C" {

LavaPDFDocument *lava_pdf_open(const char *path, const char *password,
                               LavaPDFOpenStatus *status) {
  silencePoppler();
  auto fail = [status](LavaPDFOpenStatus why) -> LavaPDFDocument * {
    if (status != nullptr) *status = why;
    return nullptr;
  };
  if (path == nullptr) return fail(LAVA_PDF_OPEN_UNREADABLE);
  const std::string secret = password != nullptr ? password : "";
  // The same string as owner and user password: a reader asks for "the
  // password" and does not know which kind the file has.
  std::unique_ptr<poppler::document> document(
      poppler::document::load_from_file(path, secret, secret));
  if (!document) {
    // A wrong password and a broken file look the same from here. Asking
    // again without one tells them apart: an encrypted file loads, locked.
    std::unique_ptr<poppler::document> probe(
        poppler::document::load_from_file(path));
    return fail(probe && probe->is_locked() ? LAVA_PDF_OPEN_LOCKED
                                            : LAVA_PDF_OPEN_UNREADABLE);
  }
  if (document->is_locked()) return fail(LAVA_PDF_OPEN_LOCKED);

  auto *result = new LavaPDFDocument;
  result->path = path;
  result->password = secret;
  result->document = std::move(document);
  result->pages.resize(static_cast<size_t>(std::max(0, result->document->pages())));
  if (status != nullptr) *status = LAVA_PDF_OPEN_OK;
  return result;
}

void lava_pdf_close(LavaPDFDocument *document) { delete document; }

int lava_pdf_page_count(LavaPDFDocument *document) {
  if (document == nullptr) return 0;
  std::lock_guard guard(document->lock);
  return static_cast<int>(document->pages.size());
}

int lava_pdf_page_size(LavaPDFDocument *document, int index, double *width,
                       double *height) {
  if (document == nullptr) return 0;
  std::lock_guard guard(document->lock);
  poppler::page *page = document->page(index);
  if (page == nullptr) return 0;
  const poppler::rectf box = page->page_rect(poppler::crop_box);
  const bool turned = quarterTurns(*page) % 2 == 1;
  if (width != nullptr) *width = turned ? box.height() : box.width();
  if (height != nullptr) *height = turned ? box.width() : box.height();
  return 1;
}

int lava_pdf_render(LavaPDFDocument *document, int index, double scale, int x,
                    int y, int width, int height, uint8_t *dst, size_t stride) {
  if (document == nullptr || dst == nullptr || width <= 0 || height <= 0 ||
      !(scale > 0) || stride < static_cast<size_t>(width) * 4)
    return 0;
  std::lock_guard guard(document->lock);
  poppler::page *page = document->page(index);
  if (page == nullptr) return 0;

  poppler::page_renderer renderer;
  renderer.set_image_format(poppler::image::format_argb32);
  renderer.set_render_hints(poppler::page_renderer::antialiasing |
                            poppler::page_renderer::text_antialiasing);
  // `render_page` turns by the page's own /Rotate already; this is the
  // caller's turn on top of it, and a reader has none to ask for.
  const double dpi = scale * 72.0;
  const poppler::image image =
      renderer.render_page(page, dpi, dpi, x, y, width, height);
  if (!image.is_valid() || image.format() != poppler::image::format_argb32)
    return 0;

  // The slice comes back clipped to the page. Paper first, so the part of
  // the window past the edge is white rather than whatever `dst` held.
  for (int row = 0; row < height; ++row)
    std::memset(dst + static_cast<size_t>(row) * stride, 0xff,
                static_cast<size_t>(width) * 4);
  const int rows = std::min(height, image.height());
  const size_t bytes =
      static_cast<size_t>(std::min(width, image.width())) * 4;
  const char *src = image.const_data();
  for (int row = 0; row < rows; ++row) {
    std::memcpy(dst + static_cast<size_t>(row) * stride,
                src + static_cast<size_t>(row) * image.bytes_per_row(), bytes);
  }
  return 1;
}

LavaPDFChar *lava_pdf_page_text(LavaPDFDocument *document, int index,
                                size_t *count) {
  if (count != nullptr) *count = 0;
  if (document == nullptr) return nullptr;
  std::lock_guard guard(document->lock);
  poppler::page *page = document->page(index);
  if (page == nullptr) return nullptr;

  std::vector<LavaPDFChar> chars;
  for (const poppler::text_box &word : page->text_list()) {
    const poppler::ustring text = word.text();
    if (text.empty()) continue;
    // A box per character, but a character can be two units: the pair
    // shares its box, and the box index only moves once per code point.
    size_t box = 0;
    const size_t start = chars.size();
    for (size_t i = 0; i < text.size(); ++i) {
      const char16_t unit = text[i];
      const poppler::rectf r = word.char_bbox(box);
      chars.push_back(LavaPDFChar{static_cast<float>(r.x()),
                                  static_cast<float>(r.y()),
                                  static_cast<float>(r.width()),
                                  static_cast<float>(r.height()),
                                  static_cast<uint16_t>(unit), 0});
      const bool leadSurrogate = unit >= 0xd800 && unit < 0xdc00;
      if (!leadSurrogate) ++box;
    }
    if (chars.size() > start) {
      chars.back().flags = LAVA_PDF_CHAR_WORD_END |
                           (word.has_space_after() ? LAVA_PDF_CHAR_SPACE_AFTER : 0);
    }
  }
  if (chars.empty()) return nullptr;
  auto *out = static_cast<LavaPDFChar *>(std::malloc(chars.size() * sizeof(LavaPDFChar)));
  if (out == nullptr) return nullptr;
  std::memcpy(out, chars.data(), chars.size() * sizeof(LavaPDFChar));
  if (count != nullptr) *count = chars.size();
  return out;
}

void lava_pdf_free_text(LavaPDFChar *text) { std::free(text); }

char *lava_pdf_title(LavaPDFDocument *document) {
  if (document == nullptr) return nullptr;
  std::lock_guard guard(document->lock);
  const poppler::byte_array utf8 = document->document->get_title().to_utf8();
  if (utf8.empty()) return nullptr;
  auto *out = static_cast<char *>(std::malloc(utf8.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, utf8.data(), utf8.size());
  out[utf8.size()] = '\0';
  return out;
}

void lava_pdf_free_string(char *string) { std::free(string); }

}  // extern "C"

// ─── Outline and links, through poppler-glib ─────────────────────────────────

namespace {

char *copyString(const char *text) {
  if (text == nullptr) return nullptr;
  const size_t length = std::strlen(text);
  auto *out = static_cast<char *>(std::malloc(length + 1));
  if (out != nullptr) std::memcpy(out, text, length + 1);
  return out;
}

LavaPDFTarget nowhere() {
  return LavaPDFTarget{-1, NAN, NAN, nullptr};
}

/// A destination as a page and a point from that page's top-left. Named ones
/// are looked up first; a page number of 0 is poppler saying it found none.
///
/// The point is only worked out for an upright page. A destination's
/// coordinates are in the page's unrotated user space, and turning them by
/// /Rotate is exactly the arithmetic whose mistakes go unnoticed until
/// someone's scanned landscape thesis jumps to the wrong paragraph — so a
/// turned page gets its top instead, which is never wrong, only less precise.
LavaPDFTarget resolve(PopplerDocument *document, const PopplerDest *dest,
                      poppler::document &cpp) {
  if (dest == nullptr) return nowhere();
  PopplerDest *named = nullptr;
  if (dest->type == POPPLER_DEST_NAMED && dest->named_dest != nullptr) {
    named = poppler_document_find_dest(document, dest->named_dest);
    dest = named;
  }
  LavaPDFTarget target = nowhere();
  if (dest != nullptr && dest->page_num > 0 && dest->page_num <= cpp.pages()) {
    target.page = dest->page_num - 1;
    std::unique_ptr<poppler::page> page(cpp.create_page(target.page));
    if (page && page->orientation() == poppler::page::portrait) {
      // Crop box top in user space, measured downwards — the y of every
      // other coordinate this file hands out.
      const poppler::rectf crop = page->page_rect(poppler::crop_box);
      const bool hasTop = dest->change_top || dest->type == POPPLER_DEST_FITH ||
                          dest->type == POPPLER_DEST_FITBH || dest->type == POPPLER_DEST_FITR;
      const bool hasLeft = dest->change_left || dest->type == POPPLER_DEST_FITV ||
                           dest->type == POPPLER_DEST_FITBV || dest->type == POPPLER_DEST_FITR;
      if (hasTop) target.y = static_cast<float>(crop.y() + crop.height() - dest->top);
      if (hasLeft) target.x = static_cast<float>(dest->left - crop.x());
    }
  }
  if (named != nullptr) poppler_dest_free(named);
  return target;
}

LavaPDFTarget targetOf(PopplerDocument *document, const PopplerAction *action,
                       poppler::document &cpp) {
  if (action == nullptr) return nowhere();
  switch (action->type) {
    case POPPLER_ACTION_GOTO_DEST:
      return resolve(document, action->goto_dest.dest, cpp);
    case POPPLER_ACTION_URI: {
      LavaPDFTarget target = nowhere();
      target.uri = copyString(action->uri.uri);
      return target;
    }
    default:
      // Another file, a named action (NextPage, Print…), JavaScript, a
      // form submission: none of them is somewhere this reader goes.
      return nowhere();
  }
}

void flatten(PopplerDocument *document, PopplerIndexIter *iter, int depth,
             poppler::document &cpp, std::vector<LavaPDFOutlineItem> &out) {
  if (iter == nullptr) return;
  do {
    PopplerAction *action = poppler_index_iter_get_action(iter);
    LavaPDFOutlineItem item{};
    item.depth = depth;
    item.open = poppler_index_iter_is_open(iter) ? 1 : 0;
    item.title = copyString(action != nullptr && action->any.title != nullptr
                                ? action->any.title : "");
    item.target = targetOf(document, action, cpp);
    if (action != nullptr) poppler_action_free(action);
    out.push_back(item);
    // Depth is bounded by the file, and a hostile file can nest without
    // limit; past this nobody is reading a table of contents anyway.
    if (depth < 32) {
      PopplerIndexIter *child = poppler_index_iter_get_child(iter);
      flatten(document, child, depth + 1, cpp, out);
      if (child != nullptr) poppler_index_iter_free(child);
    }
  } while (poppler_index_iter_next(iter));
}

template <typename T>
T *toMalloc(const std::vector<T> &items, size_t *count) {
  if (count != nullptr) *count = 0;
  if (items.empty()) return nullptr;
  auto *out = static_cast<T *>(std::malloc(items.size() * sizeof(T)));
  if (out == nullptr) return nullptr;
  std::memcpy(out, items.data(), items.size() * sizeof(T));
  if (count != nullptr) *count = items.size();
  return out;
}

}  // namespace

extern "C" {

LavaPDFOutlineItem *lava_pdf_outline(LavaPDFDocument *document, size_t *count) {
  if (count != nullptr) *count = 0;
  if (document == nullptr) return nullptr;
  std::lock_guard guard(document->lock);
  PopplerDocument *glib = document->glibDocument();
  if (glib == nullptr) return nullptr;
  std::vector<LavaPDFOutlineItem> items;
  PopplerIndexIter *iter = poppler_index_iter_new(glib);
  flatten(glib, iter, 0, *document->document, items);
  if (iter != nullptr) poppler_index_iter_free(iter);
  return toMalloc(items, count);
}

void lava_pdf_free_outline(LavaPDFOutlineItem *items, size_t count) {
  if (items == nullptr) return;
  for (size_t i = 0; i < count; ++i) {
    std::free(const_cast<char *>(items[i].title));
    std::free(const_cast<char *>(items[i].target.uri));
  }
  std::free(items);
}

LavaPDFLink *lava_pdf_page_links(LavaPDFDocument *document, int index, size_t *count) {
  if (count != nullptr) *count = 0;
  if (document == nullptr) return nullptr;
  std::lock_guard guard(document->lock);
  PopplerDocument *glib = document->glibDocument();
  if (glib == nullptr || index < 0 || index >= poppler_document_get_n_pages(glib))
    return nullptr;
  PopplerPage *page = poppler_document_get_page(glib, index);
  if (page == nullptr) return nullptr;

  // glib's areas are in points from the bottom-left of the page as it is
  // shown, crop box and rotation already applied — and so is its size — so
  // the one flip left is the y axis.
  double width = 0, height = 0;
  poppler_page_get_size(page, &width, &height);

  std::vector<LavaPDFLink> links;
  GList *mapping = poppler_page_get_link_mapping(page);
  // Walked from the end: glib builds the list by prepending, so it comes
  // back in the reverse of the page's order — and the order is what says
  // which of two overlapping links is on top.
  for (GList *node = g_list_last(mapping); node != nullptr; node = node->prev) {
    auto *link = static_cast<PopplerLinkMapping *>(node->data);
    LavaPDFTarget target = targetOf(glib, link->action, *document->document);
    if (target.page < 0 && target.uri == nullptr) continue;
    const PopplerRectangle &area = link->area;
    const double x1 = std::min(area.x1, area.x2), x2 = std::max(area.x1, area.x2);
    const double y1 = std::min(area.y1, area.y2), y2 = std::max(area.y1, area.y2);
    links.push_back(LavaPDFLink{static_cast<float>(x1), static_cast<float>(height - y2),
                                static_cast<float>(x2 - x1), static_cast<float>(y2 - y1),
                                target});
  }
  poppler_page_free_link_mapping(mapping);
  g_object_unref(page);
  return toMalloc(links, count);
}

void lava_pdf_free_links(LavaPDFLink *links, size_t count) {
  if (links == nullptr) return;
  for (size_t i = 0; i < count; ++i) std::free(const_cast<char *>(links[i].target.uri));
  std::free(links);
}

}  // extern "C"
