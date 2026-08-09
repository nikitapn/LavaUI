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

struct ActiveWindow {
  uint32_t surfaceId;
  std::string title;
};

namespace flat {
struct ActiveWindow {
  uint32_t surfaceId;
  ::nprpc::flat::String title;
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
  virtual uint32_t CreateSurface (::nprpc::flat::Span<char> arenaId, uint32_t width, uint32_t height, ::nprpc::flat::Span<char> title, WindowFrame frame) = 0;
  virtual uint32_t CreatePanel (::nprpc::flat::Span<char> arenaId, PanelEdge edge, uint32_t thickness, ::nprpc::flat::Boolean reserve, ::nprpc::flat::Span<char> title) = 0;
  virtual void BeginMove (uint32_t surfaceId) = 0;
  virtual bool ToggleMaximize (uint32_t surfaceId) = 0;
  virtual void Minimize (uint32_t surfaceId) = 0;
  virtual void SetPanelThickness (uint32_t surfaceId, uint32_t thickness, uint32_t reserved) = 0;
  virtual Appearance GetAppearance () = 0;
  virtual ::nprpc::Task<> SubscribeActiveWindow (::nprpc::BidiStream<FocusAck, ActiveWindow> stream) = 0;
  virtual void DestroySurface (uint32_t surfaceId) = 0;
  virtual void Present (uint32_t surfaceId) = 0;
  virtual void ScrollUnclaimed (uint32_t surfaceId, float dx, float dy) = 0;
  virtual ::nprpc::Task<> SubscribeInput (uint32_t surfaceId, ::nprpc::BidiStream<InputAck, InputEvent> stream) = 0;
  virtual std::vector<std::string> TakeDroppedPaths (uint32_t surfaceId) = 0;
  virtual Capture CaptureSurface (uint32_t surfaceId, int32_t x, int32_t y, int32_t w, int32_t h, int32_t maxSide) = 0;
  virtual std::string GetClipboard (uint32_t surfaceId) = 0;
  virtual void SetClipboard (uint32_t surfaceId, ::nprpc::flat::Span<char> text) = 0;
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
  uint32_t CreateSurface (const std::string& arenaId, uint32_t width, uint32_t height, const std::string& title, const WindowFrame& frame);
  ::nprpc::Task<uint32_t> CreateSurfaceAsync (const std::string& arenaId, uint32_t width, uint32_t height, const std::string& title, const WindowFrame& frame, std::stop_token st = {});
  uint32_t CreatePanel (const std::string& arenaId, const PanelEdge& edge, uint32_t thickness, bool reserve, const std::string& title);
  ::nprpc::Task<uint32_t> CreatePanelAsync (const std::string& arenaId, const PanelEdge& edge, uint32_t thickness, bool reserve, const std::string& title, std::stop_token st = {});
  void BeginMove (uint32_t surfaceId);
  ::nprpc::Task<void> BeginMoveAsync (uint32_t surfaceId, std::stop_token st = {});
  bool ToggleMaximize (uint32_t surfaceId);
  ::nprpc::Task<bool> ToggleMaximizeAsync (uint32_t surfaceId, std::stop_token st = {});
  void Minimize (uint32_t surfaceId);
  ::nprpc::Task<void> MinimizeAsync (uint32_t surfaceId, std::stop_token st = {});
  void SetPanelThickness (uint32_t surfaceId, uint32_t thickness, uint32_t reserved);
  ::nprpc::Task<void> SetPanelThicknessAsync (uint32_t surfaceId, uint32_t thickness, uint32_t reserved, std::stop_token st = {});
  Appearance GetAppearance ();
  ::nprpc::Task<Appearance> GetAppearanceAsync (std::stop_token st = {});
  std::pair<::nprpc::StreamWriter<FocusAck>, ::nprpc::StreamReader<ActiveWindow>> SubscribeActiveWindow ();
  void DestroySurface (uint32_t surfaceId);
  ::nprpc::Task<void> DestroySurfaceAsync (uint32_t surfaceId, std::stop_token st = {});
  void Present (uint32_t surfaceId);
  void ScrollUnclaimed (uint32_t surfaceId, float dx, float dy);
  std::pair<::nprpc::StreamWriter<InputAck>, ::nprpc::StreamReader<InputEvent>> SubscribeInput (uint32_t surfaceId);
  std::vector<std::string> TakeDroppedPaths (uint32_t surfaceId);
  ::nprpc::Task<std::vector<std::string>> TakeDroppedPathsAsync (uint32_t surfaceId, std::stop_token st = {});
  Capture CaptureSurface (uint32_t surfaceId, int32_t x, int32_t y, int32_t w, int32_t h, int32_t maxSide);
  ::nprpc::Task<Capture> CaptureSurfaceAsync (uint32_t surfaceId, int32_t x, int32_t y, int32_t w, int32_t h, int32_t maxSide, std::stop_token st = {});
  std::string GetClipboard (uint32_t surfaceId);
  ::nprpc::Task<std::string> GetClipboardAsync (uint32_t surfaceId, std::stop_token st = {});
  void SetClipboard (uint32_t surfaceId, const std::string& text);
  ::nprpc::Task<void> SetClipboardAsync (uint32_t surfaceId, const std::string& text, std::stop_token st = {});
};

namespace helper {
}
} // module lava
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
  __buf.prepare(12 + 128);
  __buf.commit(12);
  ::lava::flat::ActiveWindow_Direct __d(__buf, 0);
  __d.surfaceId() = value.surfaceId;
  __d.title(value.title);
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