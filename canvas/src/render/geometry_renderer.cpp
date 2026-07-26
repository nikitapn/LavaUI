#include <pch.hpp>

#include "render/vulkan.hpp"
#include "render/geometry_renderer.hpp"
#include "render/texture_manager.hpp"
#include "render/primitives.hpp"
#include "render/pipeline.hpp"
#include "render/shaders.hpp"
#include "util/util.hpp"

#include <vulkan/vulkan_core.h>

constexpr auto useTexture = false;

struct Vertex2D {
  vec2 position;
  vec2 texCoord;
  // Removed vec3 color - using push constants for per-object colors instead

  static const VkVertexInputBindingDescription &getBindingDescription()
  {
    static VkVertexInputBindingDescription bindingDescription {
      .binding   = 0,
      .stride    = sizeof(Vertex2D),
      .inputRate = VK_VERTEX_INPUT_RATE_VERTEX,
    };
    return bindingDescription;
  }

  static const std::array<VkVertexInputAttributeDescription, 2> & getAttributeDescriptions()
  {
    static std::array<VkVertexInputAttributeDescription, 2>
      attributeDescriptions {
        VkVertexInputAttributeDescription {
          .location = 0,
          .binding  = 0,
          .format   = VK_FORMAT_R32G32_SFLOAT,
          .offset   = offsetof(Vertex2D, position),
        },
        VkVertexInputAttributeDescription {
          .location = 1,
          .binding  = 0,
          .format   = VK_FORMAT_R32G32_SFLOAT,
          .offset   = offsetof(Vertex2D, texCoord),
        },
      };

    return attributeDescriptions;
  }
};

void GeometryRenderer::setupDescriptors()
{
  constexpr auto bindingCount = 3;

  // layout
  std::array<VkDescriptorSetLayoutBinding, bindingCount> layoutBindings;
  layoutBindings[0] = {
    .binding            = 0,
    .descriptorType     = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    .descriptorCount    = 1,
    .stageFlags         = VK_SHADER_STAGE_VERTEX_BIT,
    .pImmutableSamplers = nullptr,
  };

  layoutBindings[1] = {
    .binding            = 1,
    .descriptorType     = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
    .descriptorCount    = 1,
    .stageFlags         = VK_SHADER_STAGE_VERTEX_BIT,
    .pImmutableSamplers = nullptr,
  };

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

  // set

  VkDescriptorSetAllocateInfo allocInfo {
    .sType              = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
    .descriptorPool     = descriptorPool_,
    .descriptorSetCount = 1,
    .pSetLayouts        = &descriptorSetLayout_,
  };

  VR(vkAllocateDescriptorSets(vulkan_.getDevice(), &allocInfo, &descriptorSet_),
     "failed to allocate descriptor sets!");

  const auto &extent = vulkan_.getExtent();
  mat4 projView { // column-major
    2.0f / extent.width, 0.0f, 0.0f, 0.0f,
    0.0f, -2.0f / extent.height, 0.0f, 0.0f,
    0.0f,  0.0f, 0.0f, 0.0f,
    -1.0f, 1.0f, 0.0f, 1.0f
  };

  uboStatic_ = vulkan_.createImmutableUniformBuffer(&projView, sizeof(glm::mat4));

  VkDescriptorBufferInfo bufferInfo {
    .buffer = uboStatic_.buffer,
    .offset = 0,
    .range  = VK_WHOLE_SIZE,
  };

  std::array<VkWriteDescriptorSet, 2> writes;
  writes[0] = {
    .sType            = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    .dstSet           = descriptorSet_,
    .dstBinding       = 0,
    .dstArrayElement  = 0,
    .descriptorCount  = 1,
    .descriptorType   = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
    .pBufferInfo      = &bufferInfo,
  };

  const size_t bufferSize = OBJECT_INSTANCES * dynamicAlignment_;

  VR(vkMapMemory(vulkan_.getDevice(),
                 uboDataDynamic_.bufferMemory,
                 0,
                 bufferSize,
                 0,
                 &uboDataDynamic_.mapped),
     "failed to map memory!");

  VkDescriptorBufferInfo bufferInfo1 {
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
    .pBufferInfo      = &bufferInfo1,
  };


  vkUpdateDescriptorSets(vulkan_.getDevice(), writes.size(), writes.data(), 0, nullptr);
}

