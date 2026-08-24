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
enum class CursorShape : uint32_t {
  arrow,
  text,
  pointer,
  crosshair,
  resizeLeftRight,
  resizeUpDown
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

struct SystemTheme {
  uint32_t serial;
  std::string name;
};

namespace flat {
struct SystemTheme {
  uint32_t serial;
  ::nprpc::flat::String name;
};

class SystemTheme_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<SystemTheme*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const SystemTheme*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  SystemTheme_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& serial() const noexcept { return base().serial;}
  uint32_t& serial() noexcept { return base().serial;}
  void name(const char* str) { new (&base().name) ::nprpc::flat::String(buffer_, str); }
  void name(const std::string& str) { new (&base().name) ::nprpc::flat::String(buffer_, str); }
  auto name() noexcept { return (::nprpc::flat::Span<char>)base().name; }
  auto name() const noexcept { return (::nprpc::flat::Span<const char>)base().name; }
  auto name_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(SystemTheme, name)); }
};
} // namespace flat

struct ThemeAck {
  uint32_t serial;
};

namespace flat {
struct ThemeAck {
  uint32_t serial;
};

class ThemeAck_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<ThemeAck*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const ThemeAck*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  ThemeAck_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& serial() const noexcept { return base().serial;}
  uint32_t& serial() noexcept { return base().serial;}
};
} // namespace flat

struct Wallpaper {
  std::string mode;
  uint32_t color;
  std::string path;
  std::string fit;
};

namespace flat {
struct Wallpaper {
  ::nprpc::flat::String mode;
  uint32_t color;
  ::nprpc::flat::String path;
  ::nprpc::flat::String fit;
};

class Wallpaper_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<Wallpaper*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const Wallpaper*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  Wallpaper_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void mode(const char* str) { new (&base().mode) ::nprpc::flat::String(buffer_, str); }
  void mode(const std::string& str) { new (&base().mode) ::nprpc::flat::String(buffer_, str); }
  auto mode() noexcept { return (::nprpc::flat::Span<char>)base().mode; }
  auto mode() const noexcept { return (::nprpc::flat::Span<const char>)base().mode; }
  auto mode_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(Wallpaper, mode)); }
  const uint32_t& color() const noexcept { return base().color;}
  uint32_t& color() noexcept { return base().color;}
  void path(const char* str) { new (&base().path) ::nprpc::flat::String(buffer_, str); }
  void path(const std::string& str) { new (&base().path) ::nprpc::flat::String(buffer_, str); }
  auto path() noexcept { return (::nprpc::flat::Span<char>)base().path; }
  auto path() const noexcept { return (::nprpc::flat::Span<const char>)base().path; }
  auto path_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(Wallpaper, path)); }
  void fit(const char* str) { new (&base().fit) ::nprpc::flat::String(buffer_, str); }
  void fit(const std::string& str) { new (&base().fit) ::nprpc::flat::String(buffer_, str); }
  auto fit() noexcept { return (::nprpc::flat::Span<char>)base().fit; }
  auto fit() const noexcept { return (::nprpc::flat::Span<const char>)base().fit; }
  auto fit_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(Wallpaper, fit)); }
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
  bool primary;
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
  ::nprpc::flat::Boolean primary;
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
  const ::nprpc::flat::Boolean& primary() const noexcept { return base().primary;}
  ::nprpc::flat::Boolean& primary() noexcept { return base().primary;}
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

class WallpaperUnreadable : public ::nprpc::Exception {
public:
  std::string path;
  std::string reason;

  WallpaperUnreadable() : ::nprpc::Exception("WallpaperUnreadable") {} 
  WallpaperUnreadable(std::string _path, std::string _reason)
    : ::nprpc::Exception("WallpaperUnreadable")
    , path(_path)
    , reason(_reason)
  {
  }
};

namespace flat {
struct WallpaperUnreadable {
  uint32_t __ex_id;
  ::nprpc::flat::String path;
  ::nprpc::flat::String reason;
};

class WallpaperUnreadable_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<WallpaperUnreadable*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const WallpaperUnreadable*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  WallpaperUnreadable_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
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
  auto path_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(WallpaperUnreadable, path)); }
  void reason(const char* str) { new (&base().reason) ::nprpc::flat::String(buffer_, str); }
  void reason(const std::string& str) { new (&base().reason) ::nprpc::flat::String(buffer_, str); }
  auto reason() noexcept { return (::nprpc::flat::Span<char>)base().reason; }
  auto reason() const noexcept { return (::nprpc::flat::Span<const char>)base().reason; }
  auto reason_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(WallpaperUnreadable, reason)); }
};
} // namespace flat

class AtlasDumpFailed : public ::nprpc::Exception {
public:
  std::string directory;
  std::string reason;

  AtlasDumpFailed() : ::nprpc::Exception("AtlasDumpFailed") {} 
  AtlasDumpFailed(std::string _directory, std::string _reason)
    : ::nprpc::Exception("AtlasDumpFailed")
    , directory(_directory)
    , reason(_reason)
  {
  }
};

namespace flat {
struct AtlasDumpFailed {
  uint32_t __ex_id;
  ::nprpc::flat::String directory;
  ::nprpc::flat::String reason;
};

class AtlasDumpFailed_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<AtlasDumpFailed*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const AtlasDumpFailed*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  AtlasDumpFailed_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& __ex_id() const noexcept { return base().__ex_id;}
  uint32_t& __ex_id() noexcept { return base().__ex_id;}
  void directory(const char* str) { new (&base().directory) ::nprpc::flat::String(buffer_, str); }
  void directory(const std::string& str) { new (&base().directory) ::nprpc::flat::String(buffer_, str); }
  auto directory() noexcept { return (::nprpc::flat::Span<char>)base().directory; }
  auto directory() const noexcept { return (::nprpc::flat::Span<const char>)base().directory; }
  auto directory_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(AtlasDumpFailed, directory)); }
  void reason(const char* str) { new (&base().reason) ::nprpc::flat::String(buffer_, str); }
  void reason(const std::string& str) { new (&base().reason) ::nprpc::flat::String(buffer_, str); }
  auto reason() noexcept { return (::nprpc::flat::Span<char>)base().reason; }
  auto reason() const noexcept { return (::nprpc::flat::Span<const char>)base().reason; }
  auto reason_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(AtlasDumpFailed, reason)); }
};
} // namespace flat

