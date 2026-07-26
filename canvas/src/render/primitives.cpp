#include <pch.hpp>

#include <algorithm>
#include <cassert>

#include "util/types.hpp"
#include "util/constants.hpp"
#include "render/primitives.hpp"

Mesh2D Primitives::generateCircle(
  int numberOfSegments)
{
  assert(numberOfSegments >= 3);

  Mesh2D r;

  // Circle in range [-0.5, 0.5] for both x and y (1.0 unit diameter)
  r.vertices.resize(numberOfSegments + 2);
  r.texCoords.resize(numberOfSegments + 2);

  r.vertices[0] = {.0f, .0f};
  // UV coordinates range from 0 to 1
  // Center of the circle is at .5f, .5f
  // Convert from [-0.5, 0.5] range to [0, 1] UV range
  auto toUV     = [](const vec2 &v) -> vec2 {
    return {v.x + 0.5f, v.y + 0.5f};
  };
  r.texCoords[0] = toUV(r.vertices[0]);
  r.indices.resize(numberOfSegments * 3);

  const float dt = TWO_PI_F / static_cast<float>(numberOfSegments);
  for (auto [t, i] = MT(0.0f, 0); i < numberOfSegments + 1; ++i, t += dt) {
    // Generate unit circle (radius = 0.5, diameter = 1.0) for consistency with rectangle
    r.vertices[i + 1]  = {cos(t) * 0.5f, sin(t) * 0.5f};
    r.texCoords[i + 1] = (toUV(r.vertices[i + 1]));
  }

  return r;
}

Mesh2D Primitives::generateRectangle() {
  Mesh2D r;
  
  // 4 vertices for a unit rectangle from -0.5 to 0.5 (1.0 unit total size)
  // This makes scaling more intuitive: scale factor = final size
  r.vertices = {
    {-0.5f, -0.5f},  // Bottom-left
    { 0.5f, -0.5f},  // Bottom-right
    { 0.5f,  0.5f},  // Top-right
    {-0.5f,  0.5f}   // Top-left
  };
  
  r.texCoords = {
    {0.0f, 0.0f},   // Bottom-left
    {1.0f, 0.0f},   // Bottom-right
    {1.0f, 1.0f},   // Top-right
    {0.0f, 1.0f}    // Top-left
  };
  
  // Two triangles with clockwise winding: (0,2,1) and (0,3,2)
  r.indices = {
    0, 1, 2,  // First triangle (counter-clockwise)
    0, 2, 3   // Second triangle (counter-clockwise)  
  };
  
  return r;
}

Mesh2D Primitives::generateRoundedRectangle(int cornerSegments) {
  // TODO: Texture coordinates are not ideal yet...

  Mesh2D r;

  const float cornerRadius = 0.12f;  // 20% of unit size
  const float a = 0.5f - cornerRadius;

  // Center vertex
  r.vertices.push_back({0.0f, 0.0f});
  r.texCoords.push_back({0.5f, 0.5f});

  // Generate vertices for each corner and edge
  const float dt = (TWO_PI_F * 0.25f) / cornerSegments; // Quarter circle per corner

  // Right edge (lower) + Bottom-right corner
  for (int i = 0; i <= cornerSegments; ++i) {
    float angle = -i * dt;
    vec2 pos = {a + cornerRadius * cos(angle), 
                -a + cornerRadius * sin(angle)};
    r.vertices.push_back(pos);
    r.texCoords.push_back({0.5f + pos.x * 0.5f, 0.5f - pos.y * 0.5f});
  }

  // Left edge + bottom-left corner  
  for (int i = 0; i <= cornerSegments; ++i) {
    float angle = -PI_F / 2.0f - i * dt;
    vec2 pos = {-a + cornerRadius * cos(angle),
                -a + cornerRadius * sin(angle)};
    r.vertices.push_back(pos);
    r.texCoords.push_back({0.5f + pos.x * 0.5f, 0.5f - pos.y * 0.5f});
  }

  // Top edge + top-left corner
  for (int i = 0; i <= cornerSegments; ++i) {
     float angle = -PI_F - i * dt;
     vec2 pos = {-a + cornerRadius * cos(angle),
                 a + cornerRadius * sin(angle)};
     r.vertices.push_back(pos);
     r.texCoords.push_back({0.5f + pos.x * 0.5f, 0.5f - pos.y * 0.5f});
   }

  // Right edge (upper) + top-right corner
  for (int i = 0; i <= cornerSegments; ++i) {
    float angle = PI_F / 2.0f - i * dt;
    vec2 pos = {a + cornerRadius * cos(angle),
                a + cornerRadius * sin(angle)};
    r.vertices.push_back(pos);
    r.texCoords.push_back({0.5f + pos.x * 0.5f, 0.5f - pos.y * 0.5f});
  }

  // Closing the loop by connecting back to the first edge vertex
  r.vertices.push_back({0.5, -a});
  r.texCoords.push_back({0.5f + a * 0.5f, 0.5f - a * 0.5f});

  // The perimeter above is generated clockwise, opposite of generateCircle's
  // counter-clockwise winding. With VK_CULL_MODE_BACK_BIT +
  // VK_FRONT_FACE_COUNTER_CLOCKWISE (see Pipeline's rasterizer state), that
  // made every triangle in this fan back-facing and invisible — reversing
  // the perimeter order (but not the center vertex) flips each triangle's
  // winding without changing the shape.
  std::reverse(r.vertices.begin() + 1, r.vertices.end());
  std::reverse(r.texCoords.begin() + 1, r.texCoords.end());

  return r;
}

