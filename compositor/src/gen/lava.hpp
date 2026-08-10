#ifndef __NPRPC_LAVA_HPP__
#define __NPRPC_LAVA_HPP__

#include <cstring>
#include <variant>
#include <nprpc/flat.hpp>
#include <nprpc/nprpc.hpp>
#include <nprpc/bidi_stream.hpp>
#include <nprpc/stream_writer.hpp>
#include <nprpc/stream_reader.hpp>

// Module export macro
#ifdef NPRPC_EXPORTS
#  define LAVA_API NPRPC_EXPORT_ATTR
#else
#  define LAVA_API NPRPC_IMPORT_ATTR
#endif

namespace lava {

class FontNotFound : public ::nprpc::Exception {
public:
  std::string path;

  FontNotFound() : ::nprpc::Exception("FontNotFound") {} 
  FontNotFound(std::string _path)
    : ::nprpc::Exception("FontNotFound")
    , path(_path)
  {
  }
};

namespace flat {
struct FontNotFound {
  uint32_t __ex_id;
  ::nprpc::flat::String path;
};

class FontNotFound_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<FontNotFound*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const FontNotFound*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  FontNotFound_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& __ex_id() const noexcept { return base().__ex_id;}
  uint32_t& __ex_id() noexcept { return base().__ex_id;}
  void path(const char* str) { new (&base().path) ::nprpc::flat::String(buffer_, str); }
  void path(const std::string& str) { new (&base().path) ::nprpc::flat::String(buffer_, str); }
  auto path() noexcept { return (::nprpc::flat::Span<char>)base().path; }
  auto path() const noexcept { return (::nprpc::flat::Span<const char>)base().path; }
  auto path_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(FontNotFound, path)); }
};
} // namespace flat

class ImageNotFound : public ::nprpc::Exception {
public:
  std::string path;

  ImageNotFound() : ::nprpc::Exception("ImageNotFound") {} 
  ImageNotFound(std::string _path)
    : ::nprpc::Exception("ImageNotFound")
    , path(_path)
  {
  }
};

namespace flat {
struct ImageNotFound {
  uint32_t __ex_id;
  ::nprpc::flat::String path;
};

class ImageNotFound_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<ImageNotFound*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const ImageNotFound*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  ImageNotFound_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& __ex_id() const noexcept { return base().__ex_id;}
  uint32_t& __ex_id() noexcept { return base().__ex_id;}
  void path(const char* str) { new (&base().path) ::nprpc::flat::String(buffer_, str); }
  void path(const std::string& str) { new (&base().path) ::nprpc::flat::String(buffer_, str); }
  auto path() noexcept { return (::nprpc::flat::Span<char>)base().path; }
  auto path() const noexcept { return (::nprpc::flat::Span<const char>)base().path; }
  auto path_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(ImageNotFound, path)); }
};
} // namespace flat

struct ImageInfo {
  uint32_t id;
  uint32_t width;
  uint32_t height;
};

namespace flat {
struct ImageInfo {
  uint32_t id;
  uint32_t width;
  uint32_t height;
};

class ImageInfo_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<ImageInfo*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const ImageInfo*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  ImageInfo_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& id() const noexcept { return base().id;}
  uint32_t& id() noexcept { return base().id;}
  const uint32_t& width() const noexcept { return base().width;}
  uint32_t& width() noexcept { return base().width;}
  const uint32_t& height() const noexcept { return base().height;}
  uint32_t& height() noexcept { return base().height;}
};
} // namespace flat

class ArenaNotFound : public ::nprpc::Exception {
public:
  std::string arenaId;

  ArenaNotFound() : ::nprpc::Exception("ArenaNotFound") {} 
  ArenaNotFound(std::string _arenaId)
    : ::nprpc::Exception("ArenaNotFound")
    , arenaId(_arenaId)
  {
  }
};

namespace flat {
struct ArenaNotFound {
  uint32_t __ex_id;
  ::nprpc::flat::String arenaId;
};

class ArenaNotFound_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<ArenaNotFound*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const ArenaNotFound*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  ArenaNotFound_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& __ex_id() const noexcept { return base().__ex_id;}
  uint32_t& __ex_id() noexcept { return base().__ex_id;}
  void arenaId(const char* str) { new (&base().arenaId) ::nprpc::flat::String(buffer_, str); }
  void arenaId(const std::string& str) { new (&base().arenaId) ::nprpc::flat::String(buffer_, str); }
  auto arenaId() noexcept { return (::nprpc::flat::Span<char>)base().arenaId; }
  auto arenaId() const noexcept { return (::nprpc::flat::Span<const char>)base().arenaId; }
  auto arenaId_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(ArenaNotFound, arenaId)); }
};
} // namespace flat

enum class PanelEdge : uint32_t {
  top,
  bottom,
  left,
  right
};
enum class WindowFrame : uint32_t {
  server,
  client
};
class SurfaceNotFound : public ::nprpc::Exception {
public:
  uint32_t surfaceId;

  SurfaceNotFound() : ::nprpc::Exception("SurfaceNotFound") {} 
  SurfaceNotFound(uint32_t _surfaceId)
    : ::nprpc::Exception("SurfaceNotFound")
    , surfaceId(_surfaceId)
  {
  }
};

namespace flat {
struct SurfaceNotFound {
  uint32_t __ex_id;
  uint32_t surfaceId;
};

class SurfaceNotFound_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<SurfaceNotFound*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const SurfaceNotFound*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  SurfaceNotFound_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& __ex_id() const noexcept { return base().__ex_id;}
  uint32_t& __ex_id() noexcept { return base().__ex_id;}
  const uint32_t& surfaceId() const noexcept { return base().surfaceId;}
  uint32_t& surfaceId() noexcept { return base().surfaceId;}
};
} // namespace flat

class CaptureFailed : public ::nprpc::Exception {
public:
  uint32_t surfaceId;

  CaptureFailed() : ::nprpc::Exception("CaptureFailed") {} 
  CaptureFailed(uint32_t _surfaceId)
    : ::nprpc::Exception("CaptureFailed")
    , surfaceId(_surfaceId)
  {
  }
};

namespace flat {
struct CaptureFailed {
  uint32_t __ex_id;
  uint32_t surfaceId;
};

class CaptureFailed_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<CaptureFailed*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const CaptureFailed*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  CaptureFailed_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& __ex_id() const noexcept { return base().__ex_id;}
  uint32_t& __ex_id() noexcept { return base().__ex_id;}
  const uint32_t& surfaceId() const noexcept { return base().surfaceId;}
  uint32_t& surfaceId() noexcept { return base().surfaceId;}
};
} // namespace flat