struct ActiveWindow {
  uint32_t surfaceId;
  std::string title;
  std::string menuService;
  std::string menuObjectPath;
  uint32_t pid;
  uint32_t registrarId;
};

namespace flat {
struct ActiveWindow {
  uint32_t surfaceId;
  ::nprpc::flat::String title;
  ::nprpc::flat::String menuService;
  ::nprpc::flat::String menuObjectPath;
  uint32_t pid;
  uint32_t registrarId;
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
  const uint32_t& pid() const noexcept { return base().pid;}
  uint32_t& pid() noexcept { return base().pid;}
  const uint32_t& registrarId() const noexcept { return base().registrarId;}
  uint32_t& registrarId() noexcept { return base().registrarId;}
};
} // namespace flat

struct WindowInfo {
  uint32_t surfaceId;
  std::string title;
  std::string appId;
  uint32_t workspace;
  bool minimized;
  bool focused;
  uint32_t width;
  uint32_t height;
};

namespace flat {
struct WindowInfo {
  uint32_t surfaceId;
  ::nprpc::flat::String title;
  ::nprpc::flat::String appId;
  uint32_t workspace;
  ::nprpc::flat::Boolean minimized;
  ::nprpc::flat::Boolean focused;
  uint32_t width;
  uint32_t height;
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
  const uint32_t& width() const noexcept { return base().width;}
  uint32_t& width() noexcept { return base().width;}
  const uint32_t& height() const noexcept { return base().height;}
  uint32_t& height() noexcept { return base().height;}
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

struct PanelArea {
  uint32_t serial;
  bool covered;
};

namespace flat {
struct PanelArea {
  uint32_t serial;
  ::nprpc::flat::Boolean covered;
};

class PanelArea_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<PanelArea*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const PanelArea*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  PanelArea_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& serial() const noexcept { return base().serial;}
  uint32_t& serial() noexcept { return base().serial;}
  const ::nprpc::flat::Boolean& covered() const noexcept { return base().covered;}
  ::nprpc::flat::Boolean& covered() noexcept { return base().covered;}
};
} // namespace flat

struct PanelAreaAck {
  uint32_t serial;
};

namespace flat {
struct PanelAreaAck {
  uint32_t serial;
};

class PanelAreaAck_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<PanelAreaAck*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const PanelAreaAck*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  PanelAreaAck_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
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

enum class MenuItemKind : uint32_t {
  command,
  checkbox,
  separator
};
struct MenuItem {
  uint32_t id;
  std::string title;
  MenuItemKind kind;
  bool checked;
  bool enabled;
  std::string shortcut;
};

namespace flat {
struct MenuItem {
  uint32_t id;
  ::nprpc::flat::String title;
  MenuItemKind kind;
  ::nprpc::flat::Boolean checked;
  ::nprpc::flat::Boolean enabled;
  ::nprpc::flat::String shortcut;
};

class MenuItem_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<MenuItem*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const MenuItem*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  MenuItem_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& id() const noexcept { return base().id;}
  uint32_t& id() noexcept { return base().id;}
  void title(const char* str) { new (&base().title) ::nprpc::flat::String(buffer_, str); }
  void title(const std::string& str) { new (&base().title) ::nprpc::flat::String(buffer_, str); }
  auto title() noexcept { return (::nprpc::flat::Span<char>)base().title; }
  auto title() const noexcept { return (::nprpc::flat::Span<const char>)base().title; }
  auto title_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(MenuItem, title)); }
  const MenuItemKind& kind() const noexcept { return base().kind;}
  MenuItemKind& kind() noexcept { return base().kind;}
  const ::nprpc::flat::Boolean& checked() const noexcept { return base().checked;}
  ::nprpc::flat::Boolean& checked() noexcept { return base().checked;}
  const ::nprpc::flat::Boolean& enabled() const noexcept { return base().enabled;}
  ::nprpc::flat::Boolean& enabled() noexcept { return base().enabled;}
  void shortcut(const char* str) { new (&base().shortcut) ::nprpc::flat::String(buffer_, str); }
  void shortcut(const std::string& str) { new (&base().shortcut) ::nprpc::flat::String(buffer_, str); }
  auto shortcut() noexcept { return (::nprpc::flat::Span<char>)base().shortcut; }
  auto shortcut() const noexcept { return (::nprpc::flat::Span<const char>)base().shortcut; }
  auto shortcut_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(MenuItem, shortcut)); }
};
} // namespace flat

struct MenuRequest {
  uint32_t serial;
  int32_t x;
  int32_t y;
  uint32_t target;
  std::string title;
  std::vector<MenuItem> items;
};

namespace flat {
struct MenuRequest {
  uint32_t serial;
  int32_t x;
  int32_t y;
  uint32_t target;
  ::nprpc::flat::String title;
  ::nprpc::flat::Vector<flat::MenuItem> items;
};

class MenuRequest_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<MenuRequest*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const MenuRequest*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  MenuRequest_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& serial() const noexcept { return base().serial;}
  uint32_t& serial() noexcept { return base().serial;}
  const int32_t& x() const noexcept { return base().x;}
  int32_t& x() noexcept { return base().x;}
  const int32_t& y() const noexcept { return base().y;}
  int32_t& y() noexcept { return base().y;}
  const uint32_t& target() const noexcept { return base().target;}
  uint32_t& target() noexcept { return base().target;}
  void title(const char* str) { new (&base().title) ::nprpc::flat::String(buffer_, str); }
  void title(const std::string& str) { new (&base().title) ::nprpc::flat::String(buffer_, str); }
  auto title() noexcept { return (::nprpc::flat::Span<char>)base().title; }
  auto title() const noexcept { return (::nprpc::flat::Span<const char>)base().title; }
  auto title_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(MenuRequest, title)); }
  void items(std::uint32_t elements_size) { new (&base().items) ::nprpc::flat::Vector<flat::MenuItem>(buffer_, elements_size); }
  auto items_d() noexcept { return ::nprpc::flat::Vector_Direct2<flat::MenuItem,flat::MenuItem_Direct>(buffer_, offset_ + offsetof(MenuRequest, items)); }
  auto items() noexcept { return ::nprpc::flat::Span_ref<flat::MenuItem, flat::MenuItem_Direct>(buffer_, base().items.range(buffer_.data().data())); }
};
} // namespace flat

