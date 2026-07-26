#include <pch.hpp>

#include <algorithm>

#include <glm/geometric.hpp>
#include <glm/ext/vector_float3.hpp>

#include <vulkan/vulkan_core.h>

#include "render/vulkan.hpp"
#include "render/camera.hpp"
#include "render/shaders.hpp"
#include "render/pipeline.hpp"
#include "render/line_renderer.hpp"
#include "render/mesh3d_renderer.hpp"

#include "util/util.hpp"

struct Vertex3D {
  vec3 position;
  vec3 normal;
  vec2 texCoord;

  static const VkVertexInputBindingDescription &getBindingDescription()
  {
    static VkVertexInputBindingDescription bindingDescription {
      .binding   = 0,
      .stride    = sizeof(Vertex3D),
      .inputRate = VK_VERTEX_INPUT_RATE_VERTEX,
    };
    return bindingDescription;
  }

  static const auto& getAttributeDescriptions()
  {
    static std::array<VkVertexInputAttributeDescription, 3>
      attributeDescriptions {
        VkVertexInputAttributeDescription {
          .location = 0,
          .binding  = 0,
          .format   = VK_FORMAT_R32G32B32_SFLOAT,
          .offset   = offsetof(Vertex3D, position),
        },
        VkVertexInputAttributeDescription {
          .location = 1,
          .binding  = 0,
          .format   = VK_FORMAT_R32G32B32_SFLOAT,
          .offset   = offsetof(Vertex3D, normal),
        },
        VkVertexInputAttributeDescription {
          .location = 2,
          .binding  = 0,
          .format   = VK_FORMAT_R32G32_SFLOAT,
          .offset   = offsetof(Vertex3D, texCoord),
        },
      };

    return attributeDescriptions;
  }
};

// Shadow-optimized vertex input (position only)
struct ShadowVertex {
  static const VkVertexInputBindingDescription &getBindingDescription()
  {
    static VkVertexInputBindingDescription bindingDescription {
      .binding   = 0,
      .stride    = sizeof(Vertex3D), // Still use full vertex stride (data is there)
      .inputRate = VK_VERTEX_INPUT_RATE_VERTEX,
    };
    return bindingDescription;
  }

  static const auto& getAttributeDescriptions()
  {
    static std::array<VkVertexInputAttributeDescription, 1> attributeDescriptions {
      VkVertexInputAttributeDescription {
        .location = 0,
        .binding  = 0,
        .format   = VK_FORMAT_R32G32B32_SFLOAT,
        .offset   = offsetof(Vertex3D, position), // Only position needed
      },
    };
    return attributeDescriptions;
  }
};

void Mesh3DRenderer::BufferDeleter::operator()(void* ptr) const {
  utils::alignedFree(ptr);
}

Mesh3DRenderer::Mesh3DRenderer(Vulkan& vulkan, Camera& camera)
  : vulkan_(vulkan)
  , camera_(camera)
{
}

void Mesh3DRenderer::setNormalDebugRenderer(LineRenderer* renderer) {
  normalDebugRenderer_ = renderer;
}

void Mesh3DRenderer::setDrawNormals(bool enabled) {
  drawNormals_ = enabled;
}

void Mesh3DRenderer::setNormalDebugLength(float length) {
  normalLength_ = length;
}

void Mesh3DRenderer::setNormalDebugSampleStep(u32 step) {
  normalSampleStride_ = std::max<u32>(1, step);
}

void Mesh3DRenderer::setNormalDebugColor(const vec4& color) {
  normalColor_ = color;
}

void Mesh3DRenderer::setCamera(Camera& camera) {
  camera_ = camera;
}

void Mesh3DRenderer::setWireframe(bool enabled) {
  wireframeEnabled_ = enabled;
}

void Mesh3DRenderer::setLighting(const vec3& lightPosition, const vec3& lightColor) {
  lightPosition_ = lightPosition;
  lightColor_ = lightColor;
}

