#pragma once

#include <vector>
#include <atomic>
#include <cassert>
#include <unordered_map>

#include "util/types.hpp"
#include "render/vulkan.hpp"

struct Mesh3D {
  int meshId;

  struct Vertex {
    vec3 vertex;
    vec3 normal;
    vec2 texCoord;
  };
  vk::Buffer vertexBuffer;
  vk::Buffer indexBuffer;
  // TODO: Add texture support later

  // ---------------------------- CPU-side data for easy access ----------------------------

  // This probaly not a good idea to store CPU data alongside GPU buffers
  // but for simplicity we will do it for now
  std::vector<Vertex> vertices;
  std::vector<u16> indices;
};

// single threaded for now. revisit when multithreaded
// rendering will be comming to life
class Mesh3DRegistry {
  std::atomic<int> nextMeshId_{0};
  std::unordered_map<int, Mesh3D> meshes_;

public:
  Mesh3DRegistry() = default;
  ~Mesh3DRegistry() = default;

  // Non-copyable
  Mesh3DRegistry(const Mesh3DRegistry&) = delete;
  Mesh3DRegistry& operator=(const Mesh3DRegistry&) = delete;

  // Non-movable
  Mesh3DRegistry(Mesh3DRegistry&&) = delete;
  Mesh3DRegistry& operator=(Mesh3DRegistry&&) = delete;

  static Mesh3DRegistry& getInstance() {
    static Mesh3DRegistry instance;
    return instance;
  }

  // Create and register a new mesh, returning a reference to it for filling out
  Mesh3D& createMesh() {
    auto id = nextMeshId_.fetch_add(1);
    auto it = meshes_.emplace(id, Mesh3D{.meshId = id});
    assert(it.second); // Ensure insertion took place
    return it.first->second;
  }

  // Retrieve a mesh by its string identifier
  const Mesh3D* getMesh(const int id) const {
    auto it = meshes_.find(id);
    if (it != meshes_.end()) {
      return &it->second;
    }
    return nullptr;
  }

  void cleanUp(VkDevice device) {
    for (auto& [id, mesh] : meshes_) {
      mesh.vertexBuffer.destroy(device);
      mesh.indexBuffer.destroy(device);
    }
    meshes_.clear();
  }
};
