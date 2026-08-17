#pragma once

#include <cstdint>
#include <vector>

namespace canvas {

/// What a consumer said it can import, for one DRM format.
///
/// The pair travels together because neither half means anything alone: a
/// format the consumer cannot read is not a candidate, and a format with no
/// modifier in common is the same refusal spelled differently. See
/// `DmabufImage::exportFormats` for the formats worth asking about, and
/// `DmabufImage::create` for what is done with the answer.
///
/// Its own header, free of Vulkan, because it crosses the bridge: it is a
/// parameter of `Engine::openExported`, and the Swift importer completes every
/// type a public method names — including the `std::vector` element, which a
/// forward declaration cannot satisfy.
struct ExportFormatSupport {
  uint32_t              drmFormat = 0;
  std::vector<uint64_t> modifiers;
};

}  // namespace canvas