void Mesh3DRenderer::draw(VkCommandBuffer commandBuffer, u32 imageIndex) {
  // Update static uniforms if camera/lighting changed
  updateStaticUniforms();

  if (uboDataDynamic_.objectCount == 0)
    return; // Nothing to draw

  memcpy(uboDataDynamic_.mapped,
         uboDataDynamic_.transforms.get(),
         uboDataDynamic_.objectCount * dynamicAlignment_);

  // Flush memory range
  VkMappedMemoryRange memoryRange {
    .sType  = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
    .pNext  = nullptr,
    .memory = uboDataDynamic_.bufferMemory,
    .offset = 0,
    .size   = uboDataDynamic_.objectCount * dynamicAlignment_,
  };

  vkFlushMappedMemoryRanges(vulkan_.getDevice(), 1, &memoryRange);


  vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                    wireframeEnabled_ ? wireframePipeline_.pipeline : meshPipeline_.pipeline);

  Mesh3D const * mesh = nullptr;
  // Render all meshes
  for (u16 objIx = 0; objIx < uboDataDynamic_.objectCount; ++objIx) {
    const auto currentMeshId = uboDataDynamic_.meshIds[objIx];
    if (!mesh || currentMeshId != mesh->meshId) {
      mesh = Mesh3DRegistry::getInstance().getMesh(currentMeshId);
      if (!mesh) {
        // Handle error: mesh not found
        continue;
      }
      // Bind geometry for this primitive type
      VkDeviceSize offsets[] = {0};
      vkCmdBindVertexBuffers(commandBuffer, 0, 1, &mesh->vertexBuffer.buffer, offsets);
      // Bind index buffer if using indexed drawing
      vkCmdBindIndexBuffer(commandBuffer, mesh->indexBuffer.buffer, 0, VK_INDEX_TYPE_UINT16);
    }

    u32 dynamicOffset = dynamicAlignment_ * objIx;

    // *** KEY ADVANTAGE: Single efficient descriptor bind with dynamic offset ***
    vkCmdBindDescriptorSets(commandBuffer,
                            VK_PIPELINE_BIND_POINT_GRAPHICS,
                            wireframeEnabled_ ? wireframePipeline_.layout : meshPipeline_.layout,
                            0, 1, &descriptorSet_,
                            1, &dynamicOffset);  // <- This is the magic!

    // Set per-object material parameters via push constants
    const auto& renderParams = uboDataDynamic_.renderParams[objIx];

    vkCmdPushConstants(
      commandBuffer,
      wireframeEnabled_ ? wireframePipeline_.layout : meshPipeline_.layout,
      VK_SHADER_STAGE_FRAGMENT_BIT,
      0,
      sizeof(renderParams),
      &renderParams);

    // Draw the object
    vkCmdDrawIndexed(commandBuffer, mesh->indices.size(), 1, 0, 0, 0);
  }

  uboDataDynamic_.objectCount = 0;
}