void GeometryRenderer::createPipeline()
{
  VkPipelineVertexInputStateCreateInfo vertexInputInfo {.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    .vertexBindingDescriptionCount = 1,
    .pVertexBindingDescriptions    = &Vertex2D::getBindingDescription(),
    .vertexAttributeDescriptionCount =
      static_cast<u32>(Vertex2D::getAttributeDescriptions().size()),
    .pVertexAttributeDescriptions = Vertex2D::getAttributeDescriptions().data(),
  };

  // Add push constant range for render parameters  
  VkPushConstantRange pushConstantRange {
    .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT,
    .offset     = 0,
    .size       = 32  // int(4) + padding(12) + vec3(16 aligned) = 32 bytes
  };

  VkPipelineLayoutCreateInfo pipelineLayoutInfo {
    .sType                  = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
    .setLayoutCount         = 1,
    .pSetLayouts            = &descriptorSetLayout_,
    .pushConstantRangeCount = 1,
    .pPushConstantRanges    = &pushConstantRange,
  };

  auto &shaders = vulkan_.getShaders();

  // Fan topology pipeline builder (for circles and rounded rectangles)
  auto fanPipelineBuilder = PipelineBuilder()
      .setVertexShader(shaders.loadShader("shaders/shader.vert.bin"))
      .setFragmentShader(shaders.loadShader("shaders/shader.frag.bin"))
      .setPrimitiveTopology(VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN, VK_FALSE)
      .setVertexInputState(vertexInputInfo)
      .setLayoutInfo(pipelineLayoutInfo)
      .setPolygonMode(VK_POLYGON_MODE_FILL);

  // Create fan topology pipeline (for circles and rounded rectangles) - FILLED
  fanPipelineBuilder.setPrimitiveTopology(VK_PRIMITIVE_TOPOLOGY_TRIANGLE_FAN, VK_FALSE);
  fanPipeline_ = fanPipelineBuilder.build(vulkan_, "2d_fan_pipeline");
  
  // Create fan topology pipeline (for circles and rounded rectangles) - WIREFRAME
  fanPipelineBuilder.setPolygonMode(VK_POLYGON_MODE_LINE);
  fanWireframePipeline_ = fanPipelineBuilder.build(vulkan_, "2d_fan_wireframe_pipeline");

  // Indexed triangle pipeline builder (for rectangles)
  auto indexedPipelineBuilder =  PipelineBuilder()
      .setVertexShader(shaders.loadShader("shaders/shader.vert.bin"))
      .setFragmentShader(shaders.loadShader("shaders/shader.frag.bin"))
      .setPrimitiveTopology(VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, VK_FALSE)
      .setVertexInputState(vertexInputInfo)
      .setLayoutInfo(pipelineLayoutInfo)
      .setPolygonMode(VK_POLYGON_MODE_FILL);

  // Create indexed triangle pipeline (for rectangles) - FILLED
  indexedPipeline_ = indexedPipelineBuilder.build(vulkan_, "2d_indexed_pipeline");

  // Create indexed triangle pipeline (for rectangles) - WIREFRAME
  indexedPipelineBuilder.setPolygonMode(VK_POLYGON_MODE_LINE);
  indexedWireframePipeline_ = indexedPipelineBuilder.build(vulkan_, "2d_indexed_wireframe_pipeline");
}