struct MenuReply {
  uint32_t serial;
  uint32_t chosen;
};

namespace flat {
struct MenuReply {
  uint32_t serial;
  uint32_t chosen;
};

class MenuReply_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<MenuReply*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const MenuReply*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  MenuReply_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& serial() const noexcept { return base().serial;}
  uint32_t& serial() noexcept { return base().serial;}
  const uint32_t& chosen() const noexcept { return base().chosen;}
  uint32_t& chosen() noexcept { return base().chosen;}
};
} // namespace flat

struct GpuAllocation {
  uint32_t kind;
  std::string category;
  uint32_t windowId;
  std::string detail;
  uint64_t bytes;
  bool isImage;
  uint32_t width;
  uint32_t height;
  uint32_t samples;
  uint32_t mipLevels;
  bool retiring;
  bool foreign;
};

namespace flat {
struct GpuAllocation {
  uint32_t kind;
  ::nprpc::flat::String category;
  uint32_t windowId;
  ::nprpc::flat::String detail;
  uint64_t bytes;
  ::nprpc::flat::Boolean isImage;
  uint32_t width;
  uint32_t height;
  uint32_t samples;
  uint32_t mipLevels;
  ::nprpc::flat::Boolean retiring;
  ::nprpc::flat::Boolean foreign;
};

class GpuAllocation_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<GpuAllocation*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const GpuAllocation*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  GpuAllocation_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& kind() const noexcept { return base().kind;}
  uint32_t& kind() noexcept { return base().kind;}
  void category(const char* str) { new (&base().category) ::nprpc::flat::String(buffer_, str); }
  void category(const std::string& str) { new (&base().category) ::nprpc::flat::String(buffer_, str); }
  auto category() noexcept { return (::nprpc::flat::Span<char>)base().category; }
  auto category() const noexcept { return (::nprpc::flat::Span<const char>)base().category; }
  auto category_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(GpuAllocation, category)); }
  const uint32_t& windowId() const noexcept { return base().windowId;}
  uint32_t& windowId() noexcept { return base().windowId;}
  void detail(const char* str) { new (&base().detail) ::nprpc::flat::String(buffer_, str); }
  void detail(const std::string& str) { new (&base().detail) ::nprpc::flat::String(buffer_, str); }
  auto detail() noexcept { return (::nprpc::flat::Span<char>)base().detail; }
  auto detail() const noexcept { return (::nprpc::flat::Span<const char>)base().detail; }
  auto detail_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(GpuAllocation, detail)); }
  const uint64_t& bytes() const noexcept { return base().bytes;}
  uint64_t& bytes() noexcept { return base().bytes;}
  const ::nprpc::flat::Boolean& isImage() const noexcept { return base().isImage;}
  ::nprpc::flat::Boolean& isImage() noexcept { return base().isImage;}
  const uint32_t& width() const noexcept { return base().width;}
  uint32_t& width() noexcept { return base().width;}
  const uint32_t& height() const noexcept { return base().height;}
  uint32_t& height() noexcept { return base().height;}
  const uint32_t& samples() const noexcept { return base().samples;}
  uint32_t& samples() noexcept { return base().samples;}
  const uint32_t& mipLevels() const noexcept { return base().mipLevels;}
  uint32_t& mipLevels() noexcept { return base().mipLevels;}
  const ::nprpc::flat::Boolean& retiring() const noexcept { return base().retiring;}
  ::nprpc::flat::Boolean& retiring() noexcept { return base().retiring;}
  const ::nprpc::flat::Boolean& foreign() const noexcept { return base().foreign;}
  ::nprpc::flat::Boolean& foreign() noexcept { return base().foreign;}
};
} // namespace flat

struct GpuWindow {
  uint32_t id;
  std::string title;
  uint32_t width;
  uint32_t height;
  uint32_t samples;
  uint64_t bytes;
  bool presenting;
};

namespace flat {
struct GpuWindow {
  uint32_t id;
  ::nprpc::flat::String title;
  uint32_t width;
  uint32_t height;
  uint32_t samples;
  uint64_t bytes;
  ::nprpc::flat::Boolean presenting;
};

class GpuWindow_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<GpuWindow*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const GpuWindow*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  GpuWindow_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& id() const noexcept { return base().id;}
  uint32_t& id() noexcept { return base().id;}
  void title(const char* str) { new (&base().title) ::nprpc::flat::String(buffer_, str); }
  void title(const std::string& str) { new (&base().title) ::nprpc::flat::String(buffer_, str); }
  auto title() noexcept { return (::nprpc::flat::Span<char>)base().title; }
  auto title() const noexcept { return (::nprpc::flat::Span<const char>)base().title; }
  auto title_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(GpuWindow, title)); }
  const uint32_t& width() const noexcept { return base().width;}
  uint32_t& width() noexcept { return base().width;}
  const uint32_t& height() const noexcept { return base().height;}
  uint32_t& height() noexcept { return base().height;}
  const uint32_t& samples() const noexcept { return base().samples;}
  uint32_t& samples() noexcept { return base().samples;}
  const uint64_t& bytes() const noexcept { return base().bytes;}
  uint64_t& bytes() noexcept { return base().bytes;}
  const ::nprpc::flat::Boolean& presenting() const noexcept { return base().presenting;}
  ::nprpc::flat::Boolean& presenting() noexcept { return base().presenting;}
};
} // namespace flat

struct GpuAtlas {
  uint32_t kind;
  uint32_t page;
  uint32_t width;
  uint32_t height;
  uint64_t bytes;
  uint32_t fillPercent;
  uint32_t generation;
  uint32_t glyphs;
  uint32_t faces;
  uint32_t slotsUsed;
  uint32_t slotsTotal;
  uint32_t cellSize;
  std::string pngPath;
};