mat4 Mesh3DRenderer::getShadowViewProjection() const {
  // === DYNAMIC SHADOW FRUSTUM FOLLOWING CAMERA ===
  vec3 cameraPos = camera_.position();
  vec3 cameraForward = camera_.forward();

  // Calculate optimal scene center based on camera view
  float shadowDistance = 400.0f; // How far ahead of camera to center shadows
  vec3 sceneCenter = cameraPos + cameraForward * shadowDistance * 0.4f;
  
  // Keep Y focused on ground level for ground shadows
  sceneCenter.y = -30.0f; // Slightly above your ground plane at Y=-55
  
  // Position light optimally for the current view
  vec3 lightDir = glm::normalize(lightPosition_);
  vec3 shadowLightPos = sceneCenter + lightDir * 500.0f; // Distance from center
  
  // === ADAPTIVE FRUSTUM SIZING FOR OPTIMAL QUALITY ===
  // Base size for high-quality shadows around camera
  float baseFrustumSize = 400.0f;
  
  // Scale based on camera height (when higher up, need larger view)
  float heightScale = std::max(1.0f, cameraPos.y / 200.0f);
  
  // Scale based on distance from origin (for world exploration)  
  float distanceFromOrigin = glm::length(vec2(cameraPos.x, cameraPos.z));
  float distanceScale = std::min(distanceFromOrigin * 0.08f, 150.0f);
  
  float frustumSize = baseFrustumSize * heightScale + distanceScale;
  
  // Ensure minimum quality - never go below 100 units
  frustumSize = std::max(frustumSize, 100.0f);
  
  // Cap maximum size to preserve quality - never go above 300 units  
  frustumSize = std::min(frustumSize, 300.0f);
  
  // frustumSize = 350.0f; // TEMP OVERRIDE FOR DEMO

  // Near/far planes to encompass all relevant geometry
  float shadowNear = -10.0f;
  float shadowFar = 800.0f;
  
  return glm::ortho(-frustumSize, frustumSize, -frustumSize, frustumSize, shadowNear, shadowFar) *
         glm::lookAt(shadowLightPos, sceneCenter, vec3(0.0f, 1.0f, 0.0f));
}

void Mesh3DRenderer::drawShadowPass(VkCommandBuffer commandBuffer) {
  // Update dynamic uBO(same as main pass)
  if (uboDataDynamic_.objectCount == 0)
    return; // Nothing to draw

  memcpy(uboDataDynamic_.mapped,
         uboDataDynamic_.transforms.get(),
         uboDataDynamic_.objectCount * dynamicAlignment_);

  // Flush memory range
  VkMappedMemoryRange memoryRange {
    .sType  = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
    .pNext  = nullptr,
    .memory = uboDataDynamic_.bufferMemory,
    .offset = 0,
    .size   = uboDataDynamic_.objectCount * dynamicAlignment_,
  };

  vkFlushMappedMemoryRanges(vulkan_.getDevice(), 1, &memoryRange);

  // Bind shadow pipeline (depth-only shaders)
  vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                    shadowPipeline_.pipeline);

  const auto shadowViewProjection = getShadowViewProjection();

  vkCmdPushConstants(
    commandBuffer,
    shadowPipeline_.layout,
    VK_SHADER_STAGE_VERTEX_BIT,
    0,
    sizeof(mat4),
    &shadowViewProjection);

  Mesh3D const * mesh = nullptr;
  // Render all meshes (depth-only) - but only those that cast shadows
  for (u16 objIx = 0; objIx < uboDataDynamic_.objectCount; ++objIx) {
    // Skip objects that don't cast shadows (like ground/platform)
    const auto& renderParams = uboDataDynamic_.renderParams[objIx];
    if (!renderParams.castsShadows) {
      continue;
    }

    const auto currentMeshId = uboDataDynamic_.meshIds[objIx];
    if (!mesh || currentMeshId != mesh->meshId) {
      mesh = Mesh3DRegistry::getInstance().getMesh(currentMeshId);
      if (!mesh) {
        continue;
      }
      // Bind geometry for this primitive type
      VkDeviceSize offsets[] = {0};
      vkCmdBindVertexBuffers(commandBuffer, 0, 1, &mesh->vertexBuffer.buffer, offsets);
      vkCmdBindIndexBuffer(commandBuffer, mesh->indexBuffer.buffer, 0, VK_INDEX_TYPE_UINT16);
    }

    u32 dynamicOffset = dynamicAlignment_ * objIx;

    // Bind shadow descriptor set (optimized - only dynamic UBO)
    vkCmdBindDescriptorSets(commandBuffer,
                            VK_PIPELINE_BIND_POINT_GRAPHICS,
                            shadowPipeline_.layout,
                            0, 1, &shadowDescriptorSet_,
                            1, &dynamicOffset);

    // Draw the object (depth-only)
    vkCmdDrawIndexed(commandBuffer, mesh->indices.size(), 1, 0, 0, 0);
  }

  // Note: Don't reset objectCount here, as main pass will need it too
}