struct Appearance {
  float cornerRadius;
  float shadowBlur;
  float shadowOpacity;
  float shadowOffsetY;
};

namespace flat {
struct Appearance {
  float cornerRadius;
  float shadowBlur;
  float shadowOpacity;
  float shadowOffsetY;
};

class Appearance_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<Appearance*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const Appearance*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  Appearance_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const float& cornerRadius() const noexcept { return base().cornerRadius;}
  float& cornerRadius() noexcept { return base().cornerRadius;}
  const float& shadowBlur() const noexcept { return base().shadowBlur;}
  float& shadowBlur() noexcept { return base().shadowBlur;}
  const float& shadowOpacity() const noexcept { return base().shadowOpacity;}
  float& shadowOpacity() noexcept { return base().shadowOpacity;}
  const float& shadowOffsetY() const noexcept { return base().shadowOffsetY;}
  float& shadowOffsetY() noexcept { return base().shadowOffsetY;}
};
} // namespace flat

struct KeyboardSettings {
  std::string layout;
  std::string variant;
  std::string options;
  std::string model;
  std::string rules;
  int32_t repeatRate;
  int32_t repeatDelay;
  std::string modKey;
};

namespace flat {
struct KeyboardSettings {
  ::nprpc::flat::String layout;
  ::nprpc::flat::String variant;
  ::nprpc::flat::String options;
  ::nprpc::flat::String model;
  ::nprpc::flat::String rules;
  int32_t repeatRate;
  int32_t repeatDelay;
  ::nprpc::flat::String modKey;
};

class KeyboardSettings_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<KeyboardSettings*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const KeyboardSettings*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  KeyboardSettings_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void layout(const char* str) { new (&base().layout) ::nprpc::flat::String(buffer_, str); }
  void layout(const std::string& str) { new (&base().layout) ::nprpc::flat::String(buffer_, str); }
  auto layout() noexcept { return (::nprpc::flat::Span<char>)base().layout; }
  auto layout() const noexcept { return (::nprpc::flat::Span<const char>)base().layout; }
  auto layout_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyboardSettings, layout)); }
  void variant(const char* str) { new (&base().variant) ::nprpc::flat::String(buffer_, str); }
  void variant(const std::string& str) { new (&base().variant) ::nprpc::flat::String(buffer_, str); }
  auto variant() noexcept { return (::nprpc::flat::Span<char>)base().variant; }
  auto variant() const noexcept { return (::nprpc::flat::Span<const char>)base().variant; }
  auto variant_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyboardSettings, variant)); }
  void options(const char* str) { new (&base().options) ::nprpc::flat::String(buffer_, str); }
  void options(const std::string& str) { new (&base().options) ::nprpc::flat::String(buffer_, str); }
  auto options() noexcept { return (::nprpc::flat::Span<char>)base().options; }
  auto options() const noexcept { return (::nprpc::flat::Span<const char>)base().options; }
  auto options_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyboardSettings, options)); }
  void model(const char* str) { new (&base().model) ::nprpc::flat::String(buffer_, str); }
  void model(const std::string& str) { new (&base().model) ::nprpc::flat::String(buffer_, str); }
  auto model() noexcept { return (::nprpc::flat::Span<char>)base().model; }
  auto model() const noexcept { return (::nprpc::flat::Span<const char>)base().model; }
  auto model_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyboardSettings, model)); }
  void rules(const char* str) { new (&base().rules) ::nprpc::flat::String(buffer_, str); }
  void rules(const std::string& str) { new (&base().rules) ::nprpc::flat::String(buffer_, str); }
  auto rules() noexcept { return (::nprpc::flat::Span<char>)base().rules; }
  auto rules() const noexcept { return (::nprpc::flat::Span<const char>)base().rules; }
  auto rules_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyboardSettings, rules)); }
  const int32_t& repeatRate() const noexcept { return base().repeatRate;}
  int32_t& repeatRate() noexcept { return base().repeatRate;}
  const int32_t& repeatDelay() const noexcept { return base().repeatDelay;}
  int32_t& repeatDelay() noexcept { return base().repeatDelay;}
  void modKey(const char* str) { new (&base().modKey) ::nprpc::flat::String(buffer_, str); }
  void modKey(const std::string& str) { new (&base().modKey) ::nprpc::flat::String(buffer_, str); }
  auto modKey() noexcept { return (::nprpc::flat::Span<char>)base().modKey; }
  auto modKey() const noexcept { return (::nprpc::flat::Span<const char>)base().modKey; }
  auto modKey_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyboardSettings, modKey)); }
};
} // namespace flat

struct KeyboardLayout {
  std::string code;
  std::string variant;
  std::string description;
};

namespace flat {
struct KeyboardLayout {
  ::nprpc::flat::String code;
  ::nprpc::flat::String variant;
  ::nprpc::flat::String description;
};

class KeyboardLayout_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<KeyboardLayout*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const KeyboardLayout*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  KeyboardLayout_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void code(const char* str) { new (&base().code) ::nprpc::flat::String(buffer_, str); }
  void code(const std::string& str) { new (&base().code) ::nprpc::flat::String(buffer_, str); }
  auto code() noexcept { return (::nprpc::flat::Span<char>)base().code; }
  auto code() const noexcept { return (::nprpc::flat::Span<const char>)base().code; }
  auto code_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyboardLayout, code)); }
  void variant(const char* str) { new (&base().variant) ::nprpc::flat::String(buffer_, str); }
  void variant(const std::string& str) { new (&base().variant) ::nprpc::flat::String(buffer_, str); }
  auto variant() noexcept { return (::nprpc::flat::Span<char>)base().variant; }
  auto variant() const noexcept { return (::nprpc::flat::Span<const char>)base().variant; }
  auto variant_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyboardLayout, variant)); }
  void description(const char* str) { new (&base().description) ::nprpc::flat::String(buffer_, str); }
  void description(const std::string& str) { new (&base().description) ::nprpc::flat::String(buffer_, str); }
  auto description() noexcept { return (::nprpc::flat::Span<char>)base().description; }
  auto description() const noexcept { return (::nprpc::flat::Span<const char>)base().description; }
  auto description_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyboardLayout, description)); }
};
} // namespace flat