namespace flat {
struct GpuAtlas {
  uint32_t kind;
  uint32_t page;
  uint32_t width;
  uint32_t height;
  uint64_t bytes;
  uint32_t fillPercent;
  uint32_t generation;
  uint32_t glyphs;
  uint32_t faces;
  uint32_t slotsUsed;
  uint32_t slotsTotal;
  uint32_t cellSize;
  ::nprpc::flat::String pngPath;
};

class GpuAtlas_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<GpuAtlas*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const GpuAtlas*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  GpuAtlas_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& kind() const noexcept { return base().kind;}
  uint32_t& kind() noexcept { return base().kind;}
  const uint32_t& page() const noexcept { return base().page;}
  uint32_t& page() noexcept { return base().page;}
  const uint32_t& width() const noexcept { return base().width;}
  uint32_t& width() noexcept { return base().width;}
  const uint32_t& height() const noexcept { return base().height;}
  uint32_t& height() noexcept { return base().height;}
  const uint64_t& bytes() const noexcept { return base().bytes;}
  uint64_t& bytes() noexcept { return base().bytes;}
  const uint32_t& fillPercent() const noexcept { return base().fillPercent;}
  uint32_t& fillPercent() noexcept { return base().fillPercent;}
  const uint32_t& generation() const noexcept { return base().generation;}
  uint32_t& generation() noexcept { return base().generation;}
  const uint32_t& glyphs() const noexcept { return base().glyphs;}
  uint32_t& glyphs() noexcept { return base().glyphs;}
  const uint32_t& faces() const noexcept { return base().faces;}
  uint32_t& faces() noexcept { return base().faces;}
  const uint32_t& slotsUsed() const noexcept { return base().slotsUsed;}
  uint32_t& slotsUsed() noexcept { return base().slotsUsed;}
  const uint32_t& slotsTotal() const noexcept { return base().slotsTotal;}
  uint32_t& slotsTotal() noexcept { return base().slotsTotal;}
  const uint32_t& cellSize() const noexcept { return base().cellSize;}
  uint32_t& cellSize() noexcept { return base().cellSize;}
  void pngPath(const char* str) { new (&base().pngPath) ::nprpc::flat::String(buffer_, str); }
  void pngPath(const std::string& str) { new (&base().pngPath) ::nprpc::flat::String(buffer_, str); }
  auto pngPath() noexcept { return (::nprpc::flat::Span<char>)base().pngPath; }
  auto pngPath() const noexcept { return (::nprpc::flat::Span<const char>)base().pngPath; }
  auto pngPath_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(GpuAtlas, pngPath)); }
};
} // namespace flat

struct GpuTexture {
  std::string key;
  uint64_t bytes;
  uint32_t width;
  uint32_t height;
  uint32_t refCount;
  uint32_t windowPins;
  bool atlased;
  bool dormant;
};

namespace flat {
struct GpuTexture {
  ::nprpc::flat::String key;
  uint64_t bytes;
  uint32_t width;
  uint32_t height;
  uint32_t refCount;
  uint32_t windowPins;
  ::nprpc::flat::Boolean atlased;
  ::nprpc::flat::Boolean dormant;
};

class GpuTexture_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<GpuTexture*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const GpuTexture*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  GpuTexture_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void key(const char* str) { new (&base().key) ::nprpc::flat::String(buffer_, str); }
  void key(const std::string& str) { new (&base().key) ::nprpc::flat::String(buffer_, str); }
  auto key() noexcept { return (::nprpc::flat::Span<char>)base().key; }
  auto key() const noexcept { return (::nprpc::flat::Span<const char>)base().key; }
  auto key_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(GpuTexture, key)); }
  const uint64_t& bytes() const noexcept { return base().bytes;}
  uint64_t& bytes() noexcept { return base().bytes;}
  const uint32_t& width() const noexcept { return base().width;}
  uint32_t& width() noexcept { return base().width;}
  const uint32_t& height() const noexcept { return base().height;}
  uint32_t& height() noexcept { return base().height;}
  const uint32_t& refCount() const noexcept { return base().refCount;}
  uint32_t& refCount() noexcept { return base().refCount;}
  const uint32_t& windowPins() const noexcept { return base().windowPins;}
  uint32_t& windowPins() noexcept { return base().windowPins;}
  const ::nprpc::flat::Boolean& atlased() const noexcept { return base().atlased;}
  ::nprpc::flat::Boolean& atlased() noexcept { return base().atlased;}
  const ::nprpc::flat::Boolean& dormant() const noexcept { return base().dormant;}
  ::nprpc::flat::Boolean& dormant() noexcept { return base().dormant;}
};
} // namespace flat

struct GpuReport {
  std::string deviceName;
  uint32_t samples;
  uint32_t maxSamples;
  uint64_t heapUsageBytes;
  uint64_t heapBudgetBytes;
  uint64_t heapSizeBytes;
  uint64_t vmaAllocatedBytes;
  uint64_t vmaBlockBytes;
  uint64_t ownBytes;
  uint64_t foreignBytes;
  uint64_t retiringBytes;
  std::vector<GpuWindow> windows;
  std::vector<GpuAllocation> allocations;
  std::vector<GpuAtlas> atlases;
  std::vector<GpuTexture> textures;
  uint32_t textureCount;
  uint64_t textureBytes;
  uint64_t dormantBytes;
  uint64_t dormantBudgetBytes;
  uint64_t cacheHits;
  uint64_t cacheEvictions;
};