void Mesh3DRenderer::init() {
  // Setup dynamic uniform buffer (same approach as GeometryRenderer)
  size_t minUboAlignment = 
    vulkan_.getDeviceProperties().limits.minUniformBufferOffsetAlignment;
  dynamicAlignment_ = sizeof(Transform3D);
  if (minUboAlignment > 0) {
    dynamicAlignment_ = 
      (dynamicAlignment_ + minUboAlignment - 1) & ~(minUboAlignment - 1);
  }

  size_t bufferSize = OBJECT_INSTANCES * dynamicAlignment_;
  uboDataDynamic_.transforms.reset(
    (Transform3D*)utils::alignedAlloc(bufferSize, dynamicAlignment_));

  vulkan_.createBuffer(bufferSize,
                       VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
                       uboDataDynamic_.buffer,
                       uboDataDynamic_.bufferMemory);

  VR(vkMapMemory(vulkan_.getDevice(),
                 uboDataDynamic_.bufferMemory,
                 0, bufferSize, 0,
                 &uboDataDynamic_.mapped),
     "failed to map 3D dynamic UBO memory!");

  // Create static UBO for view/projection/lighting
  vulkan_.createBuffer(sizeof(StaticUbo),
                       VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                       uboStatic_.getAddressOf(),
                       uboStaticMemory_.getAddressOf());

  setupDescriptors();
  createPipelines();
}

void Mesh3DRenderer::pushMesh(
  int meshId,
  const mat4& modelMatrix,
  const RenderParams& params)
{
  if (uboDataDynamic_.objectCount >= OBJECT_INSTANCES) {
    static int count = 0;
    if (count++ % 1000 == 0) { // Throttle warnings
      std::cerr << "Warning: Exceeded max 3D object instances in Mesh3DRenderer\n";
    }
    return;
  }

  auto ix = uboDataDynamic_.objectCount++;

  // Copy render parameters
  uboDataDynamic_.renderParams[ix] = params;

  // Store mesh ID
  uboDataDynamic_.meshIds[ix] = meshId;

  // Calculate normal matrix for correct lighting transformation
  // For uniform scaling, we can use the model matrix directly
  // For non-uniform scaling, we need transpose(inverse(model))
  mat4 normalMatrix = transpose(inverse(modelMatrix));

  // Store transform data in the dynamic buffer array
  auto ptr = uboDataDynamic_.transforms.get();
  ptr[ix].modelMatrix = modelMatrix;
  ptr[ix].normalMatrix = normalMatrix;

  if (drawNormals_ && normalDebugRenderer_) {
    const Mesh3D* mesh = Mesh3DRegistry::getInstance().getMesh(meshId);
    if (mesh) {
      const mat4& model = modelMatrix;
      const mat3 normalMat3 = mat3(normalMatrix);
      const u32 stride = std::max<u32>(1, normalSampleStride_);

      for (size_t i = 0; i < mesh->vertices.size(); i += stride) {
        const auto& vertex = mesh->vertices[i];
        vec3 worldPos = vec3(model * vec4(vertex.vertex, 1.0f));
        vec3 normalDir = normalMat3 * vertex.normal;
        float len = glm::length(normalDir);
        if (len < 1e-5f) {
          continue;
        }
        normalDir = normalDir / len;
        normalDebugRenderer_->addLine(worldPos, worldPos + normalDir * normalLength_, normalColor_);
      }
    }
  }
}

