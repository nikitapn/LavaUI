#pragma once

// A C face on poppler-cpp: open a document, measure and render its pages, and
// read their text with a box per character.
//
// C rather than C++ so that `LavaPDFCore` stays plain Swift. Importing C++
// switches on interop in every module that imports the importer, and a viewer's
// model has no business deciding that for the app above it.
//
// Every call on one document takes that document's lock: poppler is not safe
// for two renders of one document at once. A caller that wants parallel
// renders opens the file twice.

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LavaPDFDocument LavaPDFDocument;

/// Why `lava_pdf_open` returned null.
typedef enum {
  LAVA_PDF_OPEN_OK = 0,
  /// Not a PDF, damaged past repair, or unreadable.
  LAVA_PDF_OPEN_UNREADABLE = 1,
  /// Encrypted, and the password (if any) did not open it.
  LAVA_PDF_OPEN_LOCKED = 2,
} LavaPDFOpenStatus;

/// Opens `path`. `password` may be null. Null on failure, with `status` saying
/// which (it may itself be null).
LavaPDFDocument *lava_pdf_open(const char *path, const char *password,
                               LavaPDFOpenStatus *status);

void lava_pdf_close(LavaPDFDocument *document);

int lava_pdf_page_count(LavaPDFDocument *document);

/// The page as it is meant to be seen, in points: the crop box, turned by the
/// page's own /Rotate. Zero if `page` is out of range.
int lava_pdf_page_size(LavaPDFDocument *document, int page, double *width,
                       double *height);

/// Renders a `width` × `height` window of `page` at `scale` pixels per point,
/// whose top-left is (`x`, `y`) in the page's pixels at that scale, into `dst`
/// rows `stride` bytes apart.
///
/// Four bytes a pixel in memory order B, G, R, A — cairo's ARGB32 on a
/// little-endian machine, which is every machine this runs on — and opaque,
/// because the paper is white. The window may run off the page; what is past
/// the edge is paper. Zero on failure, with `dst` untouched.
int lava_pdf_render(LavaPDFDocument *document, int page, double scale, int x,
                    int y, int width, int height, uint8_t *dst, size_t stride);

enum {
  /// The last character of a word.
  LAVA_PDF_CHAR_WORD_END = 1,
  /// A word followed by a space. Only ever set with `WORD_END`.
  LAVA_PDF_CHAR_SPACE_AFTER = 2,
};

/// One UTF-16 unit of the page's text and the box it was drawn in, in points
/// from the top-left of the page as `lava_pdf_page_size` sees it.
///
/// UTF-16 because that is what poppler holds. A character outside the BMP is
/// two of these sharing one box.
typedef struct {
  float x, y, width, height;
  uint16_t unit;
  uint8_t flags;
} LavaPDFChar;

/// The page's text in reading order. Null with `count` 0 for a page with no
/// text, which a scanned page is; free a non-null result with
/// `lava_pdf_free_text`.
LavaPDFChar *lava_pdf_page_text(LavaPDFDocument *document, int page,
                                size_t *count);
void lava_pdf_free_text(LavaPDFChar *text);

/// The document's title as UTF-8, or null if it states none. Free with
/// `lava_pdf_free_string`.
char *lava_pdf_title(LavaPDFDocument *document);
void lava_pdf_free_string(char *string);

#ifdef __cplusplus
}
#endif
