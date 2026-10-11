#include "lava_pdf.h"

#include <poppler-document.h>
#include <poppler-global.h>
#include <poppler-page-renderer.h>
#include <poppler-page.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

struct LavaPDFDocument {
  std::mutex lock;
  std::unique_ptr<poppler::document> document;
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
