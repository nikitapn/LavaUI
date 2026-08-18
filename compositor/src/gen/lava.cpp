#include "lava.hpp"
#include <nprpc/impl/nprpc_impl.hpp>

void lava_throw_exception(::nprpc::flat_buffer& buf);

namespace lava {

namespace {
struct lava_M1 {
  ::nprpc::flat::String _1;
  uint32_t _2;
  uint32_t _3;
  uint32_t _4;
};

class lava_M1_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M1*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M1*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M1_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void _1(const char* str) { new (&base()._1) ::nprpc::flat::String(buffer_, str); }
  void _1(const std::string& str) { new (&base()._1) ::nprpc::flat::String(buffer_, str); }
  auto _1() noexcept { return (::nprpc::flat::Span<char>)base()._1; }
  auto _1() const noexcept { return (::nprpc::flat::Span<const char>)base()._1; }
  auto _1_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(lava_M1, _1)); }
  const uint32_t& _2() const noexcept { return base()._2;}
  uint32_t& _2() noexcept { return base()._2;}
  const uint32_t& _3() const noexcept { return base()._3;}
  uint32_t& _3() noexcept { return base()._3;}
  const uint32_t& _4() const noexcept { return base()._4;}
  uint32_t& _4() noexcept { return base()._4;}
};

struct lava_M2 {
  uint32_t _1;
};

class lava_M2_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M2*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M2*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M2_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& _1() const noexcept { return base()._1;}
  uint32_t& _1() noexcept { return base()._1;}
};

struct lava_M3 {
  ::nprpc::flat::String _1;
  uint32_t _2;
};

class lava_M3_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M3*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M3*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M3_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void _1(const char* str) { new (&base()._1) ::nprpc::flat::String(buffer_, str); }
  void _1(const std::string& str) { new (&base()._1) ::nprpc::flat::String(buffer_, str); }
  auto _1() noexcept { return (::nprpc::flat::Span<char>)base()._1; }
  auto _1() const noexcept { return (::nprpc::flat::Span<const char>)base()._1; }
  auto _1_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(lava_M3, _1)); }
  const uint32_t& _2() const noexcept { return base()._2;}
  uint32_t& _2() noexcept { return base()._2;}
};

struct lava_M4 {
  ::lava::flat::ImageInfo _1;
};

class lava_M4_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M4*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M4*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M4_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  auto _1() noexcept { return ::lava::flat::ImageInfo_Direct(buffer_, offset_ + offsetof(lava_M4, _1)); }
};

struct lava_M5 {
  ::nprpc::flat::Vector<uint8_t> _1;
  uint32_t _2;
};

class lava_M5_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M5*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M5*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M5_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void _1(std::uint32_t elements_size) { new (&base()._1) ::nprpc::flat::Vector<uint8_t>(buffer_, elements_size); }
  auto _1_d() noexcept { return ::nprpc::flat::Vector_Direct1<uint8_t>(buffer_, offset_ + offsetof(lava_M5, _1)); }
  auto _1() noexcept { return (::nprpc::flat::Span<uint8_t>)base()._1; }
  const auto _1() const noexcept { return (::nprpc::flat::Span<const uint8_t>)base()._1; }
  const uint32_t& _2() const noexcept { return base()._2;}
  uint32_t& _2() noexcept { return base()._2;}
};

struct lava_M6 {
  ::nprpc::flat::String _1;
  uint32_t _2;
  uint32_t _3;
  ::nprpc::flat::String _4;
  ::lava::WindowFrame _5;
  ::nprpc::flat::String _6;
};

class lava_M6_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M6*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M6*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M6_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void _1(const char* str) { new (&base()._1) ::nprpc::flat::String(buffer_, str); }
  void _1(const std::string& str) { new (&base()._1) ::nprpc::flat::String(buffer_, str); }
  auto _1() noexcept { return (::nprpc::flat::Span<char>)base()._1; }
  auto _1() const noexcept { return (::nprpc::flat::Span<const char>)base()._1; }
  auto _1_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(lava_M6, _1)); }
  const uint32_t& _2() const noexcept { return base()._2;}
  uint32_t& _2() noexcept { return base()._2;}
  const uint32_t& _3() const noexcept { return base()._3;}
  uint32_t& _3() noexcept { return base()._3;}
  void _4(const char* str) { new (&base()._4) ::nprpc::flat::String(buffer_, str); }
  void _4(const std::string& str) { new (&base()._4) ::nprpc::flat::String(buffer_, str); }
  auto _4() noexcept { return (::nprpc::flat::Span<char>)base()._4; }
  auto _4() const noexcept { return (::nprpc::flat::Span<const char>)base()._4; }
  auto _4_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(lava_M6, _4)); }
  const ::lava::WindowFrame& _5() const noexcept { return base()._5;}
  ::lava::WindowFrame& _5() noexcept { return base()._5;}
  void _6(const char* str) { new (&base()._6) ::nprpc::flat::String(buffer_, str); }
  void _6(const std::string& str) { new (&base()._6) ::nprpc::flat::String(buffer_, str); }
  auto _6() noexcept { return (::nprpc::flat::Span<char>)base()._6; }
  auto _6() const noexcept { return (::nprpc::flat::Span<const char>)base()._6; }
  auto _6_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(lava_M6, _6)); }
};

struct lava_M7 {
  ::nprpc::flat::String _1;
  ::lava::PanelEdge _2;
  uint32_t _3;
  ::nprpc::flat::Boolean _4;
  ::nprpc::flat::String _5;
  ::nprpc::flat::String _6;
};

class lava_M7_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M7*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M7*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M7_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void _1(const char* str) { new (&base()._1) ::nprpc::flat::String(buffer_, str); }
  void _1(const std::string& str) { new (&base()._1) ::nprpc::flat::String(buffer_, str); }
  auto _1() noexcept { return (::nprpc::flat::Span<char>)base()._1; }
  auto _1() const noexcept { return (::nprpc::flat::Span<const char>)base()._1; }
  auto _1_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(lava_M7, _1)); }
  const ::lava::PanelEdge& _2() const noexcept { return base()._2;}
  ::lava::PanelEdge& _2() noexcept { return base()._2;}
  const uint32_t& _3() const noexcept { return base()._3;}
  uint32_t& _3() noexcept { return base()._3;}
  const ::nprpc::flat::Boolean& _4() const noexcept { return base()._4;}
  ::nprpc::flat::Boolean& _4() noexcept { return base()._4;}
  void _5(const char* str) { new (&base()._5) ::nprpc::flat::String(buffer_, str); }
  void _5(const std::string& str) { new (&base()._5) ::nprpc::flat::String(buffer_, str); }
  auto _5() noexcept { return (::nprpc::flat::Span<char>)base()._5; }
  auto _5() const noexcept { return (::nprpc::flat::Span<const char>)base()._5; }
  auto _5_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(lava_M7, _5)); }
  void _6(const char* str) { new (&base()._6) ::nprpc::flat::String(buffer_, str); }
  void _6(const std::string& str) { new (&base()._6) ::nprpc::flat::String(buffer_, str); }
  auto _6() noexcept { return (::nprpc::flat::Span<char>)base()._6; }
  auto _6() const noexcept { return (::nprpc::flat::Span<const char>)base()._6; }
  auto _6_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(lava_M7, _6)); }
};

struct lava_M8 {
  uint32_t _1;
  uint32_t _2;
  uint32_t _3;
};

class lava_M8_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M8*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M8*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M8_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& _1() const noexcept { return base()._1;}
  uint32_t& _1() noexcept { return base()._1;}
  const uint32_t& _2() const noexcept { return base()._2;}
  uint32_t& _2() noexcept { return base()._2;}
  const uint32_t& _3() const noexcept { return base()._3;}
  uint32_t& _3() noexcept { return base()._3;}
};

struct lava_M9 {
  ::nprpc::flat::Boolean _1;
};

class lava_M9_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M9*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M9*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M9_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const ::nprpc::flat::Boolean& _1() const noexcept { return base()._1;}
  ::nprpc::flat::Boolean& _1() noexcept { return base()._1;}
};

struct lava_M10 {
  uint32_t _1;
  int32_t _2;
  int32_t _3;
  uint32_t _4;
  uint32_t _5;
};

class lava_M10_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M10*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M10*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M10_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& _1() const noexcept { return base()._1;}
  uint32_t& _1() noexcept { return base()._1;}
  const int32_t& _2() const noexcept { return base()._2;}
  int32_t& _2() noexcept { return base()._2;}
  const int32_t& _3() const noexcept { return base()._3;}
  int32_t& _3() noexcept { return base()._3;}
  const uint32_t& _4() const noexcept { return base()._4;}
  uint32_t& _4() noexcept { return base()._4;}
  const uint32_t& _5() const noexcept { return base()._5;}
  uint32_t& _5() noexcept { return base()._5;}
};

struct lava_M11 {
  uint32_t _1;
  ::lava::CursorShape _2;
};

class lava_M11_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M11*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M11*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M11_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& _1() const noexcept { return base()._1;}
  uint32_t& _1() noexcept { return base()._1;}
  const ::lava::CursorShape& _2() const noexcept { return base()._2;}
  ::lava::CursorShape& _2() noexcept { return base()._2;}
};

struct lava_M12 {
  ::lava::flat::Appearance _1;
};

class lava_M12_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M12*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M12*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M12_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  auto _1() noexcept { return ::lava::flat::Appearance_Direct(buffer_, offset_ + offsetof(lava_M12, _1)); }
};

struct lava_M13 {
  ::lava::flat::SystemTheme _1;
};

class lava_M13_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M13*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M13*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M13_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  auto _1() noexcept { return ::lava::flat::SystemTheme_Direct(buffer_, offset_ + offsetof(lava_M13, _1)); }
};

struct lava_M14 {
  ::lava::flat::Wallpaper _1;
};

class lava_M14_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M14*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M14*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M14_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  auto _1() noexcept { return ::lava::flat::Wallpaper_Direct(buffer_, offset_ + offsetof(lava_M14, _1)); }
};

struct lava_M15 {
  ::lava::flat::KeyboardSettings _1;
};

class lava_M15_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M15*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M15*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M15_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  auto _1() noexcept { return ::lava::flat::KeyboardSettings_Direct(buffer_, offset_ + offsetof(lava_M15, _1)); }
};

struct lava_M16 {
  ::nprpc::flat::Vector<::lava::flat::KeyboardLayout> _1;
};

class lava_M16_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M16*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M16*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M16_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void _1(std::uint32_t elements_size) { new (&base()._1) ::nprpc::flat::Vector<::lava::flat::KeyboardLayout>(buffer_, elements_size); }
  auto _1_d() noexcept { return ::nprpc::flat::Vector_Direct2<::lava::flat::KeyboardLayout,::lava::flat::KeyboardLayout_Direct>(buffer_, offset_ + offsetof(lava_M16, _1)); }
  auto _1() noexcept { return ::nprpc::flat::Span_ref<::lava::flat::KeyboardLayout, ::lava::flat::KeyboardLayout_Direct>(buffer_, base()._1.range(buffer_.data().data())); }
};

struct lava_M17 {
  ::nprpc::flat::Vector<::lava::flat::KeyBinding> _1;
};

class lava_M17_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M17*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M17*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M17_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void _1(std::uint32_t elements_size) { new (&base()._1) ::nprpc::flat::Vector<::lava::flat::KeyBinding>(buffer_, elements_size); }
  auto _1_d() noexcept { return ::nprpc::flat::Vector_Direct2<::lava::flat::KeyBinding,::lava::flat::KeyBinding_Direct>(buffer_, offset_ + offsetof(lava_M17, _1)); }
  auto _1() noexcept { return ::nprpc::flat::Span_ref<::lava::flat::KeyBinding, ::lava::flat::KeyBinding_Direct>(buffer_, base()._1.range(buffer_.data().data())); }
};

struct lava_M18 {
  ::nprpc::flat::Vector<::lava::flat::OutputInfo> _1;
};

class lava_M18_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M18*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M18*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M18_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void _1(std::uint32_t elements_size) { new (&base()._1) ::nprpc::flat::Vector<::lava::flat::OutputInfo>(buffer_, elements_size); }
  auto _1_d() noexcept { return ::nprpc::flat::Vector_Direct2<::lava::flat::OutputInfo,::lava::flat::OutputInfo_Direct>(buffer_, offset_ + offsetof(lava_M18, _1)); }
  auto _1() noexcept { return ::nprpc::flat::Span_ref<::lava::flat::OutputInfo, ::lava::flat::OutputInfo_Direct>(buffer_, base()._1.range(buffer_.data().data())); }
};