struct KeyBinding {
  std::string modifiers;
  std::string key;
  std::string action;
  std::string description;
};

namespace flat {
struct KeyBinding {
  ::nprpc::flat::String modifiers;
  ::nprpc::flat::String key;
  ::nprpc::flat::String action;
  ::nprpc::flat::String description;
};

class KeyBinding_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<KeyBinding*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const KeyBinding*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  KeyBinding_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void modifiers(const char* str) { new (&base().modifiers) ::nprpc::flat::String(buffer_, str); }
  void modifiers(const std::string& str) { new (&base().modifiers) ::nprpc::flat::String(buffer_, str); }
  auto modifiers() noexcept { return (::nprpc::flat::Span<char>)base().modifiers; }
  auto modifiers() const noexcept { return (::nprpc::flat::Span<const char>)base().modifiers; }
  auto modifiers_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyBinding, modifiers)); }
  void key(const char* str) { new (&base().key) ::nprpc::flat::String(buffer_, str); }
  void key(const std::string& str) { new (&base().key) ::nprpc::flat::String(buffer_, str); }
  auto key() noexcept { return (::nprpc::flat::Span<char>)base().key; }
  auto key() const noexcept { return (::nprpc::flat::Span<const char>)base().key; }
  auto key_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyBinding, key)); }
  void action(const char* str) { new (&base().action) ::nprpc::flat::String(buffer_, str); }
  void action(const std::string& str) { new (&base().action) ::nprpc::flat::String(buffer_, str); }
  auto action() noexcept { return (::nprpc::flat::Span<char>)base().action; }
  auto action() const noexcept { return (::nprpc::flat::Span<const char>)base().action; }
  auto action_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyBinding, action)); }
  void description(const char* str) { new (&base().description) ::nprpc::flat::String(buffer_, str); }
  void description(const std::string& str) { new (&base().description) ::nprpc::flat::String(buffer_, str); }
  auto description() noexcept { return (::nprpc::flat::Span<char>)base().description; }
  auto description() const noexcept { return (::nprpc::flat::Span<const char>)base().description; }
  auto description_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(KeyBinding, description)); }
};
} // namespace flat

struct OutputMode {
  uint32_t width;
  uint32_t height;
  uint32_t refresh;
  bool current;
  bool preferred;
};

namespace flat {
struct OutputMode {
  uint32_t width;
  uint32_t height;
  uint32_t refresh;
  ::nprpc::flat::Boolean current;
  ::nprpc::flat::Boolean preferred;
};

class OutputMode_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<OutputMode*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const OutputMode*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  OutputMode_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& width() const noexcept { return base().width;}
  uint32_t& width() noexcept { return base().width;}
  const uint32_t& height() const noexcept { return base().height;}
  uint32_t& height() noexcept { return base().height;}
  const uint32_t& refresh() const noexcept { return base().refresh;}
  uint32_t& refresh() noexcept { return base().refresh;}
  const ::nprpc::flat::Boolean& current() const noexcept { return base().current;}
  ::nprpc::flat::Boolean& current() noexcept { return base().current;}
  const ::nprpc::flat::Boolean& preferred() const noexcept { return base().preferred;}
  ::nprpc::flat::Boolean& preferred() noexcept { return base().preferred;}
};
} // namespace flat

struct OutputInfo {
  std::string name;
  std::string description;
  bool enabled;
  int32_t x;
  int32_t y;
  uint32_t width;
  uint32_t height;
  uint32_t refresh;
  float scale;
  uint32_t transform;
};

namespace flat {
struct OutputInfo {
  ::nprpc::flat::String name;
  ::nprpc::flat::String description;
  ::nprpc::flat::Boolean enabled;
  int32_t x;
  int32_t y;
  uint32_t width;
  uint32_t height;
  uint32_t refresh;
  float scale;
  uint32_t transform;
};

class OutputInfo_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<OutputInfo*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const OutputInfo*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  OutputInfo_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void name(const char* str) { new (&base().name) ::nprpc::flat::String(buffer_, str); }
  void name(const std::string& str) { new (&base().name) ::nprpc::flat::String(buffer_, str); }
  auto name() noexcept { return (::nprpc::flat::Span<char>)base().name; }
  auto name() const noexcept { return (::nprpc::flat::Span<const char>)base().name; }
  auto name_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(OutputInfo, name)); }
  void description(const char* str) { new (&base().description) ::nprpc::flat::String(buffer_, str); }
  void description(const std::string& str) { new (&base().description) ::nprpc::flat::String(buffer_, str); }
  auto description() noexcept { return (::nprpc::flat::Span<char>)base().description; }
  auto description() const noexcept { return (::nprpc::flat::Span<const char>)base().description; }
  auto description_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(OutputInfo, description)); }
  const ::nprpc::flat::Boolean& enabled() const noexcept { return base().enabled;}
  ::nprpc::flat::Boolean& enabled() noexcept { return base().enabled;}
  const int32_t& x() const noexcept { return base().x;}
  int32_t& x() noexcept { return base().x;}
  const int32_t& y() const noexcept { return base().y;}
  int32_t& y() noexcept { return base().y;}
  const uint32_t& width() const noexcept { return base().width;}
  uint32_t& width() noexcept { return base().width;}
  const uint32_t& height() const noexcept { return base().height;}
  uint32_t& height() noexcept { return base().height;}
  const uint32_t& refresh() const noexcept { return base().refresh;}
  uint32_t& refresh() noexcept { return base().refresh;}
  const float& scale() const noexcept { return base().scale;}
  float& scale() noexcept { return base().scale;}
  const uint32_t& transform() const noexcept { return base().transform;}
  uint32_t& transform() noexcept { return base().transform;}
};
} // namespace flat

struct OutputRequest {
  std::string name;
  bool enabled;
  uint32_t width;
  uint32_t height;
  uint32_t refresh;
  float scale;
  int32_t x;
  int32_t y;
  uint32_t transform;
};