void Mesh3DRenderer::setupDescriptors() {
  // TODO: Optimization: Use multiple descriptor sets to optimize material changes
  constexpr auto bindingCount = 3;

  // - Binding 0: Static uBO(view/projection/lighting)
  std::array<VkDescriptorSetLayoutBinding, bindingCount> layoutBindings;
  layoutBindings[0] = {
    .binding            = 0,
    .descriptorType     = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    .descriptorCount    = 1,
    .stageFlags         = VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT,
    .pImmutableSamplers = nullptr,
  };

  // - Binding 1: Dynamic uBO(per-object transforms) <- KEY BINDING
  layoutBindings[1] = {
    .binding            = 1,
    .descriptorType     = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
    .descriptorCount    = 1,
    .stageFlags         = VK_SHADER_STAGE_VERTEX_BIT,
    .pImmutableSamplers = nullptr,
  };

  // - Binding 2: Texture sampler (if needed)
  layoutBindings[2] = {
    .binding            = 2,
    .descriptorType     = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    .descriptorCount    = 1,
    .stageFlags         = VK_SHADER_STAGE_FRAGMENT_BIT,
    .pImmutableSamplers = nullptr,
  };

  VkDescriptorSetLayoutCreateInfo layoutInfo {
    .sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    .bindingCount = bindingCount,
    .pBindings    = layoutBindings.data(),
  };

  VR(vkCreateDescriptorSetLayout(
       vulkan_.getDevice(), &layoutInfo, nullptr, &descriptorSetLayout_),
     "failed to create descriptor set layout!");

  // pool
  std::array<VkDescriptorPoolSize, 3> poolSizes;
  poolSizes[0] = {
    .type            = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    .descriptorCount = 1,
  };

  poolSizes[1] = {
    .type            = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
    .descriptorCount = 1,
  };

  poolSizes[2] = {
    .type            = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    .descriptorCount = 1,
  };

  VkDescriptorPoolCreateInfo poolInfo {
    .sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    .maxSets       = 1,
    .poolSizeCount = static_cast<u32>(poolSizes.size()),
    .pPoolSizes    = poolSizes.data(),
  };

  VR(vkCreateDescriptorPool(
       vulkan_.getDevice(), &poolInfo, nullptr, &descriptorPool_),
     "failed to create descriptor pool!");

  // Descriptor set
  VkDescriptorSetAllocateInfo allocInfo {
    .sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    .descriptorPool     = descriptorPool_,
    .descriptorSetCount = 1,
    .pSetLayouts        = &descriptorSetLayout_,
  };

  VR(vkAllocateDescriptorSets(vulkan_.getDevice(), &allocInfo, &descriptorSet_),
     "failed to allocate descriptor sets!");

  // Configure descriptor set
  std::array<VkWriteDescriptorSet, 3> writes;

  VkDescriptorBufferInfo staticUboInfo {
    .buffer = uboStatic_,
    .offset = 0,
    .range  = VK_WHOLE_SIZE,
  };

  writes[0] = {
    .sType            = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    .dstSet           = descriptorSet_,
    .dstBinding       = 0,
    .dstArrayElement  = 0,
    .descriptorCount  = 1,
    .descriptorType   = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    .pBufferInfo      = &staticUboInfo,
  };

  VkDescriptorBufferInfo dynamicBufferInfo {
    .buffer = uboDataDynamic_.buffer,
    .offset = 0,
    .range  = dynamicAlignment_,
  };

  writes[1] = {
    .sType            = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    .dstSet           = descriptorSet_,
    .dstBinding       = 1,
    .dstArrayElement  = 0,
    .descriptorCount  = 1,
    .descriptorType   = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
    .pBufferInfo      = &dynamicBufferInfo,
  };

  // Shadow map
  VkDescriptorImageInfo imageInfoShadow {
    .sampler     = vulkan_.getShadowSampler(),
    .imageView   = vulkan_.getShadowImageView(),
    .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
  };

  writes[2] = {
    .sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    .dstSet          = descriptorSet_,
    .dstBinding      = 2,
    .dstArrayElement = 0,
    .descriptorCount = 1,
    .descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    .pImageInfo      = &imageInfoShadow,
  };

  vkUpdateDescriptorSets(vulkan_.getDevice(),
                         static_cast<u32>(writes.size()),
                         writes.data(),
                         0,
                         nullptr);

  // ===== SHADOW PASS dESCRIPTORS(Optimized - only dynamic UBO) =====
  
  // Shadow descriptor layout - only binding 1 (dynamic UBO for transforms)
  VkDescriptorSetLayoutBinding shadowLayoutBinding {
    .binding            = 1,
    .descriptorType     = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
    .descriptorCount    = 1,
    .stageFlags         = VK_SHADER_STAGE_VERTEX_BIT,
    .pImmutableSamplers = nullptr,
  };

  VkDescriptorSetLayoutCreateInfo shadowLayoutInfo {
    .sType        = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    .bindingCount = 1,
    .pBindings    = &shadowLayoutBinding,
  };

  VR(vkCreateDescriptorSetLayout(
       vulkan_.getDevice(), &shadowLayoutInfo, nullptr, &shadowDescriptorSetLayout_),
     "failed to create shadow descriptor set layout!");

  // Shadow descriptor pool
  VkDescriptorPoolSize shadowPoolSize {
    .type            = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
    .descriptorCount = 1,
  };

  VkDescriptorPoolCreateInfo shadowPoolInfo {
    .sType         = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
    .maxSets       = 1,
    .poolSizeCount = 1,
    .pPoolSizes    = &shadowPoolSize,
  };

  VR(vkCreateDescriptorPool(
       vulkan_.getDevice(), &shadowPoolInfo, nullptr, &shadowDescriptorPool_),
     "failed to create shadow descriptor pool!");

  // Shadow descriptor set
  VkDescriptorSetAllocateInfo shadowAllocInfo {
    .sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    .descriptorPool     = shadowDescriptorPool_,
    .descriptorSetCount = 1,
    .pSetLayouts        = &shadowDescriptorSetLayout_,
  };

  VR(vkAllocateDescriptorSets(vulkan_.getDevice(), &shadowAllocInfo, &shadowDescriptorSet_),
     "failed to allocate shadow descriptor sets!");

  // Configure shadow descriptor set
  VkDescriptorBufferInfo shadowBufferInfo {
    .buffer = uboDataDynamic_.buffer,
    .offset = 0,
    .range  = dynamicAlignment_,
  };

  VkWriteDescriptorSet shadowWrite {
    .sType            = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    .dstSet           = shadowDescriptorSet_,
    .dstBinding       = 1,
    .dstArrayElement  = 0,
    .descriptorCount  = 1,
    .descriptorType   = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
    .pBufferInfo      = &shadowBufferInfo,
  };

  vkUpdateDescriptorSets(vulkan_.getDevice(), 1, &shadowWrite, 0, nullptr);
}

