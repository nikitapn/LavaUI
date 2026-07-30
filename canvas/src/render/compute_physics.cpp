#include <cstring>
#include <algorithm>
#include <filesystem>

#include "util/util.hpp"
#include "render/vulkan.hpp"
#include "render/compute_physics.hpp"

ComputePhysics::ComputePhysics(Vulkan& vulkan) 
    : vulkan_(vulkan) {}

ComputePhysics::~ComputePhysics() {
    cleanup();
}

void ComputePhysics::initialize(uint32_t maxParticles) {
    maxParticles_ = maxParticles;
    maxCollisionPairs_ = maxParticles * 8; // Estimate: each particle collides with ~8 others on average
    
    // Create descriptor set layout for collision detection (4 bindings)
    std::array<VkDescriptorSetLayoutBinding, 4> bindings = {{
        {0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr},
        {1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr},
        {2, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr},
        {3, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr}
    }};
    
    VkDescriptorSetLayoutCreateInfo layoutInfo {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = static_cast<uint32_t>(bindings.size()),
        .pBindings = bindings.data(),
    };
    
    VkDevice device = vulkan_.getDevice();
    VR(vkCreateDescriptorSetLayout(device, &layoutInfo, nullptr, &descriptorSetLayout_),
       "Failed to create compute descriptor set layout");
    
    // Create pipeline layout
    pipelineLayout_ = vulkan_.createComputePipelineLayout(descriptorSetLayout_);
    
    // Create compute pipelines
    integrationPipeline_ = vulkan_.createComputePipeline(pipelineLayout_, "shaders/integration.comp.bin");
    collisionDetectPipeline_ = vulkan_.createComputePipeline(pipelineLayout_, "shaders/collision_detect.comp.bin");
    collisionResolvePipeline_ = vulkan_.createComputePipeline(pipelineLayout_, "shaders/collision_resolve.comp.bin");
    
    // Create descriptor pool (needs more descriptors now)
    descriptorPool_ = vulkan_.createComputeDescriptorPool(4);
    
    // Allocate descriptor set
    descriptorSet_ = vulkan_.allocateComputeDescriptorSet(descriptorPool_, descriptorSetLayout_);
    
    // Create buffers
    createBuffers();
    
    // Update descriptor set
    updateDescriptorSet();
}

void ComputePhysics::createBuffers() {
    VkDeviceSize particleBufferSize = sizeof(GPUParticle) * maxParticles_;
    VkDeviceSize uniformBufferSize = sizeof(SimulationParams);
    VkDeviceSize collisionPairBufferSize = sizeof(CollisionPair) * maxCollisionPairs_;
    VkDeviceSize collisionCountBufferSize = sizeof(uint32_t);
    
    // Create particle storage buffer
    vulkan_.createBuffer(
        particleBufferSize,
        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        particleBuffer_,
        particleAlloc_
    );
    
    // Create collision pair buffer
    vulkan_.createBuffer(
        collisionPairBufferSize,
        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        collisionPairBuffer_,
        collisionPairAlloc_
    );
    
    // Create collision count buffer  
    vulkan_.createBuffer(
        collisionCountBufferSize,
        VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        collisionCountBuffer_,
        collisionCountAlloc_
    );
    
    // Create uniform buffer
    auto [uniformBuffer, uniformAlloc] = vulkan_.createUniformBuffer(uniformBufferSize);
    uniformBuffer_ = uniformBuffer;
    uniformAlloc_ = uniformAlloc;
}

void ComputePhysics::updateDescriptorSet() {
    VkDevice device = vulkan_.getDevice();
    
    // Particle buffer descriptor (binding 0)
    VkDescriptorBufferInfo particleBufferInfo {
        .buffer = particleBuffer_,
        .offset = 0,
        .range = sizeof(GPUParticle) * maxParticles_,
    };
    
    // Collision pair buffer descriptor (binding 1)
    VkDescriptorBufferInfo collisionPairBufferInfo {
        .buffer = collisionPairBuffer_,
        .offset = 0,
        .range = sizeof(CollisionPair) * maxCollisionPairs_,
    };
    
    // Collision count buffer descriptor (binding 2)
    VkDescriptorBufferInfo collisionCountBufferInfo {
        .buffer = collisionCountBuffer_,
        .offset = 0,
        .range = sizeof(uint32_t),
    };
    
    // Uniform buffer descriptor (binding 3)
    VkDescriptorBufferInfo uniformBufferInfo {
        .buffer = uniformBuffer_,
        .offset = 0,
        .range = sizeof(SimulationParams),
    };
    
    std::array<VkWriteDescriptorSet, 4> descriptorWrites = {{
        {
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptorSet_,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &particleBufferInfo,
        },
        {
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptorSet_,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &collisionPairBufferInfo,
        },
        {
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptorSet_,
            .dstBinding = 2,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &collisionCountBufferInfo,
        },
        {
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptorSet_,
            .dstBinding = 3,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .pBufferInfo = &uniformBufferInfo,
        }
    }};
    
    vkUpdateDescriptorSets(device, static_cast<uint32_t>(descriptorWrites.size()), descriptorWrites.data(), 0, nullptr);
}