Mesh3D* Primitives::generateCube(Vulkan& vulkan) {
  //       7-------------------6
  //      /|                  /|
  //     / |                 / |
  //    /  |                /  |
  //   4-------------------5   |
  //   |   |               |   |
  //   |   |               |   |
  //   |   |               |   |
  //   |   |               |   |
  //   |   3---------------|---2
  //   |  /                |  /
  //   | /                 | /
  //   |/                  |/
  //   0-------------------1
  auto& r = Mesh3DRegistry::getInstance().createMesh();

  // Helper function to calculate smooth normals by averaging adjacent face normals
  auto calculateSmoothNormal = [](const std::vector<vec3>& faceNormals) -> vec3 {
    vec3 result = {0.0f, 0.0f, 0.0f};
    for (const auto& normal : faceNormals) {
      result.x += normal.x;
      result.y += normal.y;
      result.z += normal.z;
    }
    // Normalize the averaged normal
    float length = sqrt(result.x * result.x + result.y * result.y + result.z * result.z);
    if (length > 0.0f) {
      result.x /= length;
      result.y /= length;
      result.z /= length;
    }
    return result;
  };

  // Define the 6 face normals
  const std::vector<vec3> faceNormals = {
    { 0.0f,  0.0f,  1.0f}, // front(+Z)
    { 1.0f,  0.0f,  0.0f}, // right(+X)
    { 0.0f,  0.0f, -1.0f}, // back(-Z)
    {-1.0f,  0.0f,  0.0f}, // left(-X)
    { 0.0f,  1.0f,  0.0f}, // top(+Y)
    { 0.0f, -1.0f,  0.0f}  // bottom(-Y)
  };

  // Calculate smooth normals for each of the 8 cube vertices
  // Each vertex is shared by 3 faces, so we average those 3 face normals
  std::vector<vec3> vertexNormals = {
    calculateSmoothNormal({faceNormals[0], faceNormals[3], faceNormals[5]}), // 0: Front+Left+Bottom
    calculateSmoothNormal({faceNormals[0], faceNormals[1], faceNormals[5]}), // 1: Front+Right+Bottom
    calculateSmoothNormal({faceNormals[2], faceNormals[1], faceNormals[5]}), // 2: Back+Right+Bottom
    calculateSmoothNormal({faceNormals[2], faceNormals[3], faceNormals[5]}), // 3: Back+Left+Bottom
    calculateSmoothNormal({faceNormals[0], faceNormals[3], faceNormals[4]}), // 4: Front+Left+Top
    calculateSmoothNormal({faceNormals[0], faceNormals[1], faceNormals[4]}), // 5: Front+Right+Top
    calculateSmoothNormal({faceNormals[2], faceNormals[1], faceNormals[4]}), // 6: Back+Right+Top
    calculateSmoothNormal({faceNormals[2], faceNormals[3], faceNormals[4]})  // 7: Back+Left+Top
  };

  // Create cube with smooth normals (8 vertices, shared between faces)
  r.vertices = {
    {{ -0.5f, -0.5f, +0.5f }, vertexNormals[0], {0.0f, 0.0f}}, // 0
    {{ +0.5f, -0.5f, +0.5f }, vertexNormals[1], {1.0f, 0.0f}}, // 1
    {{ +0.5f, -0.5f, -0.5f }, vertexNormals[2], {1.0f, 1.0f}}, // 2
    {{ -0.5f, -0.5f, -0.5f }, vertexNormals[3], {0.0f, 1.0f}}, // 3
    {{ -0.5f, +0.5f, +0.5f }, vertexNormals[4], {0.0f, 0.0f}}, // 4
    {{ +0.5f, +0.5f, +0.5f }, vertexNormals[5], {1.0f, 0.0f}}, // 5
    {{ +0.5f, +0.5f, -0.5f }, vertexNormals[6], {1.0f, 1.0f}}, // 6
    {{ -0.5f, +0.5f, -0.5f }, vertexNormals[7], {0.0f, 1.0f}}  // 7
  };

  r.vertexBuffer =
    vulkan.createImmutableVertexBuffer(r.vertices.data(), r.vertices.size() * sizeof(Mesh3D::Vertex));

  // Index buffer defines the triangles using the 8 shared vertices
  r.indices = {
    // Front face (+Z)
    0, 1, 5,  5, 4, 0,
    // Right face (+X)
    1, 2, 6,  6, 5, 1,
    // Back face (-Z)
    2, 3, 7,  7, 6, 2,
    // Left face (-X)
    3, 0, 4,  4, 7, 3,
    // Top face (+Y)
    4, 5, 6,  6, 7, 4,
    // Bottom face (-Y)
    3, 2, 1,  1, 0, 3
  };

  r.indexBuffer =
    vulkan.createImmutableIndexBuffer(r.indices.data(), r.indices.size() * sizeof(decltype(r.indices)::value_type));

  return &r;
}


