#include "lava.hpp"
#include <nprpc/impl/nprpc_impl.hpp>

void lava_throw_exception(::nprpc::flat_buffer& buf);

namespace lava {

namespace {
struct lava_M1 {
  ::nprpc::flat::String _1;
  float _2;
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
  const float& _2() const noexcept { return base()._2;}
  float& _2() noexcept { return base()._2;}
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
};

struct lava_M7 {
  ::nprpc::flat::String _1;
  ::lava::PanelEdge _2;
  uint32_t _3;
  ::nprpc::flat::Boolean _4;
  ::nprpc::flat::String _5;
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
};

struct lava_M8 {
  uint32_t _1;
  float _2;
  float _3;
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
  const float& _2() const noexcept { return base()._2;}
  float& _2() noexcept { return base()._2;}
  const float& _3() const noexcept { return base()._3;}
  float& _3() noexcept { return base()._3;}
};

struct lava_M9 {
  ::nprpc::flat::Vector<::nprpc::flat::String> _1;
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
  void _1(std::uint32_t elements_size) { new (&base()._1) ::nprpc::flat::Vector<::nprpc::flat::String>(buffer_, elements_size); }
  auto _1_d() noexcept { return ::nprpc::flat::Vector_Direct2<::nprpc::flat::String,::nprpc::flat::String_Direct1>(buffer_, offset_ + offsetof(lava_M9, _1)); }
};

struct lava_M10 {
  uint32_t _1;
  int32_t _2;
  int32_t _3;
  int32_t _4;
  int32_t _5;
  int32_t _6;
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
  const int32_t& _4() const noexcept { return base()._4;}
  int32_t& _4() noexcept { return base()._4;}
  const int32_t& _5() const noexcept { return base()._5;}
  int32_t& _5() noexcept { return base()._5;}
  const int32_t& _6() const noexcept { return base()._6;}
  int32_t& _6() noexcept { return base()._6;}
};

struct lava_M11 {
  ::lava::flat::Capture _1;
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
  auto _1() noexcept { return ::lava::flat::Capture_Direct(buffer_, offset_ + offsetof(lava_M11, _1)); }
};

struct lava_M12 {
  ::nprpc::flat::String _1;
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
  void _1(const char* str) { new (&base()._1) ::nprpc::flat::String(buffer_, str); }
  void _1(const std::string& str) { new (&base()._1) ::nprpc::flat::String(buffer_, str); }
  auto _1() noexcept { return (::nprpc::flat::Span<char>)base()._1; }
  auto _1() const noexcept { return (::nprpc::flat::Span<const char>)base()._1; }
  auto _1_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(lava_M12, _1)); }
};

struct lava_M13 {
  uint32_t _1;
  ::nprpc::flat::String _2;
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
  const uint32_t& _1() const noexcept { return base()._1;}
  uint32_t& _1() noexcept { return base()._1;}
  void _2(const char* str) { new (&base()._2) ::nprpc::flat::String(buffer_, str); }
  void _2(const std::string& str) { new (&base()._2) ::nprpc::flat::String(buffer_, str); }
  auto _2() noexcept { return (::nprpc::flat::Span<char>)base()._2; }
  auto _2() const noexcept { return (::nprpc::flat::Span<const char>)base()._2; }
  auto _2_d() noexcept { return ::nprpc::flat::String_Direct1(buffer_, offset_ + offsetof(lava_M13, _2)); }
};