namespace flat {
struct OutputRequest {
  ::nprpc::flat::String name;
  ::nprpc::flat::Boolean enabled;
  uint32_t width;
  uint32_t height;
  uint32_t refresh;
  float scale;
  int32_t x;
  int32_t y;
  uint32_t transform;
};

class OutputRequest_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<OutputRequest*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const OutputRequest*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  OutputRequest_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void name(const char* str) { new (&base().name) ::nprpc::flat::String(buffer_, str); }
  void name(const std::string& str) { new (&base().name) ::nprpc::flat::String(buffer_, str); }
  auto name() noexcept { return (::nprpc::flat::Span<char>)base().name; }
  auto name() const noexcept { return (::nprpc::flat::Span<const char>)base().name; }
  auto name_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(OutputRequest, name)); }
  const ::nprpc::flat::Boolean& enabled() const noexcept { return base().enabled;}
  ::nprpc::flat::Boolean& enabled() noexcept { return base().enabled;}
  const uint32_t& width() const noexcept { return base().width;}
  uint32_t& width() noexcept { return base().width;}
  const uint32_t& height() const noexcept { return base().height;}
  uint32_t& height() noexcept { return base().height;}
  const uint32_t& refresh() const noexcept { return base().refresh;}
  uint32_t& refresh() noexcept { return base().refresh;}
  const float& scale() const noexcept { return base().scale;}
  float& scale() noexcept { return base().scale;}
  const int32_t& x() const noexcept { return base().x;}
  int32_t& x() noexcept { return base().x;}
  const int32_t& y() const noexcept { return base().y;}
  int32_t& y() noexcept { return base().y;}
  const uint32_t& transform() const noexcept { return base().transform;}
  uint32_t& transform() noexcept { return base().transform;}
};
} // namespace flat

class OutputNotFound : public ::nprpc::Exception {
public:
  std::string name;

  OutputNotFound() : ::nprpc::Exception("OutputNotFound") {} 
  OutputNotFound(std::string _name)
    : ::nprpc::Exception("OutputNotFound")
    , name(_name)
  {
  }
};

namespace flat {
struct OutputNotFound {
  uint32_t __ex_id;
  ::nprpc::flat::String name;
};

class OutputNotFound_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<OutputNotFound*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const OutputNotFound*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  OutputNotFound_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& __ex_id() const noexcept { return base().__ex_id;}
  uint32_t& __ex_id() noexcept { return base().__ex_id;}
  void name(const char* str) { new (&base().name) ::nprpc::flat::String(buffer_, str); }
  void name(const std::string& str) { new (&base().name) ::nprpc::flat::String(buffer_, str); }
  auto name() noexcept { return (::nprpc::flat::Span<char>)base().name; }
  auto name() const noexcept { return (::nprpc::flat::Span<const char>)base().name; }
  auto name_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(OutputNotFound, name)); }
};
} // namespace flat

class SettingsWriteFailed : public ::nprpc::Exception {
public:
  std::string path;
  std::string reason;

  SettingsWriteFailed() : ::nprpc::Exception("SettingsWriteFailed") {} 
  SettingsWriteFailed(std::string _path, std::string _reason)
    : ::nprpc::Exception("SettingsWriteFailed")
    , path(_path)
    , reason(_reason)
  {
  }
};

namespace flat {
struct SettingsWriteFailed {
  uint32_t __ex_id;
  ::nprpc::flat::String path;
  ::nprpc::flat::String reason;
};

class SettingsWriteFailed_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<SettingsWriteFailed*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const SettingsWriteFailed*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  SettingsWriteFailed_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& __ex_id() const noexcept { return base().__ex_id;}
  uint32_t& __ex_id() noexcept { return base().__ex_id;}
  void path(const char* str) { new (&base().path) ::nprpc::flat::String(buffer_, str); }
  void path(const std::string& str) { new (&base().path) ::nprpc::flat::String(buffer_, str); }
  auto path() noexcept { return (::nprpc::flat::Span<char>)base().path; }
  auto path() const noexcept { return (::nprpc::flat::Span<const char>)base().path; }
  auto path_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(SettingsWriteFailed, path)); }
  void reason(const char* str) { new (&base().reason) ::nprpc::flat::String(buffer_, str); }
  void reason(const std::string& str) { new (&base().reason) ::nprpc::flat::String(buffer_, str); }
  auto reason() noexcept { return (::nprpc::flat::Span<char>)base().reason; }
  auto reason() const noexcept { return (::nprpc::flat::Span<const char>)base().reason; }
  auto reason_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(SettingsWriteFailed, reason)); }
};
} // namespace flat

struct ActiveWindow {
  uint32_t surfaceId;
  std::string title;
  std::string menuService;
  std::string menuObjectPath;
};

namespace flat {
struct ActiveWindow {
  uint32_t surfaceId;
  ::nprpc::flat::String title;
  ::nprpc::flat::String menuService;
  ::nprpc::flat::String menuObjectPath;
};

class ActiveWindow_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<ActiveWindow*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const ActiveWindow*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  ActiveWindow_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& surfaceId() const noexcept { return base().surfaceId;}
  uint32_t& surfaceId() noexcept { return base().surfaceId;}
  void title(const char* str) { new (&base().title) ::nprpc::flat::String(buffer_, str); }
  void title(const std::string& str) { new (&base().title) ::nprpc::flat::String(buffer_, str); }
  auto title() noexcept { return (::nprpc::flat::Span<char>)base().title; }
  auto title() const noexcept { return (::nprpc::flat::Span<const char>)base().title; }
  auto title_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(ActiveWindow, title)); }
  void menuService(const char* str) { new (&base().menuService) ::nprpc::flat::String(buffer_, str); }
  void menuService(const std::string& str) { new (&base().menuService) ::nprpc::flat::String(buffer_, str); }
  auto menuService() noexcept { return (::nprpc::flat::Span<char>)base().menuService; }
  auto menuService() const noexcept { return (::nprpc::flat::Span<const char>)base().menuService; }
  auto menuService_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(ActiveWindow, menuService)); }
  void menuObjectPath(const char* str) { new (&base().menuObjectPath) ::nprpc::flat::String(buffer_, str); }
  void menuObjectPath(const std::string& str) { new (&base().menuObjectPath) ::nprpc::flat::String(buffer_, str); }
  auto menuObjectPath() noexcept { return (::nprpc::flat::Span<char>)base().menuObjectPath; }
  auto menuObjectPath() const noexcept { return (::nprpc::flat::Span<const char>)base().menuObjectPath; }
  auto menuObjectPath_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(ActiveWindow, menuObjectPath)); }
};
} // namespace flat

struct WindowInfo {
  uint32_t surfaceId;
  std::string title;
  std::string appId;
  uint32_t workspace;
  bool minimized;
  bool focused;
};