Mesh3D* Primitives::generateSphere(Vulkan& vulkan, int latitudeSegments, int longitudeSegments) {
  latitudeSegments  = std::max(3, latitudeSegments);
  longitudeSegments = std::max(3, longitudeSegments);

  auto& mesh = Mesh3DRegistry::getInstance().createMesh();

  const int rings    = latitudeSegments + 1;
  const int segments = longitudeSegments + 1;

  mesh.vertices.reserve(rings * segments);
  mesh.indices.reserve(latitudeSegments * longitudeSegments * 6);

  for (int lat = 0; lat <= latitudeSegments; ++lat) {
    float theta     = PI_F * static_cast<float>(lat) / static_cast<float>(latitudeSegments);
    float sinTheta  = sin(theta);
    float cosTheta  = cos(theta);

    for (int lon = 0; lon <= longitudeSegments; ++lon) {
      float phi     = TWO_PI_F * static_cast<float>(lon) / static_cast<float>(longitudeSegments);
      float sinPhi  = sin(phi);
      float cosPhi  = cos(phi);

      vec3 normal{sinTheta * cosPhi, cosTheta, sinTheta * sinPhi};
      vec3 position = normal * 0.5f; // Unit sphere scaled to diameter 1.0
      vec2 texCoord{static_cast<float>(lon) / static_cast<float>(longitudeSegments),
                    1.0f - static_cast<float>(lat) / static_cast<float>(latitudeSegments)};

      mesh.vertices.push_back({position, glm::normalize(normal), texCoord});
    }
  }

  for (int lat = 0; lat < latitudeSegments; ++lat) {
    for (int lon = 0; lon < longitudeSegments; ++lon) {
      u32 first  = static_cast<u32>(lat * segments + lon);
      u32 second = first + segments;

      mesh.indices.push_back(static_cast<u16>(first));
      mesh.indices.push_back(static_cast<u16>(second));
      mesh.indices.push_back(static_cast<u16>(first + 1));

      mesh.indices.push_back(static_cast<u16>(second));
      mesh.indices.push_back(static_cast<u16>(second + 1));
      mesh.indices.push_back(static_cast<u16>(first + 1));
    }
  }

  mesh.vertexBuffer =
    vulkan.createImmutableVertexBuffer(mesh.vertices.data(), mesh.vertices.size() * sizeof(Mesh3D::Vertex));

  mesh.indexBuffer =
    vulkan.createImmutableIndexBuffer(mesh.indices.data(), mesh.indices.size() * sizeof(decltype(mesh.indices)::value_type));

  return &mesh;
}