void GeometryRenderer::draw(
  VkCommandBuffer commandBuffer, u32 imageIndex)
{
  memcpy(uboDataDynamic_.mapped,
         uboDataDynamic_.model.get(),
         uboDataDynamic_.count * dynamicAlignment_);

  // Flush to make changes visible to the host
  VkMappedMemoryRange memoryRange {
    .sType  = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,
    .pNext  = nullptr,
    .memory = uboDataDynamic_.bufferMemory,
    .offset = 0,
    .size   = uboDataDynamic_.count * dynamicAlignment_,
  };
  vkFlushMappedMemoryRanges(vulkan_.getDevice(), 1, &memoryRange);

  TextureHandle previousTexture {VK_NULL_HANDLE, 0};

  for (size_t i = 0; i < 3; ++i) {
    const auto &objects = objects_[i];
    const auto &geometry = vbs_[i];
    if (!geometry.vertexBuffer || objects.count == 0)
      continue;
    
    // Choose pipeline based on geometry type and wireframe mode
    const Pipeline* currentPipeline;
    bool useIndexBuffer = false;
    
    if (i == static_cast<size_t>(Type::Rectangle)) {
      currentPipeline = wireframeMode_ ? &indexedWireframePipeline_ : &indexedPipeline_;
      useIndexBuffer = true;
    } else {
      currentPipeline = wireframeMode_ ? &fanWireframePipeline_ : &fanPipeline_;
      useIndexBuffer = false;
    }
    
    vkCmdBindPipeline(
      commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, currentPipeline->pipeline);
    
    VkDeviceSize offsets[] = {0};
    vkCmdBindVertexBuffers(
      commandBuffer, 0, 1, &geometry.vertexBuffer.buffer, offsets);
      
    if (useIndexBuffer && geometry.indexBuffer) {
      vkCmdBindIndexBuffer(
        commandBuffer, geometry.indexBuffer.buffer, 0, VK_INDEX_TYPE_UINT16);
    }

    for (u16 ix = 0; ix < objects.count; ++ix) {
      const u32 dynamicOffset = dynamicAlignment_ * objects.mappings[ix];

      vkCmdBindDescriptorSets(commandBuffer,
                              VK_PIPELINE_BIND_POINT_GRAPHICS,
                              currentPipeline->layout,
                              0,
                              1,
                              &descriptorSet_,
                              1,
                              &dynamicOffset);

      // Set push constants for this object
      const auto& renderParams = objects.renderParams[ix];

      std::visit([&](auto&& params) {
        // Reality: vec3 is ALWAYS aligned to 16 bytes, regardless of std140/std430
        struct {
          int useTexture;    // 4 bytes at offset 0
          float padding[3];  // 12 bytes padding (required for vec3 alignment)
          vec3 solidColor;   // 12 bytes at offset 16
        } pushConstants;

        using T = std::decay_t<decltype(params)>;
        if constexpr (std::is_same_v<T, RenderParamsSolid>) {
          pushConstants.useTexture = 0;
          pushConstants.solidColor = vec3(params.color.r, params.color.g, params.color.b);
        } else if constexpr (std::is_same_v<T, RenderParamsTextured>) {
          // Update descriptor set with the correct texture if it has changed
          if (params.texture.isValid() && params.texture != previousTexture) {
            previousTexture = params.texture;

            VkDescriptorImageInfo imageInfo {
              .sampler     = textureSampler_,
              .imageView   = params.texture.view,
              .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };

            VkWriteDescriptorSet write {
              .sType           = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
              .dstSet          = descriptorSet_,
              .dstBinding      = 2,
              .dstArrayElement = 0,
              .descriptorCount = 1,
              .descriptorType  = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
              .pImageInfo      = &imageInfo,
            };
            vkUpdateDescriptorSets(vulkan_.getDevice(), 1, &write, 0, nullptr);
          }
          pushConstants.useTexture = 1;
          pushConstants.solidColor = vec3(params.color.r, params.color.g, params.color.b);
        }
        vkCmdPushConstants(commandBuffer,
                          currentPipeline->layout,
                          VK_SHADER_STAGE_FRAGMENT_BIT,
                          0,
                          sizeof(pushConstants),
                          &pushConstants);
      }, renderParams);

      if (useIndexBuffer && geometry.indexBuffer) {
        vkCmdDrawIndexed(commandBuffer, geometry.indexBuffer.size, 1, 0, 0, 0);
      } else {
        vkCmdDraw(commandBuffer, geometry.vertexBuffer.size, 1, 0, 0);
      }
    }
  }

  for (auto &object : objects_)
    object.count = 0;

  uboDataDynamic_.count = 0;
}

void GeometryRenderer::cleanUp()
{
  auto device = vulkan_.getDevice();

  descriptorPool_.destroy(device);
  descriptorSetLayout_.destroy(device);

  fanPipeline_.destroy(vulkan_);
  indexedPipeline_.destroy(vulkan_);
  fanWireframePipeline_.destroy(vulkan_);
  indexedWireframePipeline_.destroy(vulkan_);

  uboStatic_.destroy(device);

  vkUnmapMemory(device, uboDataDynamic_.bufferMemory);
  vkDestroyBuffer(device, uboDataDynamic_.buffer, nullptr);
  vkFreeMemory(device, uboDataDynamic_.bufferMemory, nullptr);

  for (auto &vb : vbs_) {
    vb.vertexBuffer.destroy(device);
    vb.indexBuffer.destroy(device);
  }

  textureSampler_.destroy(device);
}

