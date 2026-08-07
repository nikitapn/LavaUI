#include <cstddef>
#include <cstdlib>
#include <ctime>
#include <iostream>
#include <memory>

#include "wlr.hpp"

namespace {

template <typename T, std::size_t Offset>
T *owner_of(wl_listener *listener) {
  return reinterpret_cast<T *>(reinterpret_cast<char *>(listener) - Offset);
}

struct Server;

struct Output {
  Server *server;
  wlr_output *wlr;
  wlr_scene_output *scene_output;
  wl_listener frame{};
  wl_listener request_state{};
  wl_listener destroy{};

  Output(Server *server, wlr_output *output);
  ~Output();

  static void on_frame(wl_listener *listener, void *data);
  static void on_request_state(wl_listener *listener, void *data);
  static void on_destroy(wl_listener *listener, void *data);
};

struct Server {
  wl_display *display = nullptr;
  wlr_backend *backend = nullptr;
  wlr_renderer *renderer = nullptr;
  wlr_allocator *allocator = nullptr;
  wlr_scene *scene = nullptr;
  wlr_output_layout *output_layout = nullptr;
  wlr_scene_output_layout *scene_layout = nullptr;
  wl_listener new_output{};

  static void on_new_output(wl_listener *listener, void *data) {
    auto *server = owner_of<Server, offsetof(Server, new_output)>(listener);
    new Output(server, static_cast<wlr_output *>(data));
  }
};

Output::Output(Server *server, wlr_output *output)
    : server(server), wlr(output),
      scene_output(wlr_scene_output_create(server->scene, output)) {
  frame.notify = on_frame;
  request_state.notify = on_request_state;
  destroy.notify = on_destroy;
  wl_signal_add(&wlr->events.frame, &frame);
  wl_signal_add(&wlr->events.request_state, &request_state);
  wl_signal_add(&wlr->events.destroy, &destroy);

  wlr_output_init_render(wlr, server->allocator, server->renderer);

  wlr_output_state state;
  wlr_output_state_init(&state);
  wlr_output_state_set_enabled(&state, true);
  if (auto *mode = wlr_output_preferred_mode(wlr)) {
    wlr_output_state_set_mode(&state, mode);
  }
  wlr_output_commit_state(wlr, &state);
  wlr_output_state_finish(&state);

  auto *layout_output = wlr_output_layout_add_auto(server->output_layout, wlr);
  wlr_scene_output_layout_add_output(server->scene_layout, layout_output,
                                     scene_output);
}

Output::~Output() {
  wl_list_remove(&frame.link);
  wl_list_remove(&request_state.link);
  wl_list_remove(&destroy.link);
}

void Output::on_frame(wl_listener *listener, void *) {
  auto *output = owner_of<Output, offsetof(Output, frame)>(listener);
  wlr_scene_output_commit(output->scene_output, nullptr);
  timespec now{};
  clock_gettime(CLOCK_MONOTONIC, &now);
  wlr_scene_output_send_frame_done(output->scene_output, &now);
}

void Output::on_request_state(wl_listener *listener, void *data) {
  auto *output = owner_of<Output, offsetof(Output, request_state)>(listener);
  auto *event = static_cast<wlr_output_event_request_state *>(data);
  wlr_output_commit_state(output->wlr, event->state);
}

void Output::on_destroy(wl_listener *listener, void *) {
  delete owner_of<Output, offsetof(Output, destroy)>(listener);
}

} // namespace

int main() {
  wlr_log_init(WLR_DEBUG, nullptr);
  Server server;
  server.display = wl_display_create();
  if (!server.display) {
    std::cerr << "Could not create Wayland display\n";
    return EXIT_FAILURE;
  }

  auto *loop = wl_display_get_event_loop(server.display);
  server.backend = wlr_backend_autocreate(loop, nullptr);
  server.renderer = server.backend ? wlr_renderer_autocreate(server.backend) : nullptr;
  server.allocator = (server.backend && server.renderer)
                         ? wlr_allocator_autocreate(server.backend, server.renderer)
                         : nullptr;
  if (!server.backend || !server.renderer || !server.allocator) {
    std::cerr << "Could not create wlroots backend, renderer, or allocator\n";
    wl_display_destroy(server.display);
    return EXIT_FAILURE;
  }

  wlr_renderer_init_wl_display(server.renderer, server.display);
  wlr_compositor_create(server.display, 6, server.renderer);
  wlr_subcompositor_create(server.display);
  wlr_data_device_manager_create(server.display);

  server.scene = wlr_scene_create();
  server.output_layout = wlr_output_layout_create(server.display);
  server.scene_layout =
      wlr_scene_attach_output_layout(server.scene, server.output_layout);

  const float background[] = {0.055f, 0.075f, 0.12f, 1.0f};
  wlr_scene_rect_create(&server.scene->tree, 8192, 8192, background);

  server.new_output.notify = Server::on_new_output;
  wl_signal_add(&server.backend->events.new_output, &server.new_output);

  const char *socket = wl_display_add_socket_auto(server.display);
  if (!socket || !wlr_backend_start(server.backend)) {
    std::cerr << "Could not start compositor backend\n";
    wl_display_destroy(server.display);
    return EXIT_FAILURE;
  }

  std::cout << "Compositor running on WAYLAND_DISPLAY=" << socket << '\n';
  wl_display_run(server.display);
  wl_display_destroy_clients(server.display);
  wl_display_destroy(server.display);
  return EXIT_SUCCESS;
}