namespace flat {
struct GpuReport {
  ::nprpc::flat::String deviceName;
  uint32_t samples;
  uint32_t maxSamples;
  uint64_t heapUsageBytes;
  uint64_t heapBudgetBytes;
  uint64_t heapSizeBytes;
  uint64_t vmaAllocatedBytes;
  uint64_t vmaBlockBytes;
  uint64_t ownBytes;
  uint64_t foreignBytes;
  uint64_t retiringBytes;
  ::nprpc::flat::Vector<flat::GpuWindow> windows;
  ::nprpc::flat::Vector<flat::GpuAllocation> allocations;
  ::nprpc::flat::Vector<flat::GpuAtlas> atlases;
  ::nprpc::flat::Vector<flat::GpuTexture> textures;
  uint32_t textureCount;
  uint64_t textureBytes;
  uint64_t dormantBytes;
  uint64_t dormantBudgetBytes;
  uint64_t cacheHits;
  uint64_t cacheEvictions;
};

class GpuReport_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<GpuReport*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const GpuReport*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  GpuReport_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void deviceName(const char* str) { new (&base().deviceName) ::nprpc::flat::String(buffer_, str); }
  void deviceName(const std::string& str) { new (&base().deviceName) ::nprpc::flat::String(buffer_, str); }
  auto deviceName() noexcept { return (::nprpc::flat::Span<char>)base().deviceName; }
  auto deviceName() const noexcept { return (::nprpc::flat::Span<const char>)base().deviceName; }
  auto deviceName_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(GpuReport, deviceName)); }
  const uint32_t& samples() const noexcept { return base().samples;}
  uint32_t& samples() noexcept { return base().samples;}
  const uint32_t& maxSamples() const noexcept { return base().maxSamples;}
  uint32_t& maxSamples() noexcept { return base().maxSamples;}
  const uint64_t& heapUsageBytes() const noexcept { return base().heapUsageBytes;}
  uint64_t& heapUsageBytes() noexcept { return base().heapUsageBytes;}
  const uint64_t& heapBudgetBytes() const noexcept { return base().heapBudgetBytes;}
  uint64_t& heapBudgetBytes() noexcept { return base().heapBudgetBytes;}
  const uint64_t& heapSizeBytes() const noexcept { return base().heapSizeBytes;}
  uint64_t& heapSizeBytes() noexcept { return base().heapSizeBytes;}
  const uint64_t& vmaAllocatedBytes() const noexcept { return base().vmaAllocatedBytes;}
  uint64_t& vmaAllocatedBytes() noexcept { return base().vmaAllocatedBytes;}
  const uint64_t& vmaBlockBytes() const noexcept { return base().vmaBlockBytes;}
  uint64_t& vmaBlockBytes() noexcept { return base().vmaBlockBytes;}
  const uint64_t& ownBytes() const noexcept { return base().ownBytes;}
  uint64_t& ownBytes() noexcept { return base().ownBytes;}
  const uint64_t& foreignBytes() const noexcept { return base().foreignBytes;}
  uint64_t& foreignBytes() noexcept { return base().foreignBytes;}
  const uint64_t& retiringBytes() const noexcept { return base().retiringBytes;}
  uint64_t& retiringBytes() noexcept { return base().retiringBytes;}
  void windows(std::uint32_t elements_size) { new (&base().windows) ::nprpc::flat::Vector<flat::GpuWindow>(buffer_, elements_size); }
  auto windows_d() noexcept { return ::nprpc::flat::Vector_Direct2<flat::GpuWindow,flat::GpuWindow_Direct>(buffer_, offset_ + offsetof(GpuReport, windows)); }
  auto windows() noexcept { return ::nprpc::flat::Span_ref<flat::GpuWindow, flat::GpuWindow_Direct>(buffer_, base().windows.range(buffer_.data().data())); }
  void allocations(std::uint32_t elements_size) { new (&base().allocations) ::nprpc::flat::Vector<flat::GpuAllocation>(buffer_, elements_size); }
  auto allocations_d() noexcept { return ::nprpc::flat::Vector_Direct2<flat::GpuAllocation,flat::GpuAllocation_Direct>(buffer_, offset_ + offsetof(GpuReport, allocations)); }
  auto allocations() noexcept { return ::nprpc::flat::Span_ref<flat::GpuAllocation, flat::GpuAllocation_Direct>(buffer_, base().allocations.range(buffer_.data().data())); }
  void atlases(std::uint32_t elements_size) { new (&base().atlases) ::nprpc::flat::Vector<flat::GpuAtlas>(buffer_, elements_size); }
  auto atlases_d() noexcept { return ::nprpc::flat::Vector_Direct2<flat::GpuAtlas,flat::GpuAtlas_Direct>(buffer_, offset_ + offsetof(GpuReport, atlases)); }
  auto atlases() noexcept { return ::nprpc::flat::Span_ref<flat::GpuAtlas, flat::GpuAtlas_Direct>(buffer_, base().atlases.range(buffer_.data().data())); }
  void textures(std::uint32_t elements_size) { new (&base().textures) ::nprpc::flat::Vector<flat::GpuTexture>(buffer_, elements_size); }
  auto textures_d() noexcept { return ::nprpc::flat::Vector_Direct2<flat::GpuTexture,flat::GpuTexture_Direct>(buffer_, offset_ + offsetof(GpuReport, textures)); }
  auto textures() noexcept { return ::nprpc::flat::Span_ref<flat::GpuTexture, flat::GpuTexture_Direct>(buffer_, base().textures.range(buffer_.data().data())); }
  const uint32_t& textureCount() const noexcept { return base().textureCount;}
  uint32_t& textureCount() noexcept { return base().textureCount;}
  const uint64_t& textureBytes() const noexcept { return base().textureBytes;}
  uint64_t& textureBytes() noexcept { return base().textureBytes;}
  const uint64_t& dormantBytes() const noexcept { return base().dormantBytes;}
  uint64_t& dormantBytes() noexcept { return base().dormantBytes;}
  const uint64_t& dormantBudgetBytes() const noexcept { return base().dormantBudgetBytes;}
  uint64_t& dormantBudgetBytes() noexcept { return base().dormantBudgetBytes;}
  const uint64_t& cacheHits() const noexcept { return base().cacheHits;}
  uint64_t& cacheHits() noexcept { return base().cacheHits;}
  const uint64_t& cacheEvictions() const noexcept { return base().cacheEvictions;}
  uint64_t& cacheEvictions() noexcept { return base().cacheEvictions;}
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
  virtual uint32_t CreateMenuSurface (::nprpc::flat::Span<char> arenaId, uint32_t width, uint32_t height, ::nprpc::flat::Span<char> appId) = 0;
  virtual void BeginMove (uint32_t surfaceId) = 0;
  virtual void SetMinSize (uint32_t surfaceId, uint32_t minWidth, uint32_t minHeight) = 0;
  virtual bool ToggleMaximize (uint32_t surfaceId) = 0;
  virtual void Minimize (uint32_t surfaceId) = 0;
  virtual void SetPanelThickness (uint32_t surfaceId, uint32_t thickness, uint32_t reserved) = 0;
  virtual ::nprpc::Task<> SubscribeWindows (::nprpc::BidiStream<WindowListAck, WindowList> stream) = 0;
  virtual ::nprpc::Task<> SubscribePanelArea (uint32_t surfaceId, ::nprpc::BidiStream<PanelAreaAck, PanelArea> stream) = 0;
  virtual ::nprpc::Task<> SubscribeSystemTheme (::nprpc::BidiStream<ThemeAck, SystemTheme> stream) = 0;
  virtual void ActivateWindow (uint32_t surfaceId) = 0;
  virtual void SetInputRegion (uint32_t surfaceId, int32_t x, int32_t y, uint32_t w, uint32_t h) = 0;
  virtual void SetCursor (uint32_t surfaceId, CursorShape shape) = 0;
  virtual Appearance GetAppearance () = 0;
  virtual void SetAppearance (flat::Appearance_Direct appearance) = 0;
  virtual SystemTheme GetSystemTheme () = 0;
  virtual void SetSystemTheme (flat::SystemTheme_Direct theme) = 0;
  virtual Wallpaper GetWallpaper () = 0;
  virtual void SetWallpaper (flat::Wallpaper_Direct wallpaper) = 0;
  virtual KeyboardSettings GetKeyboard () = 0;
  virtual void SetKeyboard (flat::KeyboardSettings_Direct settings) = 0;
  virtual std::vector<KeyboardLayout> ListKeyboardLayouts () = 0;
  virtual std::vector<KeyBinding> ListKeyBindings () = 0;
  virtual std::vector<OutputInfo> ListOutputs () = 0;
  virtual std::vector<OutputMode> ListOutputModes (::nprpc::flat::Span<char> name) = 0;
  virtual void SetOutput (flat::OutputRequest_Direct request) = 0;
  virtual void SetPrimaryOutput (::nprpc::flat::Span<char> name) = 0;
  virtual std::string GetArrangement () = 0;
  virtual void SetArrangement (::nprpc::flat::Span<char> mode) = 0;
  virtual ::nprpc::Task<> SubscribeActiveWindow (::nprpc::BidiStream<FocusAck, ActiveWindow> stream) = 0;
  virtual ::nprpc::Task<> SubscribeMenu (uint32_t surfaceId, ::nprpc::BidiStream<MenuReply, MenuRequest> stream) = 0;
  virtual void ShowMenu (uint32_t surfaceId, uint32_t serial, uint32_t width, uint32_t height) = 0;
  virtual void DestroySurface (uint32_t surfaceId) = 0;
  virtual void Present (uint32_t surfaceId, uint32_t serial) = 0;
  virtual void ScrollUnclaimed (uint32_t surfaceId, float dx, float dy) = 0;
  virtual void Heartbeat (uint32_t surfaceId) = 0;
  virtual ::nprpc::Task<> SubscribeInput (uint32_t surfaceId, ::nprpc::BidiStream<InputAck, InputEvent> stream) = 0;
  virtual std::vector<std::string> TakeDroppedPaths (uint32_t surfaceId) = 0;
  virtual Capture CaptureSurface (uint32_t surfaceId, int32_t x, int32_t y, int32_t w, int32_t h, int32_t maxSide) = 0;
  virtual std::string GetClipboard (uint32_t surfaceId) = 0;
  virtual void SetClipboard (uint32_t surfaceId, ::nprpc::flat::Span<char> text) = 0;
  virtual std::string GetPrimarySelection (uint32_t surfaceId) = 0;
  virtual void SetPrimarySelection (uint32_t surfaceId, ::nprpc::flat::Span<char> text) = 0;
  virtual std::vector<uint8_t> GetClipboardPng (uint32_t surfaceId) = 0;
  virtual void SetBackdropBlur (uint32_t surfaceId, float radius) = 0;
  virtual GpuReport GetGpuReport () = 0;
  virtual std::vector<std::string> DumpAtlasImages (::nprpc::flat::Span<char> directory) = 0;
  virtual void SetBackdropBlurRegion (uint32_t surfaceId, float radius, float x, float y, float w, float h, float cornerRadius) = 0;
  virtual void EndSession () = 0;
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
  uint32_t CreateMenuSurface (const std::string& arenaId, uint32_t width, uint32_t height, const std::string& appId);
  ::nprpc::Task<uint32_t> CreateMenuSurfaceAsync (const std::string& arenaId, uint32_t width, uint32_t height, const std::string& appId, std::stop_token st = {});
  void BeginMove (uint32_t surfaceId);
  ::nprpc::Task<void> BeginMoveAsync (uint32_t surfaceId, std::stop_token st = {});
  void SetMinSize (uint32_t surfaceId, uint32_t minWidth, uint32_t minHeight);
  ::nprpc::Task<void> SetMinSizeAsync (uint32_t surfaceId, uint32_t minWidth, uint32_t minHeight, std::stop_token st = {});
  bool ToggleMaximize (uint32_t surfaceId);
  ::nprpc::Task<bool> ToggleMaximizeAsync (uint32_t surfaceId, std::stop_token st = {});
  void Minimize (uint32_t surfaceId);
  ::nprpc::Task<void> MinimizeAsync (uint32_t surfaceId, std::stop_token st = {});
  void SetPanelThickness (uint32_t surfaceId, uint32_t thickness, uint32_t reserved);
  ::nprpc::Task<void> SetPanelThicknessAsync (uint32_t surfaceId, uint32_t thickness, uint32_t reserved, std::stop_token st = {});
  std::pair<::nprpc::StreamWriter<WindowListAck>, ::nprpc::StreamReader<WindowList>> SubscribeWindows ();
  std::pair<::nprpc::StreamWriter<PanelAreaAck>, ::nprpc::StreamReader<PanelArea>> SubscribePanelArea (uint32_t surfaceId);
  std::pair<::nprpc::StreamWriter<ThemeAck>, ::nprpc::StreamReader<SystemTheme>> SubscribeSystemTheme ();
  void ActivateWindow (uint32_t surfaceId);
  ::nprpc::Task<void> ActivateWindowAsync (uint32_t surfaceId, std::stop_token st = {});
  void SetInputRegion (uint32_t surfaceId, int32_t x, int32_t y, uint32_t w, uint32_t h);
  ::nprpc::Task<void> SetInputRegionAsync (uint32_t surfaceId, int32_t x, int32_t y, uint32_t w, uint32_t h, std::stop_token st = {});
  void SetCursor (uint32_t surfaceId, const CursorShape& shape);
  Appearance GetAppearance ();
  ::nprpc::Task<Appearance> GetAppearanceAsync (std::stop_token st = {});
  void SetAppearance (const Appearance& appearance);
  ::nprpc::Task<void> SetAppearanceAsync (const Appearance& appearance, std::stop_token st = {});
  SystemTheme GetSystemTheme ();
  ::nprpc::Task<SystemTheme> GetSystemThemeAsync (std::stop_token st = {});
  void SetSystemTheme (const SystemTheme& theme);
  ::nprpc::Task<void> SetSystemThemeAsync (const SystemTheme& theme, std::stop_token st = {});
  Wallpaper GetWallpaper ();
  ::nprpc::Task<Wallpaper> GetWallpaperAsync (std::stop_token st = {});
  void SetWallpaper (const Wallpaper& wallpaper);
  ::nprpc::Task<void> SetWallpaperAsync (const Wallpaper& wallpaper, std::stop_token st = {});
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
  void SetPrimaryOutput (const std::string& name);
  ::nprpc::Task<void> SetPrimaryOutputAsync (const std::string& name, std::stop_token st = {});
  std::string GetArrangement ();
  ::nprpc::Task<std::string> GetArrangementAsync (std::stop_token st = {});
  void SetArrangement (const std::string& mode);
  ::nprpc::Task<void> SetArrangementAsync (const std::string& mode, std::stop_token st = {});
  std::pair<::nprpc::StreamWriter<FocusAck>, ::nprpc::StreamReader<ActiveWindow>> SubscribeActiveWindow ();
  std::pair<::nprpc::StreamWriter<MenuReply>, ::nprpc::StreamReader<MenuRequest>> SubscribeMenu (uint32_t surfaceId);
  void ShowMenu (uint32_t surfaceId, uint32_t serial, uint32_t width, uint32_t height);
  ::nprpc::Task<void> ShowMenuAsync (uint32_t surfaceId, uint32_t serial, uint32_t width, uint32_t height, std::stop_token st = {});
  void DestroySurface (uint32_t surfaceId);
  ::nprpc::Task<void> DestroySurfaceAsync (uint32_t surfaceId, std::stop_token st = {});
  void Present (uint32_t surfaceId, uint32_t serial);
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
  std::vector<uint8_t> GetClipboardPng (uint32_t surfaceId);
  ::nprpc::Task<std::vector<uint8_t>> GetClipboardPngAsync (uint32_t surfaceId, std::stop_token st = {});
  void SetBackdropBlur (uint32_t surfaceId, float radius);
  ::nprpc::Task<void> SetBackdropBlurAsync (uint32_t surfaceId, float radius, std::stop_token st = {});
  GpuReport GetGpuReport ();
  ::nprpc::Task<GpuReport> GetGpuReportAsync (std::stop_token st = {});
  std::vector<std::string> DumpAtlasImages (const std::string& directory);
  ::nprpc::Task<std::vector<std::string>> DumpAtlasImagesAsync (const std::string& directory, std::stop_token st = {});
  void SetBackdropBlurRegion (uint32_t surfaceId, float radius, float x, float y, float w, float h, float cornerRadius);
  ::nprpc::Task<void> SetBackdropBlurRegionAsync (uint32_t surfaceId, float radius, float x, float y, float w, float h, float cornerRadius, std::stop_token st = {});
  void EndSession ();
  ::nprpc::Task<void> EndSessionAsync (std::stop_token st = {});
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
      (*it2).width = e.width();
      (*it2).height = e.height();
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
        e.width() = __ptr->width;
        e.height() = __ptr->height;
      ++it;
    }
  }
  return __buf;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::lava::PanelArea deserialize<::lava::PanelArea>(::nprpc::flat_buffer& buf) {
  ::nprpc::impl::flat::StreamChunk_Direct __chunk(buf, sizeof(::nprpc::impl::Header));
  auto __span = __chunk.data();
  ::nprpc::flat_buffer __elem_buf;
  auto __mb = __elem_buf.prepare(__span.size());
  std::memcpy(__mb.data(), __span.data(), __span.size());
  __elem_buf.commit(__span.size());
  ::lava::PanelArea __result;
  ::lava::flat::PanelArea_Direct __d(__elem_buf, 0);
  memcpy(&__result, __d.__data(), 8);
  return __result;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::lava::PanelAreaAck deserialize<::lava::PanelAreaAck>(::nprpc::flat_buffer& buf) {
  ::nprpc::impl::flat::StreamChunk_Direct __chunk(buf, sizeof(::nprpc::impl::Header));
  auto __span = __chunk.data();
  ::nprpc::flat_buffer __elem_buf;
  auto __mb = __elem_buf.prepare(__span.size());
  std::memcpy(__mb.data(), __span.data(), __span.size());
  __elem_buf.commit(__span.size());
  ::lava::PanelAreaAck __result;
  ::lava::flat::PanelAreaAck_Direct __d(__elem_buf, 0);
  memcpy(&__result, __d.__data(), 4);
  return __result;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::nprpc::flat_buffer serialize<::lava::PanelAreaAck>(const ::lava::PanelAreaAck& value) {
  ::nprpc::flat_buffer __buf;
  __buf.prepare(4);
  __buf.commit(4);
  ::lava::flat::PanelAreaAck_Direct __d(__buf, 0);
  memcpy(__d.__data(), &value, 4);
  return __buf;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::nprpc::flat_buffer serialize<::lava::PanelArea>(const ::lava::PanelArea& value) {
  ::nprpc::flat_buffer __buf;
  __buf.prepare(8);
  __buf.commit(8);
  ::lava::flat::PanelArea_Direct __d(__buf, 0);
  memcpy(__d.__data(), &value, 8);
  return __buf;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::lava::SystemTheme deserialize<::lava::SystemTheme>(::nprpc::flat_buffer& buf) {
  ::nprpc::impl::flat::StreamChunk_Direct __chunk(buf, sizeof(::nprpc::impl::Header));
  auto __span = __chunk.data();
  ::nprpc::flat_buffer __elem_buf;
  auto __mb = __elem_buf.prepare(__span.size());
  std::memcpy(__mb.data(), __span.data(), __span.size());
  __elem_buf.commit(__span.size());
  ::lava::SystemTheme __result;
  ::lava::flat::SystemTheme_Direct __d(__elem_buf, 0);
  __result.serial = __d.serial();
  __result.name = (std::string_view)__d.name();
  return __result;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::lava::ThemeAck deserialize<::lava::ThemeAck>(::nprpc::flat_buffer& buf) {
  ::nprpc::impl::flat::StreamChunk_Direct __chunk(buf, sizeof(::nprpc::impl::Header));
  auto __span = __chunk.data();
  ::nprpc::flat_buffer __elem_buf;
  auto __mb = __elem_buf.prepare(__span.size());
  std::memcpy(__mb.data(), __span.data(), __span.size());
  __elem_buf.commit(__span.size());
  ::lava::ThemeAck __result;
  ::lava::flat::ThemeAck_Direct __d(__elem_buf, 0);
  memcpy(&__result, __d.__data(), 4);
  return __result;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::nprpc::flat_buffer serialize<::lava::ThemeAck>(const ::lava::ThemeAck& value) {
  ::nprpc::flat_buffer __buf;
  __buf.prepare(4);
  __buf.commit(4);
  ::lava::flat::ThemeAck_Direct __d(__buf, 0);
  memcpy(__d.__data(), &value, 4);
  return __buf;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::nprpc::flat_buffer serialize<::lava::SystemTheme>(const ::lava::SystemTheme& value) {
  ::nprpc::flat_buffer __buf;
  __buf.prepare(12 + 128);
  __buf.commit(12);
  ::lava::flat::SystemTheme_Direct __d(__buf, 0);
  __d.serial() = value.serial;
  __d.name(value.name);
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
  __result.pid = __d.pid();
  __result.registrarId = __d.registrarId();
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
  __buf.prepare(36 + 128);
  __buf.commit(36);
  ::lava::flat::ActiveWindow_Direct __d(__buf, 0);
  __d.surfaceId() = value.surfaceId;
  __d.title(value.title);
  __d.menuService(value.menuService);
  __d.menuObjectPath(value.menuObjectPath);
  __d.pid() = value.pid;
  __d.registrarId() = value.registrarId;
  return __buf;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::lava::MenuRequest deserialize<::lava::MenuRequest>(::nprpc::flat_buffer& buf) {
  ::nprpc::impl::flat::StreamChunk_Direct __chunk(buf, sizeof(::nprpc::impl::Header));
  auto __span = __chunk.data();
  ::nprpc::flat_buffer __elem_buf;
  auto __mb = __elem_buf.prepare(__span.size());
  std::memcpy(__mb.data(), __span.data(), __span.size());
  __elem_buf.commit(__span.size());
  ::lava::MenuRequest __result;
  ::lava::flat::MenuRequest_Direct __d(__elem_buf, 0);
  __result.serial = __d.serial();
  __result.x = __d.x();
  __result.y = __d.y();
  __result.target = __d.target();
  __result.title = (std::string_view)__d.title();
  {
    auto span = __d.items();
    __result.items.resize(span.size());
    auto it2 = std::begin(__result.items);
    for (auto e : span) {
      (*it2).id = e.id();
      (*it2).title = (std::string_view)e.title();
      (*it2).kind = e.kind();
      (*it2).checked = (bool)e.checked();
      (*it2).enabled = (bool)e.enabled();
      (*it2).shortcut = (std::string_view)e.shortcut();
      ++it2;
    }
  }
  return __result;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::lava::MenuReply deserialize<::lava::MenuReply>(::nprpc::flat_buffer& buf) {
  ::nprpc::impl::flat::StreamChunk_Direct __chunk(buf, sizeof(::nprpc::impl::Header));
  auto __span = __chunk.data();
  ::nprpc::flat_buffer __elem_buf;
  auto __mb = __elem_buf.prepare(__span.size());
  std::memcpy(__mb.data(), __span.data(), __span.size());
  __elem_buf.commit(__span.size());
  ::lava::MenuReply __result;
  ::lava::flat::MenuReply_Direct __d(__elem_buf, 0);
  memcpy(&__result, __d.__data(), 8);
  return __result;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::nprpc::flat_buffer serialize<::lava::MenuReply>(const ::lava::MenuReply& value) {
  ::nprpc::flat_buffer __buf;
  __buf.prepare(8);
  __buf.commit(8);
  ::lava::flat::MenuReply_Direct __d(__buf, 0);
  memcpy(__d.__data(), &value, 8);
  return __buf;
}
} // namespace nprpc_stream

namespace nprpc_stream {
template<>
inline ::nprpc::flat_buffer serialize<::lava::MenuRequest>(const ::lava::MenuRequest& value) {
  ::nprpc::flat_buffer __buf;
  __buf.prepare(32 + 128);
  __buf.commit(32);
  ::lava::flat::MenuRequest_Direct __d(__buf, 0);
  __d.serial() = value.serial;
  __d.x() = value.x;
  __d.y() = value.y;
  __d.target() = value.target;
  __d.title(value.title);
  __d.items(static_cast<uint32_t>(value.items.size()));
  {
    auto span = __d.items();
    auto it = value.items.begin();
    for (auto e : span) {
      auto __ptr = ::nprpc::make_wrapper1(*it);
        e.id() = __ptr->id;
        e.title(__ptr->title);
        e.kind() = __ptr->kind;
        e.checked() = __ptr->checked;
        e.enabled() = __ptr->enabled;
        e.shortcut(__ptr->shortcut);
      ++it;
    }
  }
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