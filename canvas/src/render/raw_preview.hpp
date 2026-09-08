#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace canvas {

/// Where a preview sits inside its container, in bytes from the start of the
/// file. Both numbers come from the file and neither is trusted.
struct PreviewSpan {
  uint64_t offset = 0;
  uint64_t length = 0;
};

/// Whether `path`'s extension names a camera raw this can open.
///
/// By extension rather than by sniffing, and for the same reason `ImageFormats`
/// in LavaView is: the question is asked about every file in a folder, and
/// sniffing means opening all of them to decide what Next lands on. Mirror any
/// change here in `ImageFormats.extensions`.
bool isRawPhoto(const std::string &path);

/// The camera's own rendering of a raw file, as JPEG bytes, or empty.
///
/// A raw file is a negative: sensor readings behind a colour filter array,
/// with no white balance, no tone curve and no demosaic applied. Turning that
/// into a picture is a decision — several of them — and a viewer has no
/// business making decisions the photographer's camera already made. So this
/// takes what the camera wrote: every raw container carries the JPEG its own
/// processor produced, which is what was on the screen on the back of the
/// body, and for looking at photographs that is the *right* image rather than
/// a fallback.
///
/// Empty for a file that is not a raw container, holds no displayable preview,
/// or is damaged. Every failure answers the same way, because a caller can do
/// nothing different with the reasons.
std::vector<uint8_t> readRawPreview(const std::string &path);

/// Every preview a TIFF-based container declares, largest first.
///
/// Split out from the file reading so it can be tested against bytes that no
/// camera would ever write. `fileSize` is what the spans are bounded against —
/// `count` may be only the head of the file, since a preview's *pixels* are
/// usually far beyond where its offset is written down.
std::vector<PreviewSpan> findRawPreviews(const uint8_t *bytes, size_t count,
                                         uint64_t fileSize);

/// Whether these bytes begin a JPEG that a baseline decoder can read.
///
/// The discriminator that makes "largest preview" safe. A CR2's sensor data is
/// also a JPEG stream reached through the same tags, and it is *bigger* than
/// the preview — but it is a lossless JPEG (`SOF3`) holding an undemosaiced
/// mosaic, so a viewer that just took the largest would show a grey grid. Only
/// the frame headers stb can actually decode are accepted.
bool isDisplayableJpeg(const uint8_t *bytes, size_t count);

/// How much of a file's head is read to find its IFDs.
///
/// The offsets are near the front — the structure of a TIFF is written before
/// the pixels it points at — so this is generous rather than calculated.
constexpr size_t kRawHeaderBytes = 256 * 1024;

/// How much of a candidate is read to decide whether it is displayable.
///
/// An Exif APP1 segment is capped at 64 KiB by the format and a JPEG may carry
/// more than one, so the frame header can legitimately sit some way in.
constexpr size_t kJpegProbeBytes = 256 * 1024;

}  // namespace canvas