bool check_1S2Ff32(::nprpc::flat_buffer& buf, lava_M1_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 12) goto check_failed;
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
bool check_1S2Fu323Fu324S(::nprpc::flat_buffer& buf, lava_M6_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 24) goto check_failed;
  {
    if(!ia._1_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  {
    if(!ia._4_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  return true;
check_failed:
  return false;
}
bool check_1S2EPanelEdge3Fu324Fb5S(::nprpc::flat_buffer& buf, lava_M7_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 28) goto check_failed;
  {
    if(!ia._1_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  {
    if(!ia._5_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  return true;
check_failed:
  return false;
}
bool check_1Fu322Ff323Ff32(::nprpc::flat_buffer& buf, lava_M8_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 12) goto check_failed;
  return true;
check_failed:
  return false;
}
bool check_1Fu322Fi323Fi324Fi325Fi326Fi32(::nprpc::flat_buffer& buf, lava_M10_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 24) goto check_failed;
  return true;
check_failed:
  return false;
}
bool check_1Fu322S(::nprpc::flat_buffer& buf, lava_M13_Direct& ia) {
  if (static_cast<std::uint32_t>(buf.size()) < ia.offset() + 12) goto check_failed;
  {
    if(!ia._2_d()._check_size_align(static_cast<std::uint32_t>(buf.size()))) goto check_failed;
  }
  return true;
check_failed:
  return false;
}
} // 

uint32_t Compositor::RegisterFont(const std::string& path, float pixelSize) {
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
  __ch.function_idx() = 0;
  lava_M1_Direct _(buf,32);
  _._1(path);
  _._2() = pixelSize;
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
Compositor::RegisterFontAsync(const std::string& path, float pixelSize, std::stop_token st) {
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
  __ch.function_idx() = 0;
  lava_M1_Direct _(buf,32);
  _._1(path);
  _._2() = pixelSize;
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

uint32_t Compositor::CreateSurface(const std::string& arenaId, uint32_t width, uint32_t height, const std::string& title) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 56;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(arenaId.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(title.size()));
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
  __ch.function_idx() = 4;
  lava_M6_Direct _(buf,32);
  _._1(arenaId);
  _._2() = width;
  _._3() = height;
  _._4(title);
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
Compositor::CreateSurfaceAsync(const std::string& arenaId, uint32_t width, uint32_t height, const std::string& title, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 56;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(arenaId.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(title.size()));
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
  __ch.function_idx() = 4;
  lava_M6_Direct _(buf,32);
  _._1(arenaId);
  _._2() = width;
  _._3() = height;
  _._4(title);
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

uint32_t Compositor::CreatePanel(const std::string& arenaId, const PanelEdge& edge, uint32_t thickness, bool reserve, const std::string& title) {
  auto& __arena = ::nprpc::impl::tls_bump_arena();
  __arena.reset();
  ::nprpc::flat_buffer buf;
  buf.set_arena(&__arena);
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 60;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(arenaId.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(title.size()));
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
  __ch.function_idx() = 5;
  lava_M7_Direct _(buf,32);
  _._1(arenaId);
  _._2() = edge;
  _._3() = thickness;
  _._4() = reserve;
  _._5(title);
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
Compositor::CreatePanelAsync(const std::string& arenaId, const PanelEdge& edge, uint32_t thickness, bool reserve, const std::string& title, std::stop_token st) {
  if (st.stop_requested()) throw nprpc::OperationCancelled();
  ::nprpc::flat_buffer buf;
  auto session = ::nprpc::impl::g_rpc->get_session(this->get_endpoint());
  std::size_t __wire_size = 60;
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(arenaId.size()));
  __wire_size = ::nprpc::flat::grow_size(__wire_size, 1, static_cast<std::size_t>(title.size()));
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
  __ch.function_idx() = 5;
  lava_M7_Direct _(buf,32);
  _._1(arenaId);
  _._2() = edge;
  _._3() = thickness;
  _._4() = reserve;
  _._5(title);
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
  __ch.function_idx() = 7;
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
  __ch.function_idx() = 8;
  lava_M8_Direct _(buf,32);
  _._1() = surfaceId;
  _._2() = dx;
  _._3() = dy;
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
  init.func_idx() = 9;
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
  __ch.function_idx() = 10;
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
  __ch.function_idx() = 10;
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
  __ch.function_idx() = 11;
  lava_M10_Direct _(buf,32);
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
  lava_M11_Direct out(buf, sizeof(::nprpc::impl::Header));
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
  __ch.function_idx() = 11;
  lava_M10_Direct _(buf,32);
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
  lava_M11_Direct out(buf, sizeof(::nprpc::impl::Header));
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
  __ch.function_idx() = 12;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  session->send_receive(buf, this->get_timeout());
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M12_Direct out(buf, sizeof(::nprpc::impl::Header));
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
  __ch.function_idx() = 12;
  lava_M2_Direct _(buf,32);
  _._1() = surfaceId;
  static_cast<::nprpc::impl::Header*>(buf.data().data())->size = static_cast<uint32_t>(buf.size());
  co_await session->send_receive_coro(buf, this->get_timeout(), std::move(st));
  auto std_reply = ::nprpc::impl::handle_standart_reply(buf);
  if (std_reply == 1) lava_throw_exception(buf);
  if (std_reply != -1) {
    throw ::nprpc::Exception("Unknown Error");
  }
  lava_M12_Direct out(buf, sizeof(::nprpc::impl::Header));
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
  __ch.function_idx() = 13;
  lava_M13_Direct _(buf,32);
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
  __ch.function_idx() = 13;
  lava_M13_Direct _(buf,32);
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

void ICompositor_Servant::dispatch(::nprpc::SessionContext& ctx, [[maybe_unused]] bool from_parent) {
  assert(ctx.rx_buffer != nullptr);
  auto* header = static_cast<::nprpc::impl::Header*>(ctx.rx_buffer->data().data());
  if (header->msg_id == ::nprpc::impl::MessageId::StreamInitialization) {
    ::nprpc::impl::flat::StreamInit_Direct init(*ctx.rx_buffer, sizeof(::nprpc::impl::Header));
    switch(init.func_idx()) {
      case 9: {
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
      if ( !check_1S2Ff32(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      uint32_t __ret_val;
      try {
        __ret_val = RegisterFont(ia._1(), ia._2());
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
      if ( !check_1S2Fu323Fu324S(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      uint32_t __ret_val;
      try {
        __ret_val = CreateSurface(ia._1(), ia._2(), ia._3(), ia._4());
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
      if ( !check_1S2EPanelEdge3Fu324Fb5S(*ctx.rx_buffer, ia) ) {
        ::nprpc::impl::make_simple_answer(ctx, ::nprpc::impl::MessageId::Error_BadInput);
        break;
      }
      uint32_t __ret_val;
      try {
        __ret_val = CreatePanel(ia._1(), ia._2(), ia._3(), ia._4(), ia._5());
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
    case 7: {
      assert(ctx.rx_buffer != nullptr);
      lava_M2_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu32(*ctx.rx_buffer, ia) ) {
        break;
      }
      Present(ia._1());
      break;
    }
    case 8: {
      assert(ctx.rx_buffer != nullptr);
      lava_M8_Direct ia(*ctx.rx_buffer, 32);
      if ( !check_1Fu322Ff323Ff32(*ctx.rx_buffer, ia) ) {
        break;
      }
      ScrollUnclaimed(ia._1(), ia._2(), ia._3());
      break;
    }
    case 10: {
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
      lava_M9_Direct oa(obuf,16);
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
    case 11: {
      assert(ctx.rx_buffer != nullptr);
      lava_M10_Direct ia(*ctx.rx_buffer, 32);
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
      lava_M11_Direct oa(obuf,16);
      oa._1().width() = __ret_val.width;
      oa._1().height() = __ret_val.height;
      oa._1().png(static_cast<uint32_t>(__ret_val.png.size()));
      memcpy(oa._1().png().data(), __ret_val.png.data(), __ret_val.png.size() * 1);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 12: {
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
      lava_M12_Direct oa(obuf,16);
      oa._1(__ret_val);
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->size = static_cast<uint32_t>(obuf.size());
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_id = ::nprpc::impl::MessageId::BlockResponse;
      static_cast<::nprpc::impl::Header*>(obuf.data().data())->msg_type = ::nprpc::impl::MessageType::Answer;
      break;
    }
    case 13: {
      assert(ctx.rx_buffer != nullptr);
      lava_M13_Direct ia(*ctx.rx_buffer, 32);
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
  default:
    throw std::runtime_error("unknown rpc exception");
  }
}