struct lava_M19 {
  ::nprpc::flat::String _1;
};

class lava_M19_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M19*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M19*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M19_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void _1(const char* str) { new (&base()._1) ::nprpc::flat::String(buffer_, str); }
  void _1(const std::string& str) { new (&base()._1) ::nprpc::flat::String(buffer_, str); }
  auto _1() noexcept { return (::nprpc::flat::Span<char>)base()._1; }
  auto _1() const noexcept { return (::nprpc::flat::Span<const char>)base()._1; }
  auto _1_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(lava_M19, _1)); }
};

struct lava_M20 {
  ::nprpc::flat::Vector<::lava::flat::OutputMode> _1;
};

class lava_M20_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M20*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M20*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M20_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void _1(std::uint32_t elements_size) { new (&base()._1) ::nprpc::flat::Vector<::lava::flat::OutputMode>(buffer_, elements_size); }
  auto _1_d() noexcept { return ::nprpc::flat::Vector_Direct2<::lava::flat::OutputMode,::lava::flat::OutputMode_Direct>(buffer_, offset_ + offsetof(lava_M20, _1)); }
  auto _1() noexcept { return ::nprpc::flat::Span_ref<::lava::flat::OutputMode, ::lava::flat::OutputMode_Direct>(buffer_, base()._1.range(buffer_.data().data())); }
};

struct lava_M21 {
  ::lava::flat::OutputRequest _1;
};

class lava_M21_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M21*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M21*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M21_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  auto _1() noexcept { return ::lava::flat::OutputRequest_Direct(buffer_, offset_ + offsetof(lava_M21, _1)); }
};

struct lava_M22 {
  uint32_t _1;
  float _2;
  float _3;
};

class lava_M22_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M22*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M22*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M22_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& _1() const noexcept { return base()._1;}
  uint32_t& _1() noexcept { return base()._1;}
  const float& _2() const noexcept { return base()._2;}
  float& _2() noexcept { return base()._2;}
  const float& _3() const noexcept { return base()._3;}
  float& _3() noexcept { return base()._3;}
};

struct lava_M23 {
  ::nprpc::flat::Vector<::nprpc::flat::String> _1;
};

class lava_M23_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M23*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M23*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M23_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void _1(std::uint32_t elements_size) { new (&base()._1) ::nprpc::flat::Vector<::nprpc::flat::String>(buffer_, elements_size); }
  auto _1_d() noexcept { return ::nprpc::flat::Vector_Direct2<::nprpc::flat::String,::nprpc::flat::String_Direct1>(buffer_, offset_ + offsetof(lava_M23, _1)); }
};

struct lava_M24 {
  uint32_t _1;
  int32_t _2;
  int32_t _3;
  int32_t _4;
  int32_t _5;
  int32_t _6;
};

class lava_M24_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M24*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M24*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M24_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& _1() const noexcept { return base()._1;}
  uint32_t& _1() noexcept { return base()._1;}
  const int32_t& _2() const noexcept { return base()._2;}
  int32_t& _2() noexcept { return base()._2;}
  const int32_t& _3() const noexcept { return base()._3;}
  int32_t& _3() noexcept { return base()._3;}
  const int32_t& _4() const noexcept { return base()._4;}
  int32_t& _4() noexcept { return base()._4;}
  const int32_t& _5() const noexcept { return base()._5;}
  int32_t& _5() noexcept { return base()._5;}
  const int32_t& _6() const noexcept { return base()._6;}
  int32_t& _6() noexcept { return base()._6;}
};

struct lava_M25 {
  ::lava::flat::Capture _1;
};

class lava_M25_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M25*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M25*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M25_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  auto _1() noexcept { return ::lava::flat::Capture_Direct(buffer_, offset_ + offsetof(lava_M25, _1)); }
};

struct lava_M26 {
  uint32_t _1;
  ::nprpc::flat::String _2;
};

class lava_M26_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M26*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M26*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M26_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& _1() const noexcept { return base()._1;}
  uint32_t& _1() noexcept { return base()._1;}
  void _2(const char* str) { new (&base()._2) ::nprpc::flat::String(buffer_, str); }
  void _2(const std::string& str) { new (&base()._2) ::nprpc::flat::String(buffer_, str); }
  auto _2() noexcept { return (::nprpc::flat::Span<char>)base()._2; }
  auto _2() const noexcept { return (::nprpc::flat::Span<const char>)base()._2; }
  auto _2_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(lava_M26, _2)); }
};

struct lava_M27 {
  ::nprpc::flat::Vector<uint8_t> _1;
};

class lava_M27_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M27*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M27*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M27_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  void _1(std::uint32_t elements_size) { new (&base()._1) ::nprpc::flat::Vector<uint8_t>(buffer_, elements_size); }
  auto _1_d() noexcept { return ::nprpc::flat::Vector_Direct1<uint8_t>(buffer_, offset_ + offsetof(lava_M27, _1)); }
  auto _1() noexcept { return (::nprpc::flat::Span<uint8_t>)base()._1; }
  const auto _1() const noexcept { return (::nprpc::flat::Span<const uint8_t>)base()._1; }
};

struct lava_M28 {
  uint32_t _1;
  float _2;
};

class lava_M28_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M28*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M28*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M28_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& _1() const noexcept { return base()._1;}
  uint32_t& _1() noexcept { return base()._1;}
  const float& _2() const noexcept { return base()._2;}
  float& _2() noexcept { return base()._2;}
};

struct lava_M29 {
  ::lava::flat::GpuReport _1;
};

class lava_M29_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M29*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M29*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M29_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  auto _1() noexcept { return ::lava::flat::GpuReport_Direct(buffer_, offset_ + offsetof(lava_M29, _1)); }
};

struct lava_M30 {
  uint32_t _1;
  float _2;
  float _3;
  float _4;
  float _5;
  float _6;
  float _7;
};

class lava_M30_Direct {
  ::nprpc::flat_buffer& buffer_;
  const std::uint32_t offset_;

  auto& base() noexcept { return *reinterpret_cast<lava_M30*>(reinterpret_cast<std::byte*>(buffer_.data().data()) + offset_); }
  auto const& base() const noexcept { return *reinterpret_cast<const lava_M30*>(reinterpret_cast<const std::byte*>(buffer_.data().data()) + offset_); }
public:
  uint32_t offset() const noexcept { return offset_; }
  void* __data() noexcept { return (void*)&base(); }
  lava_M30_Direct(::nprpc::flat_buffer& buffer, std::uint32_t offset)
    : buffer_(buffer)
    , offset_(offset)
  {
  }
  const uint32_t& _1() const noexcept { return base()._1;}
  uint32_t& _1() noexcept { return base()._1;}
  const float& _2() const noexcept { return base()._2;}
  float& _2() noexcept { return base()._2;}
  const float& _3() const noexcept { return base()._3;}
  float& _3() noexcept { return base()._3;}
  const float& _4() const noexcept { return base()._4;}
  float& _4() noexcept { return base()._4;}
  const float& _5() const noexcept { return base()._5;}
  float& _5() noexcept { return base()._5;}
  const float& _6() const noexcept { return base()._6;}
  float& _6() noexcept { return base()._6;}
  const float& _7() const noexcept { return base()._7;}
  float& _7() noexcept { return base()._7;}
};