void Mesh3DRenderer::createPipelines() {

  VkPipelineVertexInputStateCreateInfo vertexInputInfo {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    .vertexBindingDescriptionCount   = 1,
    .pVertexBindingDescriptions      = &Vertex3D::getBindingDescription(),
    .vertexAttributeDescriptionCount =
      static_cast<u32>(Vertex3D::getAttributeDescriptions().size()),
    .pVertexAttributeDescriptions = Vertex3D::getAttributeDescriptions().data(),
  };

  // Add push constant range for render parameters
  VkPushConstantRange pushConstantRange {
    .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
    .offset     = 0,
    .size       = sizeof(RenderParams),
  };

  VkPipelineLayoutCreateInfo pipelineLayoutInfo {
    .sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    .setLayoutCount         = 1,
    .pSetLayouts            = &descriptorSetLayout_,
    .pushConstantRangeCount = 1,
    .pPushConstantRanges    = &pushConstantRange,
  };

  auto &shaders = vulkan_.getShaders();

  // Main mesh pipeline (full lighting)
  auto pipelineBuilder = PipelineBuilder()
    .setVertexShader(shaders.loadShader("shaders/mesh.vert.bin"))
    .setFragmentShader(shaders.loadShader("shaders/mesh.frag.bin"))
    .setPrimitiveTopology(VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, VK_FALSE)
    .setVertexInputState(vertexInputInfo)
    .setLayoutInfo(pipelineLayoutInfo)
    .setPolygonMode(VK_POLYGON_MODE_FILL);

  meshPipeline_ = pipelineBuilder
    .build(vulkan_, "mesh_pipeline");

  // Debug: Wireframe pipeline (for debugging)
  wireframePipeline_ = pipelineBuilder
    .setPolygonMode(VK_POLYGON_MODE_LINE)
    .build(vulkan_, "wireframe_pipeline");

  VkPushConstantRange shadowPushConstantRange {
    .stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
    .offset     = 0,
    .size       = sizeof(glm::mat4),
  };

  // Shadow vertex input (position only)
  VkPipelineVertexInputStateCreateInfo shadowVertexInputInfo {
    .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    .vertexBindingDescriptionCount   = 1,
    .pVertexBindingDescriptions      = &ShadowVertex::getBindingDescription(),
    .vertexAttributeDescriptionCount = static_cast<u32>(ShadowVertex::getAttributeDescriptions().size()),
    .pVertexAttributeDescriptions    = ShadowVertex::getAttributeDescriptions().data(),
  };

  // Shadow pipeline layout (optimized - only dynamic UBO)
  VkPipelineLayoutCreateInfo shadowLayoutInfo {
    .sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    .setLayoutCount         = 1,
    .pSetLayouts            = &shadowDescriptorSetLayout_, // Use shadow-specific layout
    .pushConstantRangeCount = 1,
    .pPushConstantRanges    = &shadowPushConstantRange,
  };

  // Shadow pipeline (depth-only rendering)
  shadowPipeline_ = PipelineBuilder()
    .setVertexShader(shaders.loadShader("shaders/shadow.vert.bin"))
    .setFragmentShader(shaders.loadShader("shaders/shadow.frag.bin"))
    .setPrimitiveTopology(VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, VK_FALSE)
    .setVertexInputState(shadowVertexInputInfo) // Use optimized vertex input
    .setLayoutInfo(shadowLayoutInfo)
    .setPolygonMode(VK_POLYGON_MODE_FILL)
    .setRenderPass(vulkan_.getShadowRenderPass()) // CRUCIAL: Use shadow render pass!
    .setShadowPipeline(true) // CRUCIAL: Configure for shadow-specific settings!
    .build(vulkan_, "shadow_pipeline");
}