void GeometryRenderer::init()
{
  // Initialize Circle geometry
  Mesh2D                circleMesh = Primitives::generateCircle(24);
  std::vector<Vertex2D> circleVertices(circleMesh.vertices.size());

  for (size_t i = 0; i < circleVertices.size(); ++i) {
    circleVertices[i].position = circleMesh.vertices[i];
    circleVertices[i].texCoord = circleMesh.texCoords[i];
  }

  {
    auto        &circle     = vbs_[static_cast<size_t>(Type::Circle)];
    VkDeviceSize bufferSize = sizeof(circleVertices[0]) * circleVertices.size();

    circle.vertexBuffer =
      vulkan_.createImmutableVertexBuffer(circleVertices.data(), bufferSize);
    circle.vertexBuffer.size = static_cast<u32>(circleMesh.vertices.size());
  }

  // Initialize Rectangle geometry
  Mesh2D rectangleMesh = Primitives::generateRectangle();
  std::vector<Vertex2D> rectVertices(rectangleMesh.vertices.size());

  for (size_t i = 0; i < rectVertices.size(); ++i) {
    rectVertices[i].position = rectangleMesh.vertices[i];
    rectVertices[i].texCoord = rectangleMesh.texCoords[i];
  }

  {
    auto        &rectangle  = vbs_[static_cast<size_t>(Type::Rectangle)];
    VkDeviceSize bufferSize = sizeof(rectVertices[0]) * rectVertices.size();

    rectangle.vertexBuffer =
      vulkan_.createImmutableVertexBuffer(rectVertices.data(), bufferSize);
    rectangle.vertexBuffer.size = static_cast<u32>(rectangleMesh.vertices.size());

    // Create index buffer for rectangle
    rectangle.indexBuffer =
      vulkan_.createImmutableIndexBuffer(rectangleMesh.indices.data(),
        sizeof(rectangleMesh.indices[0]) * rectangleMesh.indices.size());
    rectangle.indexBuffer.size         = static_cast<u16>(rectangleMesh.indices.size());
  }

  // Initialize RoundedRectangle geometry
  Mesh2D roundedRectMesh = Primitives::generateRoundedRectangle(8);
  std::vector<Vertex2D> roundedVertices(roundedRectMesh.vertices.size());

  for (size_t i = 0; i < roundedVertices.size(); ++i) {
    roundedVertices[i].position = roundedRectMesh.vertices[i];
    roundedVertices[i].texCoord = roundedRectMesh.texCoords[i];
  }

  {
    auto        &roundedRect = vbs_[static_cast<size_t>(Type::RoundedRectangle)];
    VkDeviceSize bufferSize = sizeof(roundedVertices[0]) * roundedVertices.size();

    roundedRect.vertexBuffer =
      vulkan_.createImmutableVertexBuffer(roundedVertices.data(), bufferSize);
    roundedRect.vertexBuffer.size = static_cast<u32>(roundedRectMesh.vertices.size());
  }

  textureSampler_ = vulkan_.createTextureSampler();

  // Dynamic UBO for model matrices
  // Calculate required alignment based on minimum device offset alignment
  size_t minUboAlignment =
    vulkan_.getDeviceProperties().limits.minUniformBufferOffsetAlignment;
  dynamicAlignment_ = sizeof(glm::mat4);
  if (minUboAlignment > 0) {
    dynamicAlignment_ =
      (dynamicAlignment_ + minUboAlignment - 1) & ~(minUboAlignment - 1);
  }

  size_t bufferSize = OBJECT_INSTANCES * dynamicAlignment_;

  uboDataDynamic_.model.reset(
    (glm::mat4 *)utils::alignedAlloc(bufferSize, dynamicAlignment_));

  assert(uboDataDynamic_.model);

  // std::cout << "minUniformBufferOffsetAlignment = " << minUboAlignment
  // << std::endl;
  // std::cout << "dynamicAlignment = " << dynamicAlignment_ << std::endl;

  vulkan_.createBuffer(bufferSize,
                       VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                       VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT,
                       uboDataDynamic_.buffer,
                       uboDataDynamic_.bufferMemory);

  setupDescriptors();
  createPipeline();
}

void GeometryRenderer::setViewportSize(vec2 size)
{
  viewportSize_ = size;
}

void GeometryRenderer::toggleWireframe()
{
  wireframeMode_ = !wireframeMode_;
}

void GeometryRenderer::pushScreenObject(Type type, const ScreenParams& params)
{
  float worldX = params.position.x;
  float worldY = viewportSize_.y - params.position.y;
  
  mat4 translation = glm::translate(mat4(1.0f), vec3{worldX, worldY, 0.0f});
  // With 1.0 unit primitives, scale factor now directly matches the desired size
  mat4 scale = glm::scale(mat4(1.0f), vec3{params.size.x, params.size.y, 1.0f});
  mat4 world = translation * scale;
  
  RenderParamsSolid renderParams{params.color};
  pushObject(type, world, renderParams);
}