namespace flat {
struct WindowInfo {
  uint32_t surfaceId;
  ::nprpc::flat::String title;
  ::nprpc::flat::String appId;
  uint32_t workspace;
  ::nprpc::flat::Boolean minimized;
  ::nprpc::flat::Boolean focused;
};

class WindowInfo_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<WindowInfo*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const WindowInfo*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  WindowInfo_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& surfaceId() const noexcept { return base().surfaceId;}
  uint32_t& surfaceId() noexcept { return base().surfaceId;}
  void title(const char* str) { new (&base().title) ::nprpc::flat::String(buffer_, str); }
  void title(const std::string& str) { new (&base().title) ::nprpc::flat::String(buffer_, str); }
  auto title() noexcept { return (::nprpc::flat::Span<char>)base().title; }
  auto title() const noexcept { return (::nprpc::flat::Span<const char>)base().title; }
  auto title_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(WindowInfo, title)); }
  void appId(const char* str) { new (&base().appId) ::nprpc::flat::String(buffer_, str); }
  void appId(const std::string& str) { new (&base().appId) ::nprpc::flat::String(buffer_, str); }
  auto appId() noexcept { return (::nprpc::flat::Span<char>)base().appId; }
  auto appId() const noexcept { return (::nprpc::flat::Span<const char>)base().appId; }
  auto appId_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(WindowInfo, appId)); }
  const uint32_t& workspace() const noexcept { return base().workspace;}
  uint32_t& workspace() noexcept { return base().workspace;}
  const ::nprpc::flat::Boolean& minimized() const noexcept { return base().minimized;}
  ::nprpc::flat::Boolean& minimized() noexcept { return base().minimized;}
  const ::nprpc::flat::Boolean& focused() const noexcept { return base().focused;}
  ::nprpc::flat::Boolean& focused() noexcept { return base().focused;}
};
} // namespace flat

struct WindowList {
  uint32_t serial;
  uint32_t currentWorkspace;
  std::vector<WindowInfo> windows;
};

namespace flat {
struct WindowList {
  uint32_t serial;
  uint32_t currentWorkspace;
  ::nprpc::flat::Vector<flat::WindowInfo> windows;
};

class WindowList_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<WindowList*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const WindowList*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  WindowList_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& serial() const noexcept { return base().serial;}
  uint32_t& serial() noexcept { return base().serial;}
  const uint32_t& currentWorkspace() const noexcept { return base().currentWorkspace;}
  uint32_t& currentWorkspace() noexcept { return base().currentWorkspace;}
  void windows(std::uint32_t elements_size) { new (&base().windows) ::nprpc::flat::Vector<flat::WindowInfo>(buffer_, elements_size); }
  auto windows_d() noexcept { return ::nprpc::flat::Vector_Direct2<flat::WindowInfo,flat::WindowInfo_Direct>(buffer_, offset_ + offsetof(WindowList, windows)); }
  auto windows() noexcept { return ::nprpc::flat::Span_ref<flat::WindowInfo, flat::WindowInfo_Direct>(buffer_, base().windows.range(buffer_.data().data())); }
};
} // namespace flat

struct WindowListAck {
  uint32_t serial;
};

namespace flat {
struct WindowListAck {
  uint32_t serial;
};

class WindowListAck_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<WindowListAck*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const WindowListAck*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  WindowListAck_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& serial() const noexcept { return base().serial;}
  uint32_t& serial() noexcept { return base().serial;}
};
} // namespace flat

struct FocusAck {
  uint32_t surfaceId;
};

namespace flat {
struct FocusAck {
  uint32_t surfaceId;
};

class FocusAck_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<FocusAck*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const FocusAck*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  FocusAck_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& surfaceId() const noexcept { return base().surfaceId;}
  uint32_t& surfaceId() noexcept { return base().surfaceId;}
};
} // namespace flat

struct Capture {
  uint32_t width;
  uint32_t height;
  std::vector<uint8_t> png;
};

namespace flat {
struct Capture {
  uint32_t width;
  uint32_t height;
  ::nprpc::flat::Vector<uint8_t> png;
};

class Capture_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<Capture*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const Capture*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  Capture_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& width() const noexcept { return base().width;}
  uint32_t& width() noexcept { return base().width;}
  const uint32_t& height() const noexcept { return base().height;}
  uint32_t& height() noexcept { return base().height;}
  void png(std::uint32_t elements_size) { new (&base().png) ::nprpc::flat::Vector<uint8_t>(buffer_, elements_size); }
  auto png_d() noexcept { return ::nprpc::flat::Vector_Direct1<uint8_t>(buffer_, offset_ + offsetof(Capture, png)); }
  auto png() noexcept { return (::nprpc::flat::Span<uint8_t>)base().png; }
  const auto png() const noexcept { return (::nprpc::flat::Span<const uint8_t>)base().png; }
};
} // namespace flat

struct InputEvent {
  uint32_t serial;
  uint32_t kind;
  float x;
  float y;
  int32_t button;
  int32_t mods;
};

namespace flat {
struct InputEvent {
  uint32_t serial;
  uint32_t kind;
  float x;
  float y;
  int32_t button;
  int32_t mods;
};

class InputEvent_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<InputEvent*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const InputEvent*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  InputEvent_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& serial() const noexcept { return base().serial;}
  uint32_t& serial() noexcept { return base().serial;}
  const uint32_t& kind() const noexcept { return base().kind;}
  uint32_t& kind() noexcept { return base().kind;}
  const float& x() const noexcept { return base().x;}
  float& x() noexcept { return base().x;}
  const float& y() const noexcept { return base().y;}
  float& y() noexcept { return base().y;}
  const int32_t& button() const noexcept { return base().button;}
  int32_t& button() noexcept { return base().button;}
  const int32_t& mods() const noexcept { return base().mods;}
  int32_t& mods() noexcept { return base().mods;}
};
} // namespace flat

struct InputAck {
  uint32_t serial;
};

namespace flat {
struct InputAck {
  uint32_t serial;
};

class InputAck_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<InputAck*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const InputAck*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  InputAck_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& serial() const noexcept { return base().serial;}
  uint32_t& serial() noexcept { return base().serial;}
};
} // namespace flat