void ComputePhysics::setParticles(const std::vector<GPUParticle>& particles) {
    particleCount_ = static_cast<uint32_t>(particles.size());
    
    if (particleCount_ > maxParticles_) {
        throw std::runtime_error("Particle count exceeds maximum!");
    }
    
    // Create staging buffer
    VkDeviceSize bufferSize = sizeof(GPUParticle) * particleCount_;
    VkBuffer stagingBuffer;
    VmaAllocation stagingAlloc;
    
    vulkan_.createBuffer(
        bufferSize,
        VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        stagingBuffer,
        stagingAlloc
    );
    
    void* data = vulkan_.mapBuffer(stagingAlloc);
    memcpy(data, particles.data(), static_cast<size_t>(bufferSize));
    vulkan_.unmapBuffer(stagingAlloc);
    
    vulkan_.copyBuffer(stagingBuffer, particleBuffer_, bufferSize);
    vulkan_.destroyBuffer(stagingBuffer, stagingAlloc);
}

void ComputePhysics::updateSimulationParams(const SimulationParams& params) {
    void* data = vulkan_.mapBuffer(uniformAlloc_);
    memcpy(data, &params, sizeof(SimulationParams));
    vulkan_.unmapBuffer(uniformAlloc_);
}

void ComputePhysics::computeStep() {
    // Step 1: Clear collision count
    clearCollisionCount();
    
    VkCommandBuffer commandBuffer = vulkan_.beginSingleTimeCommands();
    
    // Calculate number of workgroups (64 threads per workgroup as defined in shader)
    uint32_t workgroupSize = 64;
    uint32_t particleWorkgroups = (particleCount_ + workgroupSize - 1) / workgroupSize;
    
    // Pass 1: Integration and wall collisions
    vulkan_.dispatchCompute(commandBuffer, integrationPipeline_, pipelineLayout_, descriptorSet_, particleWorkgroups);

    // Memory barrier to ensure integration is complete before collision detection
    VkMemoryBarrier memoryBarrier {
        .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
    };
    
    vkCmdPipelineBarrier(
        commandBuffer,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0, 1, &memoryBarrier, 0, nullptr, 0, nullptr
    );
    
    // Pass 2: Collision detection
    vulkan_.dispatchCompute(commandBuffer, collisionDetectPipeline_, pipelineLayout_, descriptorSet_, particleWorkgroups);
    
    // Another memory barrier before collision resolution
    vkCmdPipelineBarrier(
        commandBuffer,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0, 1, &memoryBarrier, 0, nullptr, 0, nullptr
    );
    
    vulkan_.endSingleTimeCommands(commandBuffer);
    
    // Step 3: Read collision count and iteratively resolve collisions
    uint32_t collisionCount = readCollisionCount();
    if (collisionCount > 0) {
        // Clamp to prevent buffer overflow
        collisionCount = std::min(collisionCount, maxCollisionPairs_);
        
        uint32_t collisionWorkgroups = (collisionCount + workgroupSize - 1) / workgroupSize;
        
        // Run multiple collision resolution iterations to handle race conditions
        const int resolutionIterations = 3; // Adjust this for quality vs performance
        
        for (int iter = 0; iter < resolutionIterations; ++iter) {
            VkCommandBuffer resolveCommandBuffer = vulkan_.beginSingleTimeCommands();
            vulkan_.dispatchCompute(resolveCommandBuffer, collisionResolvePipeline_, pipelineLayout_, descriptorSet_, collisionWorkgroups);
            vulkan_.endSingleTimeCommands(resolveCommandBuffer);
            // No sleep needed - endSingleTimeCommands() already waits for GPU completion
        }
    }
}

