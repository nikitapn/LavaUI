#include "appmenu.hpp"

#include "wlr.hpp"

#include "appmenu-protocol.h"

#include <unordered_map>

namespace lava {

struct AppMenuManager::Impl {
  /// One client's link between a wl_surface and a DBus menu address.
  struct Object {
    /// Listener first so the cast from `wl_listener *` is well-defined — same
    /// pattern as `Listener<T>` in main.cpp; offsetof through std::string is not.
    struct {
      wl_listener listener{};
      Object *owner = nullptr;
    } surfaceDestroy;
    wl_resource *resource = nullptr;
    wlr_surface *surface = nullptr;
    AppMenuAddress address;
    Impl *manager = nullptr;
  };

  wl_global *global = nullptr;
  OnChanged onChanged;
  /// Live appmenu objects keyed by the surface they were created for.
  std::unordered_map<wlr_surface *, Object *> bySurface;

  void notify(wlr_surface *surface) {
    if (onChanged && surface != nullptr) onChanged(surface);
  }

  static void detachSurface(Object *obj, bool clearAddress) {
    if (obj == nullptr || obj->surface == nullptr) return;
    wl_list_remove(&obj->surfaceDestroy.listener.link);
    wlr_surface *surface = obj->surface;
    obj->manager->bySurface.erase(surface);
    obj->surface = nullptr;
    if (clearAddress) obj->address = {};
    obj->manager->notify(surface);
  }

  static void destroyObject(Object *obj) {
    if (obj == nullptr) return;
    detachSurface(obj, /*clearAddress=*/true);
    delete obj;
  }

  static void on_surface_destroy(wl_listener *listener, void * /*data*/) {
    auto *wrap =
        reinterpret_cast<decltype(Object::surfaceDestroy) *>(listener);
    Object *obj = wrap->owner;
    // Surface is dying; drop the link. The resource stays until the client
    // releases it — destroying it here races client teardown.
    detachSurface(obj, /*clearAddress=*/true);
  }

  static void appmenu_set_address(wl_client * /*client*/, wl_resource *resource,
                                  const char *service_name,
                                  const char *object_path) {
    auto *obj = static_cast<Object *>(wl_resource_get_user_data(resource));
    if (obj == nullptr) return;
    obj->address.service = service_name ? service_name : "";
    obj->address.objectPath = object_path ? object_path : "";
    if (obj->surface != nullptr) obj->manager->notify(obj->surface);
  }

  static void appmenu_release(wl_client * /*client*/, wl_resource *resource) {
    wl_resource_destroy(resource);
  }

  static void appmenu_resource_destroy(wl_resource *resource) {
    auto *obj = static_cast<Object *>(wl_resource_get_user_data(resource));
    if (obj == nullptr) return;
    wl_resource_set_user_data(resource, nullptr);
    destroyObject(obj);
  }

  static const struct org_kde_kwin_appmenu_interface appmenu_impl;

  static void manager_create(wl_client *client, wl_resource *resource,
                             uint32_t id, wl_resource *surface_resource) {
    auto *self = static_cast<Impl *>(wl_resource_get_user_data(resource));
    wlr_surface *surface = wlr_surface_from_resource(surface_resource);
    if (surface == nullptr) {
      wl_resource_post_error(resource, WL_DISPLAY_ERROR_INVALID_OBJECT,
                             "appmenu create: bad surface");
      return;
    }

    // One appmenu per surface. A second create replaces the first; clients
    // are not supposed to stack them, and keeping both would make addressFor
    // ambiguous.
    if (auto it = self->bySurface.find(surface); it != self->bySurface.end()) {
      detachSurface(it->second, /*clearAddress=*/true);
    }

    const int version = wl_resource_get_version(resource);
    wl_resource *menu_resource =
        wl_resource_create(client, &org_kde_kwin_appmenu_interface, version, id);
    if (menu_resource == nullptr) {
      wl_client_post_no_memory(client);
      return;
    }

    auto *obj = new Object();
    obj->resource = menu_resource;
    obj->surface = surface;
    obj->manager = self;
    obj->surfaceDestroy.owner = obj;
    obj->surfaceDestroy.listener.notify = on_surface_destroy;
    wl_signal_add(&surface->events.destroy, &obj->surfaceDestroy.listener);
    self->bySurface[surface] = obj;

    wl_resource_set_implementation(menu_resource, &appmenu_impl, obj,
                                   appmenu_resource_destroy);
  }

  static const struct org_kde_kwin_appmenu_manager_interface manager_impl;

  static void bind(wl_client *client, void *data, uint32_t version,
                   uint32_t id) {
    auto *self = static_cast<Impl *>(data);
    const uint32_t max = org_kde_kwin_appmenu_manager_interface.version;
    const uint32_t ver = version > max ? max : version;
    wl_resource *resource = wl_resource_create(
        client, &org_kde_kwin_appmenu_manager_interface, static_cast<int>(ver),
        id);
    if (resource == nullptr) {
      wl_client_post_no_memory(client);
      return;
    }
    wl_resource_set_implementation(resource, &manager_impl, self, nullptr);
  }
};

const struct org_kde_kwin_appmenu_interface AppMenuManager::Impl::appmenu_impl = {
    .set_address = appmenu_set_address,
    .release = appmenu_release,
};

const struct org_kde_kwin_appmenu_manager_interface
    AppMenuManager::Impl::manager_impl = {
        .create = manager_create,
};

AppMenuManager::AppMenuManager() : impl_(new Impl()) {}

AppMenuManager::~AppMenuManager() {
  if (impl_ == nullptr) return;
  // The wl_display frees the global and every resource when it is destroyed.
  // Main tears the display down before this object, so calling
  // `wl_global_destroy` here would touch free memory. Drop our map without
  // deleting the Object* entries — their resource destroy handlers already
  // ran (or never will, with the display gone).
  impl_->global = nullptr;
  impl_->bySurface.clear();
  delete impl_;
  impl_ = nullptr;
}

void AppMenuManager::init(wl_display *display) {
  if (impl_ == nullptr || display == nullptr || impl_->global != nullptr) return;
  impl_->global = wl_global_create(
      display, &org_kde_kwin_appmenu_manager_interface,
      org_kde_kwin_appmenu_manager_interface.version, impl_, Impl::bind);
  if (impl_->global == nullptr) {
    wlr_log(WLR_ERROR,
            "appmenu: failed to advertise org_kde_kwin_appmenu_manager");
  } else {
    wlr_log(WLR_INFO, "appmenu: org_kde_kwin_appmenu_manager advertised");
  }
}

void AppMenuManager::setOnChanged(OnChanged cb) {
  if (impl_ != nullptr) impl_->onChanged = std::move(cb);
}

AppMenuAddress AppMenuManager::addressFor(wlr_surface *surface) const {
  if (impl_ == nullptr || surface == nullptr) return {};
  auto it = impl_->bySurface.find(surface);
  if (it == impl_->bySurface.end() || it->second == nullptr) return {};
  return it->second->address;
}

}  // namespace lava