class LAVA_API ICompositor_Servant
  : public virtual ::nprpc::ObjectServant
{
public:
  static std::string_view _get_class() noexcept { return "lava/lava.Compositor"; }
  std::string_view get_class() const noexcept override { return ICompositor_Servant::_get_class(); }
  void dispatch(::nprpc::SessionContext& ctx, [[maybe_unused]] bool from_parent) override;
  virtual uint32_t RegisterFont (::nprpc::flat::Span<char> path, uint32_t pixelSize26_6, uint32_t faceIndex, uint32_t rasterFlags) = 0;
  virtual ImageInfo RegisterImage (::nprpc::flat::Span<char> path, uint32_t maxPixelSize) = 0;
  virtual ImageInfo RegisterImageData (::nprpc::flat::Span<uint8_t> bytes, uint32_t maxPixelSize) = 0;
  virtual void ReleaseImage (uint32_t id) = 0;
  virtual uint32_t CreateSurface (::nprpc::flat::Span<char> arenaId, uint32_t width, uint32_t height, ::nprpc::flat::Span<char> title, WindowFrame frame, ::nprpc::flat::Span<char> appId) = 0;
  virtual uint32_t CreatePanel (::nprpc::flat::Span<char> arenaId, PanelEdge edge, uint32_t thickness, ::nprpc::flat::Boolean reserve, ::nprpc::flat::Span<char> title, ::nprpc::flat::Span<char> appId) = 0;
  virtual void BeginMove (uint32_t surfaceId) = 0;
  virtual bool ToggleMaximize (uint32_t surfaceId) = 0;
  virtual void Minimize (uint32_t surfaceId) = 0;
  virtual void SetPanelThickness (uint32_t surfaceId, uint32_t thickness, uint32_t reserved) = 0;
  virtual ::nprpc::Task<> SubscribeWindows (::nprpc::BidiStream<WindowListAck, WindowList> stream) = 0;
  virtual void ActivateWindow (uint32_t surfaceId) = 0;
  virtual void SetInputRegion (uint32_t surfaceId, int32_t x, int32_t y, uint32_t w, uint32_t h) = 0;
  virtual Appearance GetAppearance () = 0;
  virtual void SetAppearance (flat::Appearance_Direct appearance) = 0;
  virtual KeyboardSettings GetKeyboard () = 0;
  virtual void SetKeyboard (flat::KeyboardSettings_Direct settings) = 0;
  virtual std::vector<KeyboardLayout> ListKeyboardLayouts () = 0;
  virtual std::vector<KeyBinding> ListKeyBindings () = 0;
  virtual std::vector<OutputInfo> ListOutputs () = 0;
  virtual std::vector<OutputMode> ListOutputModes (::nprpc::flat::Span<char> name) = 0;
  virtual void SetOutput (flat::OutputRequest_Direct request) = 0;
  virtual ::nprpc::Task<> SubscribeActiveWindow (::nprpc::BidiStream<FocusAck, ActiveWindow> stream) = 0;
  virtual void DestroySurface (uint32_t surfaceId) = 0;
  virtual void Present (uint32_t surfaceId) = 0;
  virtual void ScrollUnclaimed (uint32_t surfaceId, float dx, float dy) = 0;
  virtual void Heartbeat (uint32_t surfaceId) = 0;
  virtual ::nprpc::Task<> SubscribeInput (uint32_t surfaceId, ::nprpc::BidiStream<InputAck, InputEvent> stream) = 0;
  virtual std::vector<std::string> TakeDroppedPaths (uint32_t surfaceId) = 0;
  virtual Capture CaptureSurface (uint32_t surfaceId, int32_t x, int32_t y, int32_t w, int32_t h, int32_t maxSide) = 0;
  virtual std::string GetClipboard (uint32_t surfaceId) = 0;
  virtual void SetClipboard (uint32_t surfaceId, ::nprpc::flat::Span<char> text) = 0;
  virtual std::string GetPrimarySelection (uint32_t surfaceId) = 0;
  virtual void SetPrimarySelection (uint32_t surfaceId, ::nprpc::flat::Span<char> text) = 0;
};