bool check_1S2Fu323Fu324Fu32(::nprpc::flat_buffer& buf, lava_M1_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 20) goto check_failed;
  {
    if(!ia._1_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  return true;
check_failed:
  return false;
}
bool check_1S2Fu32(::nprpc::flat_buffer& buf, lava_M3_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 12) goto check_failed;
  {
    if(!ia._1_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  return true;
check_failed:
  return false;
}
bool check_1VFu82Fu32(::nprpc::flat_buffer& buf, lava_M5_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 12) goto check_failed;
  {
    if(!ia._1_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  return true;
check_failed:
  return false;
}
bool check_1Fu32(::nprpc::flat_buffer& buf, lava_M2_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 4) goto check_failed;
  return true;
check_failed:
  return false;
}
bool check_1S2Fu323Fu324S5EWindowFrame6S(::nprpc::flat_buffer& buf, lava_M6_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 36) goto check_failed;
  {
    if(!ia._1_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  {
    if(!ia._4_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  {
    if(!ia._6_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  return true;
check_failed:
  return false;
}
bool check_1S2EPanelEdge3Fu324Fb5S6S(::nprpc::flat_buffer& buf, lava_M7_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 36) goto check_failed;
  {
    if(!ia._1_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  {
    if(!ia._5_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  {
    if(!ia._6_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  return true;
check_failed:
  return false;
}
bool check_1Fu322Fu323Fu32(::nprpc::flat_buffer& buf, lava_M8_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 12) goto check_failed;
  return true;
check_failed:
  return false;
}
bool check_1Fu322Fi323Fi324Fu325Fu32(::nprpc::flat_buffer& buf, lava_M10_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 20) goto check_failed;
  return true;
check_failed:
  return false;
}
bool check_1Fu322ECursorShape(::nprpc::flat_buffer& buf, lava_M11_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 8) goto check_failed;
  return true;
check_failed:
  return false;
}
bool check_1Appearance_1(::nprpc::flat_buffer& buf, lava_M12_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 16) goto check_failed;
  return true;
check_failed:
  return false;
}
bool check_1SystemTheme_1(::nprpc::flat_buffer& buf, lava_M13_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 12) goto check_failed;
  {
    {
      if(!ia._1().name_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
    }
  }
  return true;
check_failed:
  return false;
}
bool check_1Wallpaper_1(::nprpc::flat_buffer& buf, lava_M14_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 28) goto check_failed;
  {
    {
      if(!ia._1().mode_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
    }
    {
      if(!ia._1().path_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
    }
    {
      if(!ia._1().fit_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
    }
  }
  return true;
check_failed:
  return false;
}
bool check_1KeyboardSettings_1(::nprpc::flat_buffer& buf, lava_M15_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 56) goto check_failed;
  {
    {
      if(!ia._1().layout_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
    }
    {
      if(!ia._1().variant_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
    }
    {
      if(!ia._1().options_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
    }
    {
      if(!ia._1().model_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
    }
    {
      if(!ia._1().rules_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
    }
    {
      if(!ia._1().modKey_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
    }
  }
  return true;
check_failed:
  return false;
}
bool check_1S(::nprpc::flat_buffer& buf, lava_M19_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 8) goto check_failed;
  {
    if(!ia._1_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  return true;
check_failed:
  return false;
}
bool check_1OutputRequest_1(::nprpc::flat_buffer& buf, lava_M21_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 40) goto check_failed;
  {
    {
      if(!ia._1().name_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
    }
  }
  return true;
check_failed:
  return false;
}
bool check_1Fu322Ff323Ff32(::nprpc::flat_buffer& buf, lava_M22_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 12) goto check_failed;
  return true;
check_failed:
  return false;
}
bool check_1Fu322Fi323Fi324Fi325Fi326Fi32(::nprpc::flat_buffer& buf, lava_M24_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 24) goto check_failed;
  return true;
check_failed:
  return false;
}
bool check_1Fu322S(::nprpc::flat_buffer& buf, lava_M26_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 12) goto check_failed;
  {
    if(!ia._2_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  return true;
check_failed:
  return false;
}
bool check_1Fu322Ff32(::nprpc::flat_buffer& buf, lava_M28_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 8) goto check_failed;
  return true;
check_failed:
  return false;
}
bool check_1Fu322Ff323Ff324Ff325Ff326Ff327Ff32(::nprpc::flat_buffer& buf, lava_M30_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 28) goto check_failed;
  return true;
check_failed:
  return false;
}
} // 

uint32_t Compositor::RegisterFont(const std::string& path, uint32_t pixelSize26_6, uint32_t faceIndex, uint32_t rasterFlags) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 52;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(path.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(52);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 0;
  lava_M1_Direct _(buf,32);
  _._1(path);
  _._2() = pixelSize26_6;
  _._3() = faceIndex;
  _._4() = rasterFlags;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M2_Direct out(buf, sizeof(::nprpc::impl::Header));
    uint32_t __ret_value;
    __ret_value = out._1();
  return __ret_value;
}

::nprpc::Task<uint32_t>
Compositor::RegisterFontAsync(const std::string& path, uint32_t pixelSize26_6, uint32_t faceIndex, uint32_t rasterFlags, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 52;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(path.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(52);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 0;
  lava_M1_Direct _(buf,32);
  _._1(path);
  _._2() = pixelSize26_6;
  _._3() = faceIndex;
  _._4() = rasterFlags;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M2_Direct out(buf, sizeof(::nprpc::impl::Header));
    uint32_t __ret_value;
    __ret_value = out._1();
  co_return __ret_value;
}

ImageInfo Compositor::RegisterImage(const std::string& path, uint32_t maxPixelSize) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(path.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 1;
  lava_M3_Direct _(buf,32);
  _._1(path);
  _._2() = maxPixelSize;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M4_Direct out(buf, sizeof(::nprpc::impl::Header));
    ImageInfo __ret_value;
    memcpy(&__ret_value, out._1().__data(), 12);
  return __ret_value;
}

::nprpc::Task<ImageInfo>
Compositor::RegisterImageAsync(const std::string& path, uint32_t maxPixelSize, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(path.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 1;
  lava_M3_Direct _(buf,32);
  _._1(path);
  _._2() = maxPixelSize;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M4_Direct out(buf, sizeof(::nprpc::impl::Header));
    ImageInfo __ret_value;
    memcpy(&__ret_value, out._1().__data(), 12);
  co_return __ret_value;
}

ImageInfo Compositor::RegisterImageData(::nprpc::flat::Span<const uint8_t> bytes, uint32_t maxPixelSize) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(bytes.size()) * 1);
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 2;
  lava_M5_Direct _(buf,32);
  _._1(static_cast<uint32_t>(bytes.size()));
  memcpy(_._1().data(), bytes.data(), bytes.size() * 1);
  _._2() = maxPixelSize;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M4_Direct out(buf, sizeof(::nprpc::impl::Header));
    ImageInfo __ret_value;
    memcpy(&__ret_value, out._1().__data(), 12);
  return __ret_value;
}

::nprpc::Task<ImageInfo>
Compositor::RegisterImageDataAsync(::nprpc::flat::Span<const uint8_t> bytes, uint32_t maxPixelSize, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(bytes.size()) * 1);
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 2;
  lava_M5_Direct _(buf,32);
  _._1(static_cast<uint32_t>(bytes.size()));
  memcpy(_._1().data(), bytes.data(), bytes.size() * 1);
  _._2() = maxPixelSize;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M4_Direct out(buf, sizeof(::nprpc::impl::Header));
    ImageInfo __ret_value;
    memcpy(&__ret_value, out._1().__data(), 12);
  co_return __ret_value;
}

void Compositor::ReleaseImage(uint32_t id) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 3;
  lava_M2_Direct _(buf,32);
  _._1() = id;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::ReleaseImageAsync(uint32_t id, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 3;
  lava_M2_Direct _(buf,32);
  _._1() = id;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

uint32_t Compositor::CreateSurface(const std::string& arenaId, uint32_t width, uint32_t height, const std::string& title, const WindowFrame& frame, const std::string& appId) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 68;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(arenaId.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(title.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(appId.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(68);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 4;
  lava_M6_Direct _(buf,32);
  _._1(arenaId);
  _._2() = width;
  _._3() = height;
  _._4(title);
  _._5() = frame;
  _._6(appId);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M2_Direct out(buf, sizeof(::nprpc::impl::Header));
    uint32_t __ret_value;
    __ret_value = out._1();
  return __ret_value;
}

::nprpc::Task<uint32_t>
Compositor::CreateSurfaceAsync(const std::string& arenaId, uint32_t width, uint32_t height, const std::string& title, const WindowFrame& frame, const std::string& appId, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 68;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(arenaId.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(title.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(appId.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(68);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 4;
  lava_M6_Direct _(buf,32);
  _._1(arenaId);
  _._2() = width;
  _._3() = height;
  _._4(title);
  _._5() = frame;
  _._6(appId);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M2_Direct out(buf, sizeof(::nprpc::impl::Header));
    uint32_t __ret_value;
    __ret_value = out._1();
  co_return __ret_value;
}

uint32_t Compositor::CreatePanel(const std::string& arenaId, const PanelEdge& edge, uint32_t thickness, bool reserve, const std::string& title, const std::string& appId) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 68;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(arenaId.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(title.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(appId.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(68);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 5;
  lava_M7_Direct _(buf,32);
  _._1(arenaId);
  _._2() = edge;
  _._3() = thickness;
  _._4() = reserve;
  _._5(title);
  _._6(appId);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M2_Direct out(buf, sizeof(::nprpc::impl::Header));
    uint32_t __ret_value;
    __ret_value = out._1();
  return __ret_value;
}

::nprpc::Task<uint32_t>
Compositor::CreatePanelAsync(const std::string& arenaId, const PanelEdge& edge, uint32_t thickness, bool reserve, const std::string& title, const std::string& appId, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 68;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(arenaId.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(title.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(appId.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(68);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 5;
  lava_M7_Direct _(buf,32);
  _._1(arenaId);
  _._2() = edge;
  _._3() = thickness;
  _._4() = reserve;
  _._5(title);
  _._6(appId);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M2_Direct out(buf, sizeof(::nprpc::impl::Header));
    uint32_t __ret_value;
    __ret_value = out._1();
  co_return __ret_value;
}

void Compositor::BeginMove(uint32_t surfaceId) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 6;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::BeginMoveAsync(uint32_t surfaceId, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 6;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

void Compositor::SetMinSize(uint32_t surfaceId, uint32_t minWidth, uint32_t minHeight) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 7;
  lava_M8_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = minWidth;
  _._3() = minHeight;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetMinSizeAsync(uint32_t surfaceId, uint32_t minWidth, uint32_t minHeight, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 7;
  lava_M8_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = minWidth;
  _._3() = minHeight;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

bool Compositor::ToggleMaximize(uint32_t surfaceId) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 8;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M9_Direct out(buf, sizeof(::nprpc::impl::Header));
    bool __ret_value;
    __ret_value = (bool)out._1();
  return __ret_value;
}

::nprpc::Task<bool>
Compositor::ToggleMaximizeAsync(uint32_t surfaceId, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 8;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M9_Direct out(buf, sizeof(::nprpc::impl::Header));
    bool __ret_value;
    __ret_value = (bool)out._1();
  co_return __ret_value;
}

void Compositor::Minimize(uint32_t surfaceId) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 9;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::MinimizeAsync(uint32_t surfaceId, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 9;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

void Compositor::SetPanelThickness(uint32_t surfaceId, uint32_t thickness, uint32_t reserved) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 10;
  lava_M8_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = thickness;
  _._3() = reserved;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetPanelThicknessAsync(uint32_t surfaceId, uint32_t thickness, uint32_t reserved, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 10;
  lava_M8_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = thickness;
  _._3() = reserved;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

std::pair<::nprpc::StreamWriter<WindowListAck>, ::nprpc::StreamReader<WindowList>> Compositor::SubscribeWindows() {
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  auto stream_id = ::nprpc::impl::StreamManager::generate_stream_id();
  ::nprpc::StreamWriter<WindowListAck> writer(session->ctx(), stream_id);
  ::nprpc::StreamReader<WindowList> reader(session->ctx(), stream_id, ::nprpc::impl::StreamManager::kDefaultReaderWindow);
  ::nprpc::flat_buffer buf;
  buf.prepare(48);
  buf.commit(48);
  auto* header = static_cast<::nprpc::impl::Header*>(buf.data().data());
  header->msg_id = ::nprpc::impl::MessageId::StreamInitialization;
  header->msg_type = ::nprpc::impl::MessageType::Request;
  ::nprpc::impl::flat::StreamInit_Direct init(buf, sizeof(::nprpc::impl::Header));
  init.stream_id() = stream_id;
  init.poa_idx() = this->poa_idx();
  init.interface_idx() = interface_idx_;
  init.object_id() = this->object_id();
  init.func_idx() = 11;
  init.stream_kind() = ::nprpc::impl::StreamKind::Bidi;
  init.initial_credits() = ::nprpc::impl::StreamManager::kDefaultReaderWindow;
  header->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != 0) { throw ::nprpc::Exception("Unknown Error"); }
  session->ctx().stream_manager->defer_stream_start(stream_id);
  session->ctx().stream_manager->on_reply_sent();
  return { std::move(writer), std::move(reader) };
}

std::pair<::nprpc::StreamWriter<PanelAreaAck>, ::nprpc::StreamReader<PanelArea>> Compositor::SubscribePanelArea(uint32_t surfaceId) {
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  auto stream_id = ::nprpc::impl::StreamManager::generate_stream_id();
  ::nprpc::StreamWriter<PanelAreaAck> writer(session->ctx(), stream_id);
  ::nprpc::StreamReader<PanelArea> reader(session->ctx(), stream_id, ::nprpc::impl::StreamManager::kDefaultReaderWindow);
  ::nprpc::flat_buffer buf;
  buf.prepare(52);
  buf.commit(52);
  auto* header = static_cast<::nprpc::impl::Header*>(buf.data().data());
  header->msg_id = ::nprpc::impl::MessageId::StreamInitialization;
  header->msg_type = ::nprpc::impl::MessageType::Request;
  ::nprpc::impl::flat::StreamInit_Direct init(buf, sizeof(::nprpc::impl::Header));
  init.stream_id() = stream_id;
  init.poa_idx() = this->poa_idx();
  init.interface_idx() = interface_idx_;
  init.object_id() = this->object_id();
  init.func_idx() = 12;
  init.stream_kind() = ::nprpc::impl::StreamKind::Bidi;
  init.initial_credits() = ::nprpc::impl::StreamManager::kDefaultReaderWindow;
  lava_M2_Direct _(buf,48);
  _._1() = surfaceId;
  header->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) { throw ::nprpc::Exception("Unknown Error"); }
  session->ctx().stream_manager->defer_stream_start(stream_id);
  session->ctx().stream_manager->on_reply_sent();
  return { std::move(writer), std::move(reader) };
}

std::pair<::nprpc::StreamWriter<ThemeAck>, ::nprpc::StreamReader<SystemTheme>> Compositor::SubscribeSystemTheme() {
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  auto stream_id = ::nprpc::impl::StreamManager::generate_stream_id();
  ::nprpc::StreamWriter<ThemeAck> writer(session->ctx(), stream_id);
  ::nprpc::StreamReader<SystemTheme> reader(session->ctx(), stream_id, ::nprpc::impl::StreamManager::kDefaultReaderWindow);
  ::nprpc::flat_buffer buf;
  buf.prepare(48);
  buf.commit(48);
  auto* header = static_cast<::nprpc::impl::Header*>(buf.data().data());
  header->msg_id = ::nprpc::impl::MessageId::StreamInitialization;
  header->msg_type = ::nprpc::impl::MessageType::Request;
  ::nprpc::impl::flat::StreamInit_Direct init(buf, sizeof(::nprpc::impl::Header));
  init.stream_id() = stream_id;
  init.poa_idx() = this->poa_idx();
  init.interface_idx() = interface_idx_;
  init.object_id() = this->object_id();
  init.func_idx() = 13;
  init.stream_kind() = ::nprpc::impl::StreamKind::Bidi;
  init.initial_credits() = ::nprpc::impl::StreamManager::kDefaultReaderWindow;
  header->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != 0) { throw ::nprpc::Exception("Unknown Error"); }
  session->ctx().stream_manager->defer_stream_start(stream_id);
  session->ctx().stream_manager->on_reply_sent();
  return { std::move(writer), std::move(reader) };
}

void Compositor::ActivateWindow(uint32_t surfaceId) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 14;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::ActivateWindowAsync(uint32_t surfaceId, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 14;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

void Compositor::SetInputRegion(uint32_t surfaceId, int32_t x, int32_t y, uint32_t w, uint32_t h) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 52;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(52);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 15;
  lava_M10_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = x;
  _._3() = y;
  _._4() = w;
  _._5() = h;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetInputRegionAsync(uint32_t surfaceId, int32_t x, int32_t y, uint32_t w, uint32_t h, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 52;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(52);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 15;
  lava_M10_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = x;
  _._3() = y;
  _._4() = w;
  _._5() = h;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

void Compositor::SetCursor(uint32_t surfaceId, const CursorShape& shape) {
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 40;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(40);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 16;
  lava_M11_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = shape;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  ::nprpc::impl::g_rpc->send_unreliable(this->get_endpoint(), std::move(buf));
}

Appearance Compositor::GetAppearance() {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 17;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M12_Direct out(buf, sizeof(::nprpc::impl::Header));
    Appearance __ret_value;
    memcpy(&__ret_value, out._1().__data(), 16);
  return __ret_value;
}

::nprpc::Task<Appearance>
Compositor::GetAppearanceAsync(std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 17;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M12_Direct out(buf, sizeof(::nprpc::impl::Header));
    Appearance __ret_value;
    memcpy(&__ret_value, out._1().__data(), 16);
  co_return __ret_value;
}

void Compositor::SetAppearance(const Appearance& appearance) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 48;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(48);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 18;
  lava_M12_Direct _(buf,32);
  memcpy(_._1().__data(), &appearance, 16);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetAppearanceAsync(const Appearance& appearance, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 48;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(48);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 18;
  lava_M12_Direct _(buf,32);
  memcpy(_._1().__data(), &appearance, 16);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

SystemTheme Compositor::GetSystemTheme() {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 19;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M13_Direct out(buf, sizeof(::nprpc::impl::Header));
    SystemTheme __ret_value;
    __ret_value.serial = out._1().serial();
    __ret_value.name = (std::string_view)out._1().name();
  return __ret_value;
}

::nprpc::Task<SystemTheme>
Compositor::GetSystemThemeAsync(std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 19;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M13_Direct out(buf, sizeof(::nprpc::impl::Header));
    SystemTheme __ret_value;
    __ret_value.serial = out._1().serial();
    __ret_value.name = (std::string_view)out._1().name();
  co_return __ret_value;
}

void Compositor::SetSystemTheme(const SystemTheme& theme) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(theme.name.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 20;
  lava_M13_Direct _(buf,32);
  _._1().serial() = theme.serial;
  _._1().name(theme.name);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetSystemThemeAsync(const SystemTheme& theme, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(theme.name.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 20;
  lava_M13_Direct _(buf,32);
  _._1().serial() = theme.serial;
  _._1().name(theme.name);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

Wallpaper Compositor::GetWallpaper() {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 21;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M14_Direct out(buf, sizeof(::nprpc::impl::Header));
    Wallpaper __ret_value;
    __ret_value.mode = (std::string_view)out._1().mode();
    __ret_value.color = out._1().color();
    __ret_value.path = (std::string_view)out._1().path();
    __ret_value.fit = (std::string_view)out._1().fit();
  return __ret_value;
}

::nprpc::Task<Wallpaper>
Compositor::GetWallpaperAsync(std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 21;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M14_Direct out(buf, sizeof(::nprpc::impl::Header));
    Wallpaper __ret_value;
    __ret_value.mode = (std::string_view)out._1().mode();
    __ret_value.color = out._1().color();
    __ret_value.path = (std::string_view)out._1().path();
    __ret_value.fit = (std::string_view)out._1().fit();
  co_return __ret_value;
}

void Compositor::SetWallpaper(const Wallpaper& wallpaper) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 60;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(wallpaper.mode.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(wallpaper.path.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(wallpaper.fit.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(60);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 22;
  lava_M14_Direct _(buf,32);
  _._1().mode(wallpaper.mode);
  _._1().color() = wallpaper.color;
  _._1().path(wallpaper.path);
  _._1().fit(wallpaper.fit);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetWallpaperAsync(const Wallpaper& wallpaper, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 60;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(wallpaper.mode.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(wallpaper.path.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(wallpaper.fit.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(60);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 22;
  lava_M14_Direct _(buf,32);
  _._1().mode(wallpaper.mode);
  _._1().color() = wallpaper.color;
  _._1().path(wallpaper.path);
  _._1().fit(wallpaper.fit);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

KeyboardSettings Compositor::GetKeyboard() {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 23;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M15_Direct out(buf, sizeof(::nprpc::impl::Header));
    KeyboardSettings __ret_value;
    __ret_value.layout = (std::string_view)out._1().layout();
    __ret_value.variant = (std::string_view)out._1().variant();
    __ret_value.options = (std::string_view)out._1().options();
    __ret_value.model = (std::string_view)out._1().model();
    __ret_value.rules = (std::string_view)out._1().rules();
    __ret_value.repeatRate = out._1().repeatRate();
    __ret_value.repeatDelay = out._1().repeatDelay();
    __ret_value.modKey = (std::string_view)out._1().modKey();
  return __ret_value;
}

::nprpc::Task<KeyboardSettings>
Compositor::GetKeyboardAsync(std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 23;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M15_Direct out(buf, sizeof(::nprpc::impl::Header));
    KeyboardSettings __ret_value;
    __ret_value.layout = (std::string_view)out._1().layout();
    __ret_value.variant = (std::string_view)out._1().variant();
    __ret_value.options = (std::string_view)out._1().options();
    __ret_value.model = (std::string_view)out._1().model();
    __ret_value.rules = (std::string_view)out._1().rules();
    __ret_value.repeatRate = out._1().repeatRate();
    __ret_value.repeatDelay = out._1().repeatDelay();
    __ret_value.modKey = (std::string_view)out._1().modKey();
  co_return __ret_value;
}

void Compositor::SetKeyboard(const KeyboardSettings& settings) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 88;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(settings.layout.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(settings.variant.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(settings.options.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(settings.model.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(settings.rules.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(settings.modKey.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(88);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 24;
  lava_M15_Direct _(buf,32);
  _._1().layout(settings.layout);
  _._1().variant(settings.variant);
  _._1().options(settings.options);
  _._1().model(settings.model);
  _._1().rules(settings.rules);
  _._1().repeatRate() = settings.repeatRate;
  _._1().repeatDelay() = settings.repeatDelay;
  _._1().modKey(settings.modKey);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetKeyboardAsync(const KeyboardSettings& settings, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 88;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(settings.layout.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(settings.variant.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(settings.options.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(settings.model.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(settings.rules.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(settings.modKey.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(88);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 24;
  lava_M15_Direct _(buf,32);
  _._1().layout(settings.layout);
  _._1().variant(settings.variant);
  _._1().options(settings.options);
  _._1().model(settings.model);
  _._1().rules(settings.rules);
  _._1().repeatRate() = settings.repeatRate;
  _._1().repeatDelay() = settings.repeatDelay;
  _._1().modKey(settings.modKey);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

std::vector<KeyboardLayout> Compositor::ListKeyboardLayouts() {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 25;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M16_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<KeyboardLayout> __ret_value;
    {
      auto span = out._1();
      __ret_value.resize(span.size());
      auto it3 = std::begin(__ret_value);
      for (auto e : span) {
        (*it3).code = (std::string_view)e.code();
        (*it3).variant = (std::string_view)e.variant();
        (*it3).description = (std::string_view)e.description();
        ++it3;
      }
    }
  return __ret_value;
}

::nprpc::Task<std::vector<KeyboardLayout>>
Compositor::ListKeyboardLayoutsAsync(std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 25;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M16_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<KeyboardLayout> __ret_value;
    {
      auto span = out._1();
      __ret_value.resize(span.size());
      auto it3 = std::begin(__ret_value);
      for (auto e : span) {
        (*it3).code = (std::string_view)e.code();
        (*it3).variant = (std::string_view)e.variant();
        (*it3).description = (std::string_view)e.description();
        ++it3;
      }
    }
  co_return __ret_value;
}

std::vector<KeyBinding> Compositor::ListKeyBindings() {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 26;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M17_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<KeyBinding> __ret_value;
    {
      auto span = out._1();
      __ret_value.resize(span.size());
      auto it3 = std::begin(__ret_value);
      for (auto e : span) {
        (*it3).modifiers = (std::string_view)e.modifiers();
        (*it3).key = (std::string_view)e.key();
        (*it3).action = (std::string_view)e.action();
        (*it3).description = (std::string_view)e.description();
        ++it3;
      }
    }
  return __ret_value;
}

::nprpc::Task<std::vector<KeyBinding>>
Compositor::ListKeyBindingsAsync(std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 26;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M17_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<KeyBinding> __ret_value;
    {
      auto span = out._1();
      __ret_value.resize(span.size());
      auto it3 = std::begin(__ret_value);
      for (auto e : span) {
        (*it3).modifiers = (std::string_view)e.modifiers();
        (*it3).key = (std::string_view)e.key();
        (*it3).action = (std::string_view)e.action();
        (*it3).description = (std::string_view)e.description();
        ++it3;
      }
    }
  co_return __ret_value;
}

std::vector<OutputInfo> Compositor::ListOutputs() {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 27;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M18_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<OutputInfo> __ret_value;
    {
      auto span = out._1();
      __ret_value.resize(span.size());
      auto it3 = std::begin(__ret_value);
      for (auto e : span) {
        (*it3).name = (std::string_view)e.name();
        (*it3).description = (std::string_view)e.description();
        (*it3).enabled = (bool)e.enabled();
        (*it3).x = e.x();
        (*it3).y = e.y();
        (*it3).width = e.width();
        (*it3).height = e.height();
        (*it3).refresh = e.refresh();
        (*it3).scale = e.scale();
        (*it3).transform = e.transform();
        (*it3).primary = (bool)e.primary();
        ++it3;
      }
    }
  return __ret_value;
}

::nprpc::Task<std::vector<OutputInfo>>
Compositor::ListOutputsAsync(std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 27;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M18_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<OutputInfo> __ret_value;
    {
      auto span = out._1();
      __ret_value.resize(span.size());
      auto it3 = std::begin(__ret_value);
      for (auto e : span) {
        (*it3).name = (std::string_view)e.name();
        (*it3).description = (std::string_view)e.description();
        (*it3).enabled = (bool)e.enabled();
        (*it3).x = e.x();
        (*it3).y = e.y();
        (*it3).width = e.width();
        (*it3).height = e.height();
        (*it3).refresh = e.refresh();
        (*it3).scale = e.scale();
        (*it3).transform = e.transform();
        (*it3).primary = (bool)e.primary();
        ++it3;
      }
    }
  co_return __ret_value;
}

std::vector<OutputMode> Compositor::ListOutputModes(const std::string& name) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 40;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(name.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(40);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 28;
  lava_M19_Direct _(buf,32);
  _._1(name);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M20_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<OutputMode> __ret_value;
    {
      auto span = out._1();
      __ret_value.resize(span.size());
      memcpy(__ret_value.data(), span.data(), 16 * span.size());
    }
  return __ret_value;
}

::nprpc::Task<std::vector<OutputMode>>
Compositor::ListOutputModesAsync(const std::string& name, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 40;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(name.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(40);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 28;
  lava_M19_Direct _(buf,32);
  _._1(name);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M20_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<OutputMode> __ret_value;
    {
      auto span = out._1();
      __ret_value.resize(span.size());
      memcpy(__ret_value.data(), span.data(), 16 * span.size());
    }
  co_return __ret_value;
}

void Compositor::SetOutput(const OutputRequest& request) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 72;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(request.name.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(72);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 29;
  lava_M21_Direct _(buf,32);
  _._1().name(request.name);
  _._1().enabled() = request.enabled;
  _._1().width() = request.width;
  _._1().height() = request.height;
  _._1().refresh() = request.refresh;
  _._1().scale() = request.scale;
  _._1().x() = request.x;
  _._1().y() = request.y;
  _._1().transform() = request.transform;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetOutputAsync(const OutputRequest& request, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 72;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(request.name.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(72);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 29;
  lava_M21_Direct _(buf,32);
  _._1().name(request.name);
  _._1().enabled() = request.enabled;
  _._1().width() = request.width;
  _._1().height() = request.height;
  _._1().refresh() = request.refresh;
  _._1().scale() = request.scale;
  _._1().x() = request.x;
  _._1().y() = request.y;
  _._1().transform() = request.transform;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

void Compositor::SetPrimaryOutput(const std::string& name) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 40;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(name.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(40);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 30;
  lava_M19_Direct _(buf,32);
  _._1(name);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetPrimaryOutputAsync(const std::string& name, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 40;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(name.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(40);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 30;
  lava_M19_Direct _(buf,32);
  _._1(name);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

std::string Compositor::GetArrangement() {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 31;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M19_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::string __ret_value;
    __ret_value = (std::string_view)out._1();
  return __ret_value;
}

::nprpc::Task<std::string>
Compositor::GetArrangementAsync(std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 31;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M19_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::string __ret_value;
    __ret_value = (std::string_view)out._1();
  co_return __ret_value;
}

void Compositor::SetArrangement(const std::string& mode) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 40;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(mode.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(40);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 32;
  lava_M19_Direct _(buf,32);
  _._1(mode);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetArrangementAsync(const std::string& mode, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 40;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(mode.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(40);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 32;
  lava_M19_Direct _(buf,32);
  _._1(mode);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

std::pair<::nprpc::StreamWriter<FocusAck>, ::nprpc::StreamReader<ActiveWindow>> Compositor::SubscribeActiveWindow() {
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  auto stream_id = ::nprpc::impl::StreamManager::generate_stream_id();
  ::nprpc::StreamWriter<FocusAck> writer(session->ctx(), stream_id);
  ::nprpc::StreamReader<ActiveWindow> reader(session->ctx(), stream_id, ::nprpc::impl::StreamManager::kDefaultReaderWindow);
  ::nprpc::flat_buffer buf;
  buf.prepare(48);
  buf.commit(48);
  auto* header = static_cast<::nprpc::impl::Header*>(buf.data().data());
  header->msg_id = ::nprpc::impl::MessageId::StreamInitialization;
  header->msg_type = ::nprpc::impl::MessageType::Request;
  ::nprpc::impl::flat::StreamInit_Direct init(buf, sizeof(::nprpc::impl::Header));
  init.stream_id() = stream_id;
  init.poa_idx() = this->poa_idx();
  init.interface_idx() = interface_idx_;
  init.object_id() = this->object_id();
  init.func_idx() = 33;
  init.stream_kind() = ::nprpc::impl::StreamKind::Bidi;
  init.initial_credits() = ::nprpc::impl::StreamManager::kDefaultReaderWindow;
  header->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != 0) { throw ::nprpc::Exception("Unknown Error"); }
  session->ctx().stream_manager->defer_stream_start(stream_id);
  session->ctx().stream_manager->on_reply_sent();
  return { std::move(writer), std::move(reader) };
}

void Compositor::DestroySurface(uint32_t surfaceId) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 34;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::DestroySurfaceAsync(uint32_t surfaceId, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 34;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

void Compositor::Present(uint32_t surfaceId) {
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 35;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  ::nprpc::impl::g_rpc->send_unreliable(this->get_endpoint(), std::move(buf));
}

void Compositor::ScrollUnclaimed(uint32_t surfaceId, float dx, float dy) {
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 36;
  lava_M22_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = dx;
  _._3() = dy;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  ::nprpc::impl::g_rpc->send_unreliable(this->get_endpoint(), std::move(buf));
}

void Compositor::Heartbeat(uint32_t surfaceId) {
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 37;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  ::nprpc::impl::g_rpc->send_unreliable(this->get_endpoint(), std::move(buf));
}

std::pair<::nprpc::StreamWriter<InputAck>, ::nprpc::StreamReader<InputEvent>> Compositor::SubscribeInput(uint32_t surfaceId) {
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  auto stream_id = ::nprpc::impl::StreamManager::generate_stream_id();
  ::nprpc::StreamWriter<InputAck> writer(session->ctx(), stream_id);
  ::nprpc::StreamReader<InputEvent> reader(session->ctx(), stream_id, ::nprpc::impl::StreamManager::kDefaultReaderWindow);
  ::nprpc::flat_buffer buf;
  buf.prepare(52);
  buf.commit(52);
  auto* header = static_cast<::nprpc::impl::Header*>(buf.data().data());
  header->msg_id = ::nprpc::impl::MessageId::StreamInitialization;
  header->msg_type = ::nprpc::impl::MessageType::Request;
  ::nprpc::impl::flat::StreamInit_Direct init(buf, sizeof(::nprpc::impl::Header));
  init.stream_id() = stream_id;
  init.poa_idx() = this->poa_idx();
  init.interface_idx() = interface_idx_;
  init.object_id() = this->object_id();
  init.func_idx() = 38;
  init.stream_kind() = ::nprpc::impl::StreamKind::Bidi;
  init.initial_credits() = ::nprpc::impl::StreamManager::kDefaultReaderWindow;
  lava_M2_Direct _(buf,48);
  _._1() = surfaceId;
  header->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) { throw ::nprpc::Exception("Unknown Error"); }
  session->ctx().stream_manager->defer_stream_start(stream_id);
  session->ctx().stream_manager->on_reply_sent();
  return { std::move(writer), std::move(reader) };
}

std::vector<std::string> Compositor::TakeDroppedPaths(uint32_t surfaceId) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 39;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M23_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<std::string> __ret_value;
    {
      auto span = out._1_d()();
      __ret_value.resize(span.size());
      auto it3 = std::begin(__ret_value);
      for (auto e : span) {
        (*it3) = (std::string_view)e();
        ++it3;
      }
    }
  return __ret_value;
}

::nprpc::Task<std::vector<std::string>>
Compositor::TakeDroppedPathsAsync(uint32_t surfaceId, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 39;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M23_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<std::string> __ret_value;
    {
      auto span = out._1_d()();
      __ret_value.resize(span.size());
      auto it3 = std::begin(__ret_value);
      for (auto e : span) {
        (*it3) = (std::string_view)e();
        ++it3;
      }
    }
  co_return __ret_value;
}

Capture Compositor::CaptureSurface(uint32_t surfaceId, int32_t x, int32_t y, int32_t w, int32_t h, int32_t maxSide) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 56;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(56);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 40;
  lava_M24_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = x;
  _._3() = y;
  _._4() = w;
  _._5() = h;
  _._6() = maxSide;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M25_Direct out(buf, sizeof(::nprpc::impl::Header));
    Capture __ret_value;
    __ret_value.width = out._1().width();
    __ret_value.height = out._1().height();
    {
      auto span = out._1().png();
      __ret_value.png.resize(span.size());
      memcpy(__ret_value.png.data(), span.data(), 1 * span.size());
    }
  return __ret_value;
}

::nprpc::Task<Capture>
Compositor::CaptureSurfaceAsync(uint32_t surfaceId, int32_t x, int32_t y, int32_t w, int32_t h, int32_t maxSide, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 56;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(56);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 40;
  lava_M24_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = x;
  _._3() = y;
  _._4() = w;
  _._5() = h;
  _._6() = maxSide;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M25_Direct out(buf, sizeof(::nprpc::impl::Header));
    Capture __ret_value;
    __ret_value.width = out._1().width();
    __ret_value.height = out._1().height();
    {
      auto span = out._1().png();
      __ret_value.png.resize(span.size());
      memcpy(__ret_value.png.data(), span.data(), 1 * span.size());
    }
  co_return __ret_value;
}

std::string Compositor::GetClipboard(uint32_t surfaceId) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 41;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M19_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::string __ret_value;
    __ret_value = (std::string_view)out._1();
  return __ret_value;
}

::nprpc::Task<std::string>
Compositor::GetClipboardAsync(uint32_t surfaceId, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 41;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M19_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::string __ret_value;
    __ret_value = (std::string_view)out._1();
  co_return __ret_value;
}

void Compositor::SetClipboard(uint32_t surfaceId, const std::string& text) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(text.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 42;
  lava_M26_Direct _(buf,32);
  _._1() = surfaceId;
  _._2(text);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetClipboardAsync(uint32_t surfaceId, const std::string& text, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(text.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 42;
  lava_M26_Direct _(buf,32);
  _._1() = surfaceId;
  _._2(text);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

std::string Compositor::GetPrimarySelection(uint32_t surfaceId) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 43;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M19_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::string __ret_value;
    __ret_value = (std::string_view)out._1();
  return __ret_value;
}

::nprpc::Task<std::string>
Compositor::GetPrimarySelectionAsync(uint32_t surfaceId, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 43;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M19_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::string __ret_value;
    __ret_value = (std::string_view)out._1();
  co_return __ret_value;
}

void Compositor::SetPrimarySelection(uint32_t surfaceId, const std::string& text) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(text.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 44;
  lava_M26_Direct _(buf,32);
  _._1() = surfaceId;
  _._2(text);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetPrimarySelectionAsync(uint32_t surfaceId, const std::string& text, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 44;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(text.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(44);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 44;
  lava_M26_Direct _(buf,32);
  _._1() = surfaceId;
  _._2(text);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

std::vector<uint8_t> Compositor::GetClipboardPng(uint32_t surfaceId) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 45;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M27_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<uint8_t> __ret_value;
    {
      auto span = out._1();
      __ret_value.resize(span.size());
      memcpy(__ret_value.data(), span.data(), 1 * span.size());
    }
  return __ret_value;
}

::nprpc::Task<std::vector<uint8_t>>
Compositor::GetClipboardPngAsync(uint32_t surfaceId, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 36;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(36);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 45;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M27_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<uint8_t> __ret_value;
    {
      auto span = out._1();
      __ret_value.resize(span.size());
      memcpy(__ret_value.data(), span.data(), 1 * span.size());
    }
  co_return __ret_value;
}

void Compositor::SetBackdropBlur(uint32_t surfaceId, float radius) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 40;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(40);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 46;
  lava_M28_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = radius;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetBackdropBlurAsync(uint32_t surfaceId, float radius, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 40;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(40);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 46;
  lava_M28_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = radius;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

GpuReport Compositor::GetGpuReport() {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 47;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M29_Direct out(buf, sizeof(::nprpc::impl::Header));
    GpuReport __ret_value;
    __ret_value.deviceName = (std::string_view)out._1().deviceName();
    __ret_value.samples = out._1().samples();
    __ret_value.maxSamples = out._1().maxSamples();
    __ret_value.heapUsageBytes = out._1().heapUsageBytes();
    __ret_value.heapBudgetBytes = out._1().heapBudgetBytes();
    __ret_value.heapSizeBytes = out._1().heapSizeBytes();
    __ret_value.vmaAllocatedBytes = out._1().vmaAllocatedBytes();
    __ret_value.vmaBlockBytes = out._1().vmaBlockBytes();
    __ret_value.ownBytes = out._1().ownBytes();
    __ret_value.foreignBytes = out._1().foreignBytes();
    __ret_value.retiringBytes = out._1().retiringBytes();
    {
      auto span = out._1().windows();
      __ret_value.windows.resize(span.size());
      auto it3 = std::begin(__ret_value.windows);
      for (auto e : span) {
        (*it3).id = e.id();
        (*it3).title = (std::string_view)e.title();
        (*it3).width = e.width();
        (*it3).height = e.height();
        (*it3).samples = e.samples();
        (*it3).bytes = e.bytes();
        (*it3).presenting = (bool)e.presenting();
        ++it3;
      }
    }
    {
      auto span = out._1().allocations();
      __ret_value.allocations.resize(span.size());
      auto it3 = std::begin(__ret_value.allocations);
      for (auto e : span) {
        (*it3).kind = e.kind();
        (*it3).category = (std::string_view)e.category();
        (*it3).windowId = e.windowId();
        (*it3).detail = (std::string_view)e.detail();
        (*it3).bytes = e.bytes();
        (*it3).isImage = (bool)e.isImage();
        (*it3).width = e.width();
        (*it3).height = e.height();
        (*it3).samples = e.samples();
        (*it3).mipLevels = e.mipLevels();
        (*it3).retiring = (bool)e.retiring();
        (*it3).foreign = (bool)e.foreign();
        ++it3;
      }
    }
    {
      auto span = out._1().atlases();
      __ret_value.atlases.resize(span.size());
      auto it3 = std::begin(__ret_value.atlases);
      for (auto e : span) {
        (*it3).kind = e.kind();
        (*it3).page = e.page();
        (*it3).width = e.width();
        (*it3).height = e.height();
        (*it3).bytes = e.bytes();
        (*it3).fillPercent = e.fillPercent();
        (*it3).generation = e.generation();
        (*it3).glyphs = e.glyphs();
        (*it3).faces = e.faces();
        (*it3).slotsUsed = e.slotsUsed();
        (*it3).slotsTotal = e.slotsTotal();
        (*it3).cellSize = e.cellSize();
        (*it3).pngPath = (std::string_view)e.pngPath();
        ++it3;
      }
    }
    {
      auto span = out._1().textures();
      __ret_value.textures.resize(span.size());
      auto it3 = std::begin(__ret_value.textures);
      for (auto e : span) {
        (*it3).key = (std::string_view)e.key();
        (*it3).bytes = e.bytes();
        (*it3).width = e.width();
        (*it3).height = e.height();
        (*it3).refCount = e.refCount();
        (*it3).windowPins = e.windowPins();
        (*it3).atlased = (bool)e.atlased();
        (*it3).dormant = (bool)e.dormant();
        ++it3;
      }
    }
    __ret_value.textureCount = out._1().textureCount();
    __ret_value.textureBytes = out._1().textureBytes();
    __ret_value.dormantBytes = out._1().dormantBytes();
    __ret_value.dormantBudgetBytes = out._1().dormantBudgetBytes();
    __ret_value.cacheHits = out._1().cacheHits();
    __ret_value.cacheEvictions = out._1().cacheEvictions();
  return __ret_value;
}

::nprpc::Task<GpuReport>
Compositor::GetGpuReportAsync(std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 32;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(32);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 47;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M29_Direct out(buf, sizeof(::nprpc::impl::Header));
    GpuReport __ret_value;
    __ret_value.deviceName = (std::string_view)out._1().deviceName();
    __ret_value.samples = out._1().samples();
    __ret_value.maxSamples = out._1().maxSamples();
    __ret_value.heapUsageBytes = out._1().heapUsageBytes();
    __ret_value.heapBudgetBytes = out._1().heapBudgetBytes();
    __ret_value.heapSizeBytes = out._1().heapSizeBytes();
    __ret_value.vmaAllocatedBytes = out._1().vmaAllocatedBytes();
    __ret_value.vmaBlockBytes = out._1().vmaBlockBytes();
    __ret_value.ownBytes = out._1().ownBytes();
    __ret_value.foreignBytes = out._1().foreignBytes();
    __ret_value.retiringBytes = out._1().retiringBytes();
    {
      auto span = out._1().windows();
      __ret_value.windows.resize(span.size());
      auto it3 = std::begin(__ret_value.windows);
      for (auto e : span) {
        (*it3).id = e.id();
        (*it3).title = (std::string_view)e.title();
        (*it3).width = e.width();
        (*it3).height = e.height();
        (*it3).samples = e.samples();
        (*it3).bytes = e.bytes();
        (*it3).presenting = (bool)e.presenting();
        ++it3;
      }
    }
    {
      auto span = out._1().allocations();
      __ret_value.allocations.resize(span.size());
      auto it3 = std::begin(__ret_value.allocations);
      for (auto e : span) {
        (*it3).kind = e.kind();
        (*it3).category = (std::string_view)e.category();
        (*it3).windowId = e.windowId();
        (*it3).detail = (std::string_view)e.detail();
        (*it3).bytes = e.bytes();
        (*it3).isImage = (bool)e.isImage();
        (*it3).width = e.width();
        (*it3).height = e.height();
        (*it3).samples = e.samples();
        (*it3).mipLevels = e.mipLevels();
        (*it3).retiring = (bool)e.retiring();
        (*it3).foreign = (bool)e.foreign();
        ++it3;
      }
    }
    {
      auto span = out._1().atlases();
      __ret_value.atlases.resize(span.size());
      auto it3 = std::begin(__ret_value.atlases);
      for (auto e : span) {
        (*it3).kind = e.kind();
        (*it3).page = e.page();
        (*it3).width = e.width();
        (*it3).height = e.height();
        (*it3).bytes = e.bytes();
        (*it3).fillPercent = e.fillPercent();
        (*it3).generation = e.generation();
        (*it3).glyphs = e.glyphs();
        (*it3).faces = e.faces();
        (*it3).slotsUsed = e.slotsUsed();
        (*it3).slotsTotal = e.slotsTotal();
        (*it3).cellSize = e.cellSize();
        (*it3).pngPath = (std::string_view)e.pngPath();
        ++it3;
      }
    }
    {
      auto span = out._1().textures();
      __ret_value.textures.resize(span.size());
      auto it3 = std::begin(__ret_value.textures);
      for (auto e : span) {
        (*it3).key = (std::string_view)e.key();
        (*it3).bytes = e.bytes();
        (*it3).width = e.width();
        (*it3).height = e.height();
        (*it3).refCount = e.refCount();
        (*it3).windowPins = e.windowPins();
        (*it3).atlased = (bool)e.atlased();
        (*it3).dormant = (bool)e.dormant();
        ++it3;
      }
    }
    __ret_value.textureCount = out._1().textureCount();
    __ret_value.textureBytes = out._1().textureBytes();
    __ret_value.dormantBytes = out._1().dormantBytes();
    __ret_value.dormantBudgetBytes = out._1().dormantBudgetBytes();
    __ret_value.cacheHits = out._1().cacheHits();
    __ret_value.cacheEvictions = out._1().cacheEvictions();
  co_return __ret_value;
}

std::vector<std::string> Compositor::DumpAtlasImages(const std::string& directory) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 40;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(directory.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(40);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 48;
  lava_M19_Direct _(buf,32);
  _._1(directory);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M23_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<std::string> __ret_value;
    {
      auto span = out._1_d()();
      __ret_value.resize(span.size());
      auto it3 = std::begin(__ret_value);
      for (auto e : span) {
        (*it3) = (std::string_view)e();
        ++it3;
      }
    }
  return __ret_value;
}

::nprpc::Task<std::vector<std::string>>
Compositor::DumpAtlasImagesAsync(const std::string& directory, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 40;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(directory.size()));
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(40);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 48;
  lava_M19_Direct _(buf,32);
  _._1(directory);
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M23_Direct out(buf, sizeof(::nprpc::impl::Header));
    std::vector<std::string> __ret_value;
    {
      auto span = out._1_d()();
      __ret_value.resize(span.size());
      auto it3 = std::begin(__ret_value);
      for (auto e : span) {
        (*it3) = (std::string_view)e();
        ++it3;
      }
    }
  co_return __ret_value;
}

void Compositor::SetBackdropBlurRegion(uint32_t surfaceId, float radius, float x, float y, float w, float h, float cornerRadius) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 60;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(60);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 49;
  lava_M30_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = radius;
  _._3() = x;
  _._4() = y;
  _._5() = w;
  _._6() = h;
  _._7() = cornerRadius;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

::nprpc::Task<void>
Compositor::SetBackdropBlurRegionAsync(uint32_t surfaceId, float radius, float x, float y, float w, float h, float cornerRadius, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 60;
  if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(session->ctx(), buf, __wire_size))
    buf.prepare(__wire_size);
  {
    buf.commit(60);
    static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_id = ::nprpc::impl::MessageId::FunctionCall;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->msg_type =::nprpc::impl::MessageType::Request;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(buf, sizeof(::nprpc::impl::Header));
  __ch.object_id() = this->object_id();
  __ch.poa_idx() = this->poa_idx();
  __ch.interface_idx() = interface_idx_;
  __ch.function_idx() = 49;
  lava_M30_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = radius;
  _._3() = x;
  _._4() = y;
  _._5() = w;
  _._6() = h;
  _._7() = cornerRadius;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != 0) {
    throw ::nprpc::Exception("Unknown Error");
  }
}

void ICompositor_Servant::dispatch(::nprpc::SessionContext& ctx, [[maybe_unused]] bool from_parent) {
  assert(ctx.rx_buffer != nullptr);
  auto* header = static_cast<::nprpc::impl::Header*>(ctx.rx_buffer->data().data());
  if (header->msg_id == ::nprpc::impl::MessageId::StreamInitialization) {
    ::nprpc::impl::flat::StreamInit_Direct init(*ctx.rx_buffer, sizeof(::nprpc::impl::Header));
    switch(init.func_idx()) {
      case 11: {
        ::nprpc::StreamReader<WindowListAck> __reader(ctx, init.stream_id());
        ::nprpc::StreamWriter<WindowList> __writer(ctx, init.stream_id());
        ::nprpc::BidiStream<WindowListAck, WindowList> __stream(std::move(__reader), std::move(__writer));
        auto __task = this->SubscribeWindows(std::move(__stream));
        if (__task.done()) __task.rethrow_if_exception();
        ctx.stream_manager->start_task_after_reply(init.stream_id(), std::move(__task));
        break;
      }
      case 12: {
        lava_M2_Direct ia(*ctx.rx_buffer, 48);
        if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
          ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
          break;
        }
        uint32_t __arg1;
  __arg1 = ia._1();

        try {
        ::nprpc::StreamReader<PanelAreaAck> __reader(ctx, init.stream_id());
        ::nprpc::StreamWriter<PanelArea> __writer(ctx, init.stream_id());
        ::nprpc::BidiStream<PanelAreaAck, PanelArea> __stream(std::move(__reader), std::move(__writer));
        auto __task = this->SubscribePanelArea(std::move(__arg1), std::move(__stream));
        if (__task.done()) __task.rethrow_if_exception();
        ctx.stream_manager->start_task_after_reply(init.stream_id(), std::move(__task));
        }
        catch(::lava::SurfaceNotFound& e) {
          assert(ctx.tx_buffer != nullptr);
          auto& obuf = *ctx.tx_buffer;
          obuf.consume(obuf.size());
          std::size_t __wire_size = 24;
          if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
            obuf.prepare(__wire_size);
          obuf.commit(24);
          ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
          oa.__ex_id() = 3;
          oa.surfaceId() = e.surfaceId;
          auto* out_header = static_cast<::nprpc::impl::Header*>(obuf.data().data());
          out_header->size = static_cast<uint32_t>(obuf.size());
          out_header->msg_id = ::nprpc::impl::MessageId::Exception;
          out_header->msg_type = ::nprpc::impl::MessageType::Answer;
          out_header->request_id = static_cast<const ::nprpc::impl::Header*>(ctx.rx_buffer->cdata().data())->request_id;
        }
        break;
      }
      case 13: {
        ::nprpc::StreamReader<ThemeAck> __reader(ctx, init.stream_id());
        ::nprpc::StreamWriter<SystemTheme> __writer(ctx, init.stream_id());
        ::nprpc::BidiStream<ThemeAck, SystemTheme> __stream(std::move(__reader), std::move(__writer));
        auto __task = this->SubscribeSystemTheme(std::move(__stream));
        if (__task.done()) __task.rethrow_if_exception();
        ctx.stream_manager->start_task_after_reply(init.stream_id(), std::move(__task));
        break;
      }
      case 33: {
        ::nprpc::StreamReader<FocusAck> __reader(ctx, init.stream_id());
        ::nprpc::StreamWriter<ActiveWindow> __writer(ctx, init.stream_id());
        ::nprpc::BidiStream<FocusAck, ActiveWindow> __stream(std::move(__reader), std::move(__writer));
        auto __task = this->SubscribeActiveWindow(std::move(__stream));
        if (__task.done()) __task.rethrow_if_exception();
        ctx.stream_manager->start_task_after_reply(init.stream_id(), std::move(__task));
        break;
      }
      case 38: {
        lava_M2_Direct ia(*ctx.rx_buffer, 48);
        if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
          ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
          break;
        }
        uint32_t __arg1;
  __arg1 = ia._1();

        try {
        ::nprpc::StreamReader<InputAck> __reader(ctx, init.stream_id());
        ::nprpc::StreamWriter<InputEvent> __writer(ctx, init.stream_id());
        ::nprpc::BidiStream<InputAck, InputEvent> __stream(std::move(__reader), std::move(__writer));
        auto __task = this->SubscribeInput(std::move(__arg1), std::move(__stream));
        if (__task.done()) __task.rethrow_if_exception();
        ctx.stream_manager->start_task_after_reply(init.stream_id(), std::move(__task));
        }
        catch(::lava::SurfaceNotFound& e) {
          assert(ctx.tx_buffer != nullptr);
          auto& obuf = *ctx.tx_buffer;
          obuf.consume(obuf.size());
          std::size_t __wire_size = 24;
          if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
            obuf.prepare(__wire_size);
          obuf.commit(24);
          ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
          oa.__ex_id() = 3;
          oa.surfaceId() = e.surfaceId;
          auto* out_header = static_cast<::nprpc::impl::Header*>(obuf.data().data());
          out_header->size = static_cast<uint32_t>(obuf.size());
          out_header->msg_id = ::nprpc::impl::MessageId::Exception;
          out_header->msg_type = ::nprpc::impl::MessageType::Answer;
          out_header->request_id = static_cast<const ::nprpc::impl::Header*>(ctx.rx_buffer->cdata().data())->request_id;
        }
        break;
      }
      default:
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_UnknownFunctionIdx);
        break;
    }
    return;
  }
  ::nprpc::impl::flat::CallHeader_Direct __ch(*ctx.rx_buffer, sizeof(::nprpc::impl::Header));
  switch(__ch.function_idx()) {
    case 0: {
      assert(ctx.rx_buffer != nullptr);
      lava_M1_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1S2Fu323Fu324Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      uint32_t __ret_val;
      try {
        __ret_val = RegisterFont(ia._1(), ia._2(), ia._3(), ia._4());
      }
      catch(::lava::FontNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 28;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.path.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(28);
        ::lava::flat::FontNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 0;
        oa.path(e.path);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, 20))
        obuf.prepare(20);
      obuf.commit(20);
      lava_M2_Direct oa(obuf,16);
        oa._1() = __ret_val;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 1: {
      assert(ctx.rx_buffer != nullptr);
      lava_M3_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1S2Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      ImageInfo __ret_val;
      try {
        __ret_val = RegisterImage(ia._1(), ia._2());
      }
      catch(::lava::ImageNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 28;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.path.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(28);
        ::lava::flat::ImageNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 1;
        oa.path(e.path);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, 28))
        obuf.prepare(28);
      obuf.commit(28);
      lava_M4_Direct oa(obuf,16);
        memcpy(oa._1().__data(), &__ret_val, 12);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 2: {
      assert(ctx.rx_buffer != nullptr);
      lava_M5_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1VFu82Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      ImageInfo __ret_val;
      try {
        __ret_val = RegisterImageData(ia._1(), ia._2());
      }
      catch(::lava::ImageNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 28;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.path.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(28);
        ::lava::flat::ImageNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 1;
        oa.path(e.path);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, 28))
        obuf.prepare(28);
      obuf.commit(28);
      lava_M4_Direct oa(obuf,16);
        memcpy(oa._1().__data(), &__ret_val, 12);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 3: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      ReleaseImage(ia._1());
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 4: {
      assert(ctx.rx_buffer != nullptr);
      lava_M6_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1S2Fu323Fu324S5EWindowFrame6S(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      uint32_t __ret_val;
      try {
        __ret_val = CreateSurface(ia._1(), ia._2(), ia._3(), ia._4(), ia._5(), ia._6());
      }
      catch(::lava::ArenaNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 28;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.arenaId.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(28);
        ::lava::flat::ArenaNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 2;
        oa.arenaId(e.arenaId);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, 20))
        obuf.prepare(20);
      obuf.commit(20);
      lava_M2_Direct oa(obuf,16);
        oa._1() = __ret_val;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 5: {
      assert(ctx.rx_buffer != nullptr);
      lava_M7_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1S2EPanelEdge3Fu324Fb5S6S(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      uint32_t __ret_val;
      try {
        __ret_val = CreatePanel(ia._1(), ia._2(), ia._3(), ia._4(), ia._5(), ia._6());
      }
      catch(::lava::ArenaNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 28;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.arenaId.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(28);
        ::lava::flat::ArenaNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 2;
        oa.arenaId(e.arenaId);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, 20))
        obuf.prepare(20);
      obuf.commit(20);
      lava_M2_Direct oa(obuf,16);
        oa._1() = __ret_val;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 6: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        BeginMove(ia._1());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 7: {
      assert(ctx.rx_buffer != nullptr);
      lava_M8_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu322Fu323Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetMinSize(ia._1(), ia._2(), ia._3());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 8: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      bool __ret_val;
      try {
        __ret_val = ToggleMaximize(ia._1());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, 17))
        obuf.prepare(17);
      obuf.commit(17);
      lava_M9_Direct oa(obuf,16);
        oa._1() = __ret_val;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 9: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        Minimize(ia._1());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 10: {
      assert(ctx.rx_buffer != nullptr);
      lava_M8_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu322Fu323Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetPanelThickness(ia._1(), ia._2(), ia._3());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 14: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        ActivateWindow(ia._1());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 15: {
      assert(ctx.rx_buffer != nullptr);
      lava_M10_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu322Fi323Fi324Fu325Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetInputRegion(ia._1(), ia._2(), ia._3(), ia._4(), ia._5());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 16: {
      assert(ctx.rx_buffer != nullptr);
      lava_M11_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu322ECursorShape(*ctx.rx_buffer, ia) ) {
        break;
      }
      SetCursor(ia._1(), ia._2());
      break;
    }
    case 17: {
      Appearance __ret_val;
      __ret_val = GetAppearance();
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, 32))
        obuf.prepare(32);
      obuf.commit(32);
      lava_M12_Direct oa(obuf,16);
      memcpy(oa._1().__data(), &__ret_val, 16);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 18: {
      assert(ctx.rx_buffer != nullptr);
      lava_M12_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Appearance_1(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetAppearance(ia._1());
      }
      catch(::lava::SettingsWriteFailed& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 36;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.path.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.reason.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(36);
        ::lava::flat::SettingsWriteFailed_Direct oa(obuf,16);
        oa.__ex_id() = 6;
        oa.path(e.path);
        oa.reason(e.reason);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 19: {
      SystemTheme __ret_val;
      __ret_val = GetSystemTheme();
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 28;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.name.size()));
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(28);
      lava_M13_Direct oa(obuf,16);
      oa._1().serial() = __ret_val.serial;
      oa._1().name(__ret_val.name);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 20: {
      assert(ctx.rx_buffer != nullptr);
      lava_M13_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1SystemTheme_1(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetSystemTheme(ia._1());
      }
      catch(::lava::SettingsWriteFailed& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 36;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.path.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.reason.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(36);
        ::lava::flat::SettingsWriteFailed_Direct oa(obuf,16);
        oa.__ex_id() = 6;
        oa.path(e.path);
        oa.reason(e.reason);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 21: {
      Wallpaper __ret_val;
      __ret_val = GetWallpaper();
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 44;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.mode.size()));
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.path.size()));
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.fit.size()));
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(44);
      lava_M14_Direct oa(obuf,16);
      oa._1().mode(__ret_val.mode);
      oa._1().color() = __ret_val.color;
      oa._1().path(__ret_val.path);
      oa._1().fit(__ret_val.fit);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 22: {
      assert(ctx.rx_buffer != nullptr);
      lava_M14_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Wallpaper_1(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetWallpaper(ia._1());
      }
      catch(::lava::WallpaperUnreadable& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 36;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.path.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.reason.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(36);
        ::lava::flat::WallpaperUnreadable_Direct oa(obuf,16);
        oa.__ex_id() = 7;
        oa.path(e.path);
        oa.reason(e.reason);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      catch(::lava::SettingsWriteFailed& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 36;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.path.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.reason.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(36);
        ::lava::flat::SettingsWriteFailed_Direct oa(obuf,16);
        oa.__ex_id() = 6;
        oa.path(e.path);
        oa.reason(e.reason);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 23: {
      KeyboardSettings __ret_val;
      __ret_val = GetKeyboard();
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 72;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.layout.size()));
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.variant.size()));
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.options.size()));
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.model.size()));
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.rules.size()));
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.modKey.size()));
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(72);
      lava_M15_Direct oa(obuf,16);
      oa._1().layout(__ret_val.layout);
      oa._1().variant(__ret_val.variant);
      oa._1().options(__ret_val.options);
      oa._1().model(__ret_val.model);
      oa._1().rules(__ret_val.rules);
      oa._1().repeatRate() = __ret_val.repeatRate;
      oa._1().repeatDelay() = __ret_val.repeatDelay;
      oa._1().modKey(__ret_val.modKey);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 24: {
      assert(ctx.rx_buffer != nullptr);
      lava_M15_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1KeyboardSettings_1(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetKeyboard(ia._1());
      }
      catch(::lava::SettingsWriteFailed& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 36;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.path.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.reason.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(36);
        ::lava::flat::SettingsWriteFailed_Direct oa(obuf,16);
        oa.__ex_id() = 6;
        oa.path(e.path);
        oa.reason(e.reason);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 25: {
      std::vector<KeyboardLayout> __ret_val;
      __ret_val = ListKeyboardLayouts();
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 24;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 4, static_cast<std::size_t>(__ret_val.size()) * 24);
      for (auto const& __m_elem : __ret_val) {
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.code.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.variant.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.description.size()));
      }
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(24);
      lava_M16_Direct oa(obuf,16);
      oa._1(static_cast<uint32_t>(__ret_val.size()));
      {
        auto span = oa._1();
        auto it = __ret_val.begin();
        for (auto e : span) {
          auto __ptr = ::nprpc::make_wrapper1(*it);
            e.code(__ptr->code);
            e.variant(__ptr->variant);
            e.description(__ptr->description);
          ++it;
        }
      }
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 26: {
      std::vector<KeyBinding> __ret_val;
      __ret_val = ListKeyBindings();
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 24;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 4, static_cast<std::size_t>(__ret_val.size()) * 32);
      for (auto const& __m_elem : __ret_val) {
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.modifiers.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.key.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.action.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.description.size()));
      }
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(24);
      lava_M17_Direct oa(obuf,16);
      oa._1(static_cast<uint32_t>(__ret_val.size()));
      {
        auto span = oa._1();
        auto it = __ret_val.begin();
        for (auto e : span) {
          auto __ptr = ::nprpc::make_wrapper1(*it);
            e.modifiers(__ptr->modifiers);
            e.key(__ptr->key);
            e.action(__ptr->action);
            e.description(__ptr->description);
          ++it;
        }
      }
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 27: {
      std::vector<OutputInfo> __ret_val;
      __ret_val = ListOutputs();
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 24;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 4, static_cast<std::size_t>(__ret_val.size()) * 52);
      for (auto const& __m_elem : __ret_val) {
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.name.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.description.size()));
      }
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(24);
      lava_M18_Direct oa(obuf,16);
      oa._1(static_cast<uint32_t>(__ret_val.size()));
      {
        auto span = oa._1();
        auto it = __ret_val.begin();
        for (auto e : span) {
          auto __ptr = ::nprpc::make_wrapper1(*it);
            e.name(__ptr->name);
            e.description(__ptr->description);
            e.enabled() = __ptr->enabled;
            e.x() = __ptr->x;
            e.y() = __ptr->y;
            e.width() = __ptr->width;
            e.height() = __ptr->height;
            e.refresh() = __ptr->refresh;
            e.scale() = __ptr->scale;
            e.transform() = __ptr->transform;
            e.primary() = __ptr->primary;
          ++it;
        }
      }
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 28: {
      assert(ctx.rx_buffer != nullptr);
      lava_M19_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1S(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      std::vector<OutputMode> __ret_val;
      try {
        __ret_val = ListOutputModes(ia._1());
      }
      catch(::lava::OutputNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 28;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.name.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(28);
        ::lava::flat::OutputNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 5;
        oa.name(e.name);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 24;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 4, static_cast<std::size_t>(__ret_val.size()) * 16);
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(24);
      lava_M20_Direct oa(obuf,16);
      oa._1(static_cast<uint32_t>(__ret_val.size()));
      memcpy(oa._1().data(), __ret_val.data(), __ret_val.size() * 16);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 29: {
      assert(ctx.rx_buffer != nullptr);
      lava_M21_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1OutputRequest_1(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetOutput(ia._1());
      }
      catch(::lava::OutputNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 28;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.name.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(28);
        ::lava::flat::OutputNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 5;
        oa.name(e.name);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      catch(::lava::SettingsWriteFailed& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 36;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.path.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.reason.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(36);
        ::lava::flat::SettingsWriteFailed_Direct oa(obuf,16);
        oa.__ex_id() = 6;
        oa.path(e.path);
        oa.reason(e.reason);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 30: {
      assert(ctx.rx_buffer != nullptr);
      lava_M19_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1S(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetPrimaryOutput(ia._1());
      }
      catch(::lava::OutputNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 28;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.name.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(28);
        ::lava::flat::OutputNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 5;
        oa.name(e.name);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      catch(::lava::SettingsWriteFailed& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 36;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.path.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.reason.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(36);
        ::lava::flat::SettingsWriteFailed_Direct oa(obuf,16);
        oa.__ex_id() = 6;
        oa.path(e.path);
        oa.reason(e.reason);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 31: {
      std::string __ret_val;
      __ret_val = GetArrangement();
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 24;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.size()));
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(24);
      lava_M19_Direct oa(obuf,16);
      oa._1(__ret_val);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 32: {
      assert(ctx.rx_buffer != nullptr);
      lava_M19_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1S(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetArrangement(ia._1());
      }
      catch(::lava::SettingsWriteFailed& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 36;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.path.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.reason.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(36);
        ::lava::flat::SettingsWriteFailed_Direct oa(obuf,16);
        oa.__ex_id() = 6;
        oa.path(e.path);
        oa.reason(e.reason);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 34: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        DestroySurface(ia._1());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 35: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        break;
      }
      Present(ia._1());
      break;
    }
    case 36: {
      assert(ctx.rx_buffer != nullptr);
      lava_M22_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu322Ff323Ff32(*ctx.rx_buffer, ia) ) {
        break;
      }
      ScrollUnclaimed(ia._1(), ia._2(), ia._3());
      break;
    }
    case 37: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        break;
      }
      Heartbeat(ia._1());
      break;
    }
    case 39: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      std::vector<std::string> __ret_val;
      try {
        __ret_val = TakeDroppedPaths(ia._1());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 24;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 4, static_cast<std::size_t>(__ret_val.size()) * 8);
      for (auto const& __m_elem : __ret_val) {
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.size()));
      }
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(24);
      lava_M23_Direct oa(obuf,16);
      oa._1(static_cast<uint32_t>(__ret_val.size()));
      {
        auto vdir = oa._1_d();
        auto it = __ret_val.begin();
        auto span = vdir();
        for (auto e : span) {
          e = *it;
          ++it;
        }
      }
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 40: {
      assert(ctx.rx_buffer != nullptr);
      lava_M24_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu322Fi323Fi324Fi325Fi326Fi32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      Capture __ret_val;
      try {
        __ret_val = CaptureSurface(ia._1(), ia._2(), ia._3(), ia._4(), ia._5(), ia._6());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      catch(::lava::CaptureFailed& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::CaptureFailed_Direct oa(obuf,16);
        oa.__ex_id() = 4;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 32;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.png.size()) * 1);
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(32);
      lava_M25_Direct oa(obuf,16);
      oa._1().width() = __ret_val.width;
      oa._1().height() = __ret_val.height;
      oa._1().png(static_cast<uint32_t>(__ret_val.png.size()));
      memcpy(oa._1().png().data(), __ret_val.png.data(), __ret_val.png.size() * 1);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 41: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      std::string __ret_val;
      try {
        __ret_val = GetClipboard(ia._1());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 24;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.size()));
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(24);
      lava_M19_Direct oa(obuf,16);
      oa._1(__ret_val);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 42: {
      assert(ctx.rx_buffer != nullptr);
      lava_M26_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu322S(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetClipboard(ia._1(), ia._2());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 43: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      std::string __ret_val;
      try {
        __ret_val = GetPrimarySelection(ia._1());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 24;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.size()));
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(24);
      lava_M19_Direct oa(obuf,16);
      oa._1(__ret_val);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 44: {
      assert(ctx.rx_buffer != nullptr);
      lava_M26_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu322S(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetPrimarySelection(ia._1(), ia._2());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 45: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      std::vector<uint8_t> __ret_val;
      try {
        __ret_val = GetClipboardPng(ia._1());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 24;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.size()) * 1);
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(24);
      lava_M27_Direct oa(obuf,16);
      oa._1(static_cast<uint32_t>(__ret_val.size()));
      memcpy(oa._1().data(), __ret_val.data(), __ret_val.size() * 1);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 46: {
      assert(ctx.rx_buffer != nullptr);
      lava_M28_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu322Ff32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetBackdropBlur(ia._1(), ia._2());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    case 47: {
      GpuReport __ret_val;
      __ret_val = GetGpuReport();
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 176;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__ret_val.deviceName.size()));
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 8, static_cast<std::size_t>(__ret_val.windows.size()) * 40);
      for (auto const& __m_elem : __ret_val.windows) {
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.title.size()));
      }
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 8, static_cast<std::size_t>(__ret_val.allocations.size()) * 56);
      for (auto const& __m_elem : __ret_val.allocations) {
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.category.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.detail.size()));
      }
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 8, static_cast<std::size_t>(__ret_val.atlases.size()) * 64);
      for (auto const& __m_elem : __ret_val.atlases) {
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.pngPath.size()));
      }
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 8, static_cast<std::size_t>(__ret_val.textures.size()) * 40);
      for (auto const& __m_elem : __ret_val.textures) {
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.key.size()));
      }
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(176);
      lava_M29_Direct oa(obuf,16);
      oa._1().deviceName(__ret_val.deviceName);
      oa._1().samples() = __ret_val.samples;
      oa._1().maxSamples() = __ret_val.maxSamples;
      oa._1().heapUsageBytes() = __ret_val.heapUsageBytes;
      oa._1().heapBudgetBytes() = __ret_val.heapBudgetBytes;
      oa._1().heapSizeBytes() = __ret_val.heapSizeBytes;
      oa._1().vmaAllocatedBytes() = __ret_val.vmaAllocatedBytes;
      oa._1().vmaBlockBytes() = __ret_val.vmaBlockBytes;
      oa._1().ownBytes() = __ret_val.ownBytes;
      oa._1().foreignBytes() = __ret_val.foreignBytes;
      oa._1().retiringBytes() = __ret_val.retiringBytes;
      oa._1().windows(static_cast<uint32_t>(__ret_val.windows.size()));
      {
        auto span = oa._1().windows();
        auto it = __ret_val.windows.begin();
        for (auto e : span) {
          auto __ptr = ::nprpc::make_wrapper1(*it);
            e.id() = __ptr->id;
            e.title(__ptr->title);
            e.width() = __ptr->width;
            e.height() = __ptr->height;
            e.samples() = __ptr->samples;
            e.bytes() = __ptr->bytes;
            e.presenting() = __ptr->presenting;
          ++it;
        }
      }
      oa._1().allocations(static_cast<uint32_t>(__ret_val.allocations.size()));
      {
        auto span = oa._1().allocations();
        auto it = __ret_val.allocations.begin();
        for (auto e : span) {
          auto __ptr = ::nprpc::make_wrapper1(*it);
            e.kind() = __ptr->kind;
            e.category(__ptr->category);
            e.windowId() = __ptr->windowId;
            e.detail(__ptr->detail);
            e.bytes() = __ptr->bytes;
            e.isImage() = __ptr->isImage;
            e.width() = __ptr->width;
            e.height() = __ptr->height;
            e.samples() = __ptr->samples;
            e.mipLevels() = __ptr->mipLevels;
            e.retiring() = __ptr->retiring;
            e.foreign() = __ptr->foreign;
          ++it;
        }
      }
      oa._1().atlases(static_cast<uint32_t>(__ret_val.atlases.size()));
      {
        auto span = oa._1().atlases();
        auto it = __ret_val.atlases.begin();
        for (auto e : span) {
          auto __ptr = ::nprpc::make_wrapper1(*it);
            e.kind() = __ptr->kind;
            e.page() = __ptr->page;
            e.width() = __ptr->width;
            e.height() = __ptr->height;
            e.bytes() = __ptr->bytes;
            e.fillPercent() = __ptr->fillPercent;
            e.generation() = __ptr->generation;
            e.glyphs() = __ptr->glyphs;
            e.faces() = __ptr->faces;
            e.slotsUsed() = __ptr->slotsUsed;
            e.slotsTotal() = __ptr->slotsTotal;
            e.cellSize() = __ptr->cellSize;
            e.pngPath(__ptr->pngPath);
          ++it;
        }
      }
      oa._1().textures(static_cast<uint32_t>(__ret_val.textures.size()));
      {
        auto span = oa._1().textures();
        auto it = __ret_val.textures.begin();
        for (auto e : span) {
          auto __ptr = ::nprpc::make_wrapper1(*it);
            e.key(__ptr->key);
            e.bytes() = __ptr->bytes;
            e.width() = __ptr->width;
            e.height() = __ptr->height;
            e.refCount() = __ptr->refCount;
            e.windowPins() = __ptr->windowPins;
            e.atlased() = __ptr->atlased;
            e.dormant() = __ptr->dormant;
          ++it;
        }
      }
      oa._1().textureCount() = __ret_val.textureCount;
      oa._1().textureBytes() = __ret_val.textureBytes;
      oa._1().dormantBytes() = __ret_val.dormantBytes;
      oa._1().dormantBudgetBytes() = __ret_val.dormantBudgetBytes;
      oa._1().cacheHits() = __ret_val.cacheHits;
      oa._1().cacheEvictions() = __ret_val.cacheEvictions;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 48: {
      assert(ctx.rx_buffer != nullptr);
      lava_M19_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1S(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      std::vector<std::string> __ret_val;
      try {
        __ret_val = DumpAtlasImages(ia._1());
      }
      catch(::lava::AtlasDumpFailed& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 36;
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.directory.size()));
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(e.reason.size()));
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(36);
        ::lava::flat::AtlasDumpFailed_Direct oa(obuf,16);
        oa.__ex_id() = 8;
        oa.directory(e.directory);
        oa.reason(e.reason);
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      assert(ctx.tx_buffer != nullptr);
      auto& obuf = *ctx.tx_buffer;
      obuf.consume(obuf.size());
      std::size_t __wire_size = 24;
      __wire_size = ::nprpc::flat::grow_size(__wire_size, 4, static_cast<std::size_t>(__ret_val.size()) * 8);
      for (auto const& __m_elem : __ret_val) {
        __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(__m_elem.size()));
      }
      if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
        obuf.prepare(__wire_size);
      obuf.commit(24);
      lava_M23_Direct oa(obuf,16);
      oa._1(static_cast<uint32_t>(__ret_val.size()));
      {
        auto vdir = oa._1_d();
        auto it = __ret_val.begin();
        auto span = vdir();
        for (auto e : span) {
          e = *it;
          ++it;
        }
      }
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 49: {
      assert(ctx.rx_buffer != nullptr);
      lava_M30_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu322Ff323Ff324Ff325Ff326Ff327Ff32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      try {
        SetBackdropBlurRegion(ia._1(), ia._2(), ia._3(), ia._4(), ia._5(), ia._6(), ia._7());
      }
      catch(::lava::SurfaceNotFound& e) {
        assert(ctx.tx_buffer != nullptr);
        auto& obuf = *ctx.tx_buffer;
        obuf.consume(obuf.size());
        std::size_t __wire_size = 24;
        if (!::nprpc::impl::g_rpc->prepare_zero_copy_buffer(ctx, obuf, __wire_size))
          obuf.prepare(__wire_size);
        obuf.commit(24);
        ::lava::flat::SurfaceNotFound_Direct oa(obuf,16);
        oa.__ex_id() = 3;
        oa.surfaceId() = e.surfaceId;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::Exception;
        static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
        return;
      }
      ::nprpc::impl::make_simple_answer(ctx, nprpc::impl::MessageId::Success);
      break;
    }
    default:
      ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_UnknownFunctionIdx);
  }
}

} // module lava

void lava_throw_exception(::nprpc::flat_buffer& buf) { 
  switch(*(uint32_t*)( (char*)buf.data().data() + sizeof(::nprpc::impl::Header)) ) {
  case 0:
  {
    ::lava::flat::FontNotFound_Direct ex_flat(buf, sizeof(::nprpc::impl::Header));
    ::lava::FontNotFound ex;
  ex.path = (std::string_view)ex_flat.path();
    throw ex;
  }
  case 1:
  {
    ::lava::flat::ImageNotFound_Direct ex_flat(buf, sizeof(::nprpc::impl::Header));
    ::lava::ImageNotFound ex;
  ex.path = (std::string_view)ex_flat.path();
    throw ex;
  }
  case 2:
  {
    ::lava::flat::ArenaNotFound_Direct ex_flat(buf, sizeof(::nprpc::impl::Header));
    ::lava::ArenaNotFound ex;
  ex.arenaId = (std::string_view)ex_flat.arenaId();
    throw ex;
  }
  case 3:
  {
    ::lava::flat::SurfaceNotFound_Direct ex_flat(buf, sizeof(::nprpc::impl::Header));
    ::lava::SurfaceNotFound ex;
  ex.surfaceId = ex_flat.surfaceId();
    throw ex;
  }
  case 4:
  {
    ::lava::flat::CaptureFailed_Direct ex_flat(buf, sizeof(::nprpc::impl::Header));
    ::lava::CaptureFailed ex;
  ex.surfaceId = ex_flat.surfaceId();
    throw ex;
  }
  case 5:
  {
    ::lava::flat::OutputNotFound_Direct ex_flat(buf, sizeof(::nprpc::impl::Header));
    ::lava::OutputNotFound ex;
  ex.name = (std::string_view)ex_flat.name();
    throw ex;
  }
  case 6:
  {
    ::lava::flat::SettingsWriteFailed_Direct ex_flat(buf, sizeof(::nprpc::impl::Header));
    ::lava::SettingsWriteFailed ex;
  ex.path = (std::string_view)ex_flat.path();
  ex.reason = (std::string_view)ex_flat.reason();
    throw ex;
  }
  case 7:
  {
    ::lava::flat::WallpaperUnreadable_Direct ex_flat(buf, sizeof(::nprpc::impl::Header));
    ::lava::WallpaperUnreadable ex;
  ex.path = (std::string_view)ex_flat.path();
  ex.reason = (std::string_view)ex_flat.reason();
    throw ex;
  }
  case 8:
  {
    ::lava::flat::AtlasDumpFailed_Direct ex_flat(buf, sizeof(::nprpc::impl::Header));
    ::lava::AtlasDumpFailed ex;
  ex.directory = (std::string_view)ex_flat.directory();
  ex.reason = (std::string_view)ex_flat.reason();
    throw ex;
  }
  default:
    throw std::runtime_error("unknown rpc exception");
  }
}