void ComputePhysics::readParticles(std::vector<GPUParticle>& outParticles) {
    outParticles.resize(particleCount_);
    
    VkDeviceSize bufferSize = sizeof(GPUParticle) * particleCount_;
    VkBuffer stagingBuffer;
    VmaAllocation stagingAlloc;
    
    vulkan_.createBuffer(
        bufferSize,
        VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        stagingBuffer,
        stagingAlloc
    );
    
    // Copy from device buffer to staging
    vulkan_.copyBuffer(particleBuffer_, stagingBuffer, bufferSize);
    
    void* data = vulkan_.mapBuffer(stagingAlloc);
    memcpy(outParticles.data(), data, static_cast<size_t>(bufferSize));
    vulkan_.unmapBuffer(stagingAlloc);
    
    vulkan_.destroyBuffer(stagingBuffer, stagingAlloc);
}

void ComputePhysics::clearCollisionCount() {
    uint32_t zero = 0;
    
    // Create staging buffer
    VkBuffer stagingBuffer;
    VmaAllocation stagingAlloc;
    
    vulkan_.createBuffer(
        sizeof(uint32_t),
        VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        stagingBuffer,
        stagingAlloc
    );
    
    void* data = vulkan_.mapBuffer(stagingAlloc);
    memcpy(data, &zero, sizeof(uint32_t));
    vulkan_.unmapBuffer(stagingAlloc);
    
    // Copy to collision count buffer
    vulkan_.copyBuffer(stagingBuffer, collisionCountBuffer_, sizeof(uint32_t));
    
    vulkan_.destroyBuffer(stagingBuffer, stagingAlloc);
}

uint32_t ComputePhysics::readCollisionCount() {
    uint32_t count = 0;
    
    // Create staging buffer
    VkBuffer stagingBuffer;
    VmaAllocation stagingAlloc;
    
    vulkan_.createBuffer(
        sizeof(uint32_t),
        VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        stagingBuffer,
        stagingAlloc
    );
    
    // Copy from collision count buffer to staging
    vulkan_.copyBuffer(collisionCountBuffer_, stagingBuffer, sizeof(uint32_t));
    
    void* data = vulkan_.mapBuffer(stagingAlloc);
    memcpy(&count, data, sizeof(uint32_t));
    vulkan_.unmapBuffer(stagingAlloc);
    
    vulkan_.destroyBuffer(stagingBuffer, stagingAlloc);
    
    return count;
}

void ComputePhysics::cleanup() {
    VkDevice device = vulkan_.getDevice();
    
    vulkan_.destroyBuffer(particleBuffer_, particleAlloc_);
    vulkan_.destroyBuffer(uniformBuffer_, uniformAlloc_);
    vulkan_.destroyBuffer(collisionPairBuffer_, collisionPairAlloc_);
    vulkan_.destroyBuffer(collisionCountBuffer_, collisionCountAlloc_);
    
    if (integrationPipeline_ != VK_NULL_HANDLE) {
        vkDestroyPipeline(device, integrationPipeline_, nullptr);
        integrationPipeline_ = VK_NULL_HANDLE;
    }
    
    if (collisionDetectPipeline_ != VK_NULL_HANDLE) {
        vkDestroyPipeline(device, collisionDetectPipeline_, nullptr);
        collisionDetectPipeline_ = VK_NULL_HANDLE;
    }
    
    if (collisionResolvePipeline_ != VK_NULL_HANDLE) {
        vkDestroyPipeline(device, collisionResolvePipeline_, nullptr);
        collisionResolvePipeline_ = VK_NULL_HANDLE;
    }
    
    if (pipelineLayout_ != VK_NULL_HANDLE) {
        vkDestroyPipelineLayout(device, pipelineLayout_, nullptr);
        pipelineLayout_ = VK_NULL_HANDLE;
    }
    
    if (descriptorPool_ != VK_NULL_HANDLE) {
        vkDestroyDescriptorPool(device, descriptorPool_, nullptr);
        descriptorPool_ = VK_NULL_HANDLE;
    }
    
    if (descriptorSetLayout_ != VK_NULL_HANDLE) {
        vkDestroyDescriptorSetLayout(device, descriptorSetLayout_, nullptr);
        descriptorSetLayout_ = VK_NULL_HANDLE;
    }
}