class LAVA_API Compositor
  : public virtual ::nprpc::Object
{
  const uint8_t interface_idx_;
public:
  using servant_t = ICompositor_Servant;

  Compositor(uint8_t interface_idx) : interface_idx_(interface_idx) {}
  uint32_t RegisterFont (const std::string& path, uint32_t pixelSize26_6, uint32_t faceIndex, uint32_t rasterFlags);
  ::nprpc::Task<uint32_t> RegisterFontAsync (const std::string& path, uint32_t pixelSize26_6, uint32_t faceIndex, uint32_t rasterFlags, std::stop_token st = {});
  ImageInfo RegisterImage (const std::string& path, uint32_t maxPixelSize);
  ::nprpc::Task<ImageInfo> RegisterImageAsync (const std::string& path, uint32_t maxPixelSize, std::stop_token st = {});
  ImageInfo RegisterImageData (::nprpc::flat::Span<const uint8_t> bytes, uint32_t maxPixelSize);
  ::nprpc::Task<ImageInfo> RegisterImageDataAsync (::nprpc::flat::Span<const uint8_t> bytes, uint32_t maxPixelSize, std::stop_token st = {});
  void ReleaseImage (uint32_t id);
  ::nprpc::Task<void> ReleaseImageAsync (uint32_t id, std::stop_token st = {});
  uint32_t CreateSurface (const std::string& arenaId, uint32_t width, uint32_t height, const std::string& title, const WindowFrame& frame, const std::string& appId);
  ::nprpc::Task<uint32_t> CreateSurfaceAsync (const std::string& arenaId, uint32_t width, uint32_t height, const std::string& title, const WindowFrame& frame, const std::string& appId, std::stop_token st = {});
  uint32_t CreatePanel (const std::string& arenaId, const PanelEdge& edge, uint32_t thickness, bool reserve, const std::string& title, const std::string& appId);
  ::nprpc::Task<uint32_t> CreatePanelAsync (const std::string& arenaId, const PanelEdge& edge, uint32_t thickness, bool reserve, const std::string& title, const std::string& appId, std::stop_token st = {});
  void BeginMove (uint32_t surfaceId);
  ::nprpc::Task<void> BeginMoveAsync (uint32_t surfaceId, std::stop_token st = {});
  bool ToggleMaximize (uint32_t surfaceId);
  ::nprpc::Task<bool> ToggleMaximizeAsync (uint32_t surfaceId, std::stop_token st = {});
  void Minimize (uint32_t surfaceId);
  ::nprpc::Task<void> MinimizeAsync (uint32_t surfaceId, std::stop_token st = {});
  void SetPanelThickness (uint32_t surfaceId, uint32_t thickness, uint32_t reserved);
  ::nprpc::Task<void> SetPanelThicknessAsync (uint32_t surfaceId, uint32_t thickness, uint32_t reserved, std::stop_token st = {});
  std::pair<::nprpc::StreamWriter<WindowListAck>, ::nprpc::StreamReader<WindowList>> SubscribeWindows ();
  void ActivateWindow (uint32_t surfaceId);
  ::nprpc::Task<void> ActivateWindowAsync (uint32_t surfaceId, std::stop_token st = {});
  void SetInputRegion (uint32_t surfaceId, int32_t x, int32_t y, uint32_t w, uint32_t h);
  ::nprpc::Task<void> SetInputRegionAsync (uint32_t surfaceId, int32_t x, int32_t y, uint32_t w, uint32_t h, std::stop_token st = {});
  Appearance GetAppearance ();
  ::nprpc::Task<Appearance> GetAppearanceAsync (std::stop_token st = {});
  void SetAppearance (const Appearance& appearance);
  ::nprpc::Task<void> SetAppearanceAsync (const Appearance& appearance, std::stop_token st = {});
  KeyboardSettings GetKeyboard ();
  ::nprpc::Task<KeyboardSettings> GetKeyboardAsync (std::stop_token st = {});
  void SetKeyboard (const KeyboardSettings& settings);
  ::nprpc::Task<void> SetKeyboardAsync (const KeyboardSettings& settings, std::stop_token st = {});
  std::vector<KeyboardLayout> ListKeyboardLayouts ();
  ::nprpc::Task<std::vector<KeyboardLayout>> ListKeyboardLayoutsAsync (std::stop_token st = {});
  std::vector<KeyBinding> ListKeyBindings ();
  ::nprpc::Task<std::vector<KeyBinding>> ListKeyBindingsAsync (std::stop_token st = {});
  std::vector<OutputInfo> ListOutputs ();
  ::nprpc::Task<std::vector<OutputInfo>> ListOutputsAsync (std::stop_token st = {});
  std::vector<OutputMode> ListOutputModes (const std::string& name);
  ::nprpc::Task<std::vector<OutputMode>> ListOutputModesAsync (const std::string& name, std::stop_token st = {});
  void SetOutput (const OutputRequest& request);
  ::nprpc::Task<void> SetOutputAsync (const OutputRequest& request, std::stop_token st = {});
  std::pair<::nprpc::StreamWriter<FocusAck>, ::nprpc::StreamReader<ActiveWindow>> SubscribeActiveWindow ();
  void DestroySurface (uint32_t surfaceId);
  ::nprpc::Task<void> DestroySurfaceAsync (uint32_t surfaceId, std::stop_token st = {});
  void Present (uint32_t surfaceId);
  void ScrollUnclaimed (uint32_t surfaceId, float dx, float dy);
  void Heartbeat (uint32_t surfaceId);
  std::pair<::nprpc::StreamWriter<InputAck>, ::nprpc::StreamReader<InputEvent>> SubscribeInput (uint32_t surfaceId);
  std::vector<std::string> TakeDroppedPaths (uint32_t surfaceId);
  ::nprpc::Task<std::vector<std::string>> TakeDroppedPathsAsync (uint32_t surfaceId, std::stop_token st = {});
  Capture CaptureSurface (uint32_t surfaceId, int32_t x, int32_t y, int32_t w, int32_t h, int32_t maxSide);
  ::nprpc::Task<Capture> CaptureSurfaceAsync (uint32_t surfaceId, int32_t x, int32_t y, int32_t w, int32_t h, int32_t maxSide, std::stop_token st = {});
  std::string GetClipboard (uint32_t surfaceId);
  ::nprpc::Task<std::string> GetClipboardAsync (uint32_t surfaceId, std::stop_token st = {});
  void SetClipboard (uint32_t surfaceId, const std::string& text);
  ::nprpc::Task<void> SetClipboardAsync (uint32_t surfaceId, const std::string& text, std::stop_token st = {});
  std::string GetPrimarySelection (uint32_t surfaceId);
  ::nprpc::Task<std::string> GetPrimarySelectionAsync (uint32_t surfaceId, std::stop_token st = {});
  void SetPrimarySelection (uint32_t surfaceId, const std::string& text);
  ::nprpc::Task<void> SetPrimarySelectionAsync (uint32_t surfaceId, const std::string& text, std::stop_token st = {});
};