void Mesh3DRenderer::updateStaticUniforms() {
  auto& view = camera_.getViewMatrix();
  auto& proj = camera_.getProjectionMatrix();

  StaticUbo ubo {
    .viewProjection = proj * view,
    .shadowViewProjection = getShadowViewProjection(),
    .lightPosition  = lightPosition_,
    .lightColor     = lightColor_,
  };

  void* data;
  vkMapMemory(vulkan_.getDevice(), uboStaticMemory_, 0, sizeof(ubo), 0, &data);
  memcpy(data, &ubo, sizeof(ubo));
  vkUnmapMemory(vulkan_.getDevice(), uboStaticMemory_);
}

void Mesh3DRenderer::cleanUp() {
  auto device = vulkan_.getDevice();

  // Clean up dynamic UBO
  vkUnmapMemory(device, uboDataDynamic_.bufferMemory);
  vkDestroyBuffer(device, uboDataDynamic_.buffer, nullptr);
  vkFreeMemory(device, uboDataDynamic_.bufferMemory, nullptr);

  // Clean up pipelines
  meshPipeline_.destroy(vulkan_);
  wireframePipeline_.destroy(vulkan_);
  shadowPipeline_.destroy(vulkan_);

  // Clean up main descriptors
  descriptorPool_.destroy(device);
  descriptorSetLayout_.destroy(device);
  uboStatic_.destroy(device);
  uboStaticMemory_.destroy(device);

  // Clean up shadow descriptors
  shadowDescriptorPool_.destroy(device);
  shadowDescriptorSetLayout_.destroy(device);
}