namespace helper {
inline void assign_from_flat_SetOutput_request(::lava::flat::OutputRequest_Direct& src, ::lava::OutputRequest& dest) {
  dest.name = (std::string_view)src.name();
  dest.enabled = (bool)src.enabled();
  dest.width = src.width();
  dest.height = src.height();
  dest.refresh = src.refresh();
  dest.scale = src.scale();
  dest.x = src.x();
  dest.y = src.y();
  dest.transform = src.transform();
}
}
} // module lava
namespace nprpc_stream {
template<>
inline ::lava::WindowList deserialize<::lava::WindowList>(::nprpc::flat_buffer& buf) {
  ::nprpc::impl::flat::StreamChunk_Direct __chunk(buf, sizeof(::nprpc::impl::Header));
  auto __span = __chunk.data();
  ::nprpc::flat_buffer __elem_buf;
  auto __mb = __elem_buf.prepare(__span.size());
  std::memcpy(__mb.data(), __span.data(), __span.size());
  __elem_buf.commit(__span.size());
  ::lava::WindowList __result;
  ::lava::flat::WindowList_Direct __d(__elem_buf, 0);
  __result.serial = __d.serial();
  __result.currentWorkspace = __d.currentWorkspace();
  {
    auto span = __d.windows();
    __result.windows.resize(span.size());
    auto it2 = std::begin(__result.windows);
    for (auto e : span) {
      (*it2).surfaceId = e.surfaceId();
      (*it2).title = (std::string_view)e.title();
      (*it2).appId = (std::string_view)e.appId();
      (*it2).workspace = e.workspace();
      (*it2).minimized = (bool)e.minimized();
      (*it2).focused = (bool)e.focused();
      ++it2;
    }
  }
  return __result;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::lava::WindowListAck deserialize<::lava::WindowListAck>(::nprpc::flat_buffer& buf) {
  ::nprpc::impl::flat::StreamChunk_Direct __chunk(buf, sizeof(::nprpc::impl::Header));
  auto __span = __chunk.data();
  ::nprpc::flat_buffer __elem_buf;
  auto __mb = __elem_buf.prepare(__span.size());
  std::memcpy(__mb.data(), __span.data(), __span.size());
  __elem_buf.commit(__span.size());
  ::lava::WindowListAck __result;
  ::lava::flat::WindowListAck_Direct __d(__elem_buf, 0);
  memcpy(&__result, __d.__data(), 4);
  return __result;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::nprpc::flat_buffer serialize<::lava::WindowListAck>(const ::lava::WindowListAck& value) {
  ::nprpc::flat_buffer __buf;
  __buf.prepare(4);
  __buf.commit(4);
  ::lava::flat::WindowListAck_Direct __d(__buf, 0);
  memcpy(__d.__data(), &value, 4);
  return __buf;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::nprpc::flat_buffer serialize<::lava::WindowList>(const ::lava::WindowList& value) {
  ::nprpc::flat_buffer __buf;
  __buf.prepare(16 + 128);
  __buf.commit(16);
  ::lava::flat::WindowList_Direct __d(__buf, 0);
  __d.serial() = value.serial;
  __d.currentWorkspace() = value.currentWorkspace;
  __d.windows(static_cast<uint32_t>(value.windows.size()));
  {
    auto span = __d.windows();
    auto it = value.windows.begin();
    for (auto e : span) {
      auto __ptr = ::nprpc::make_wrapper1(*it);
        e.surfaceId() = __ptr->surfaceId;
        e.title(__ptr->title);
        e.appId(__ptr->appId);
        e.workspace() = __ptr->workspace;
        e.minimized() = __ptr->minimized;
        e.focused() = __ptr->focused;
      ++it;
    }
  }
  return __buf;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::lava::ActiveWindow deserialize<::lava::ActiveWindow>(::nprpc::flat_buffer& buf) {
  ::nprpc::impl::flat::StreamChunk_Direct __chunk(buf, sizeof(::nprpc::impl::Header));
  auto __span = __chunk.data();
  ::nprpc::flat_buffer __elem_buf;
  auto __mb = __elem_buf.prepare(__span.size());
  std::memcpy(__mb.data(), __span.data(), __span.size());
  __elem_buf.commit(__span.size());
  ::lava::ActiveWindow __result;
  ::lava::flat::ActiveWindow_Direct __d(__elem_buf, 0);
  __result.surfaceId = __d.surfaceId();
  __result.title = (std::string_view)__d.title();
  __result.menuService = (std::string_view)__d.menuService();
  __result.menuObjectPath = (std::string_view)__d.menuObjectPath();
  return __result;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::lava::FocusAck deserialize<::lava::FocusAck>(::nprpc::flat_buffer& buf) {
  ::nprpc::impl::flat::StreamChunk_Direct __chunk(buf, sizeof(::nprpc::impl::Header));
  auto __span = __chunk.data();
  ::nprpc::flat_buffer __elem_buf;
  auto __mb = __elem_buf.prepare(__span.size());
  std::memcpy(__mb.data(), __span.data(), __span.size());
  __elem_buf.commit(__span.size());
  ::lava::FocusAck __result;
  ::lava::flat::FocusAck_Direct __d(__elem_buf, 0);
  memcpy(&__result, __d.__data(), 4);
  return __result;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::nprpc::flat_buffer serialize<::lava::FocusAck>(const ::lava::FocusAck& value) {
  ::nprpc::flat_buffer __buf;
  __buf.prepare(4);
  __buf.commit(4);
  ::lava::flat::FocusAck_Direct __d(__buf, 0);
  memcpy(__d.__data(), &value, 4);
  return __buf;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::nprpc::flat_buffer serialize<::lava::ActiveWindow>(const ::lava::ActiveWindow& value) {
  ::nprpc::flat_buffer __buf;
  __buf.prepare(28 + 128);
  __buf.commit(28);
  ::lava::flat::ActiveWindow_Direct __d(__buf, 0);
  __d.surfaceId() = value.surfaceId;
  __d.title(value.title);
  __d.menuService(value.menuService);
  __d.menuObjectPath(value.menuObjectPath);
  return __buf;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::lava::InputEvent deserialize<::lava::InputEvent>(::nprpc::flat_buffer& buf) {
  ::nprpc::impl::flat::StreamChunk_Direct __chunk(buf, sizeof(::nprpc::impl::Header));
  auto __span = __chunk.data();
  ::nprpc::flat_buffer __elem_buf;
  auto __mb = __elem_buf.prepare(__span.size());
  std::memcpy(__mb.data(), __span.data(), __span.size());
  __elem_buf.commit(__span.size());
  ::lava::InputEvent __result;
  ::lava::flat::InputEvent_Direct __d(__elem_buf, 0);
  memcpy(&__result, __d.__data(), 24);
  return __result;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::lava::InputAck deserialize<::lava::InputAck>(::nprpc::flat_buffer& buf) {
  ::nprpc::impl::flat::StreamChunk_Direct __chunk(buf, sizeof(::nprpc::impl::Header));
  auto __span = __chunk.data();
  ::nprpc::flat_buffer __elem_buf;
  auto __mb = __elem_buf.prepare(__span.size());
  std::memcpy(__mb.data(), __span.data(), __span.size());
  __elem_buf.commit(__span.size());
  ::lava::InputAck __result;
  ::lava::flat::InputAck_Direct __d(__elem_buf, 0);
  memcpy(&__result, __d.__data(), 4);
  return __result;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::nprpc::flat_buffer serialize<::lava::InputAck>(const ::lava::InputAck& value) {
  ::nprpc::flat_buffer __buf;
  __buf.prepare(4);
  __buf.commit(4);
  ::lava::flat::InputAck_Direct __d(__buf, 0);
  memcpy(__d.__data(), &value, 4);
  return __buf;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::nprpc::flat_buffer serialize<::lava::InputEvent>(const ::lava::InputEvent& value) {
  ::nprpc::flat_buffer __buf;
  __buf.prepare(24);
  __buf.commit(24);
  ::lava::flat::InputEvent_Direct __d(__buf, 0);
  memcpy(__d.__data(), &value, 24);
  return __buf;
}
} // namespace nprpc_stream


#endif