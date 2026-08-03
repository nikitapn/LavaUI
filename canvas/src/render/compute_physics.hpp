#pragma once

#include <vulkan/vulkan.h>
#include "vk_mem_alloc.h"

#include "util/types.hpp"

class RenderDevice;

// Using std140 layout rules for alignment
// vector types are aligned to vec4 size (vec2/vec3/vec4 = 16 bytes)
// https://docs.device.org/guide/latest/shader_memory_layout.html

// GPU particle structure (must match shader struct)
struct alignas(16) GPUParticle {
    vec2 position;
    vec2 velocity;
    float mass;
    float invMass;
    vec2 force;
    float padding; // For alignment
};

// Collision pair structure (must match shader)
struct alignas(16) CollisionPair {
    uint32_t particleA;
    uint32_t particleB;
    vec2 normal;
    float penetration;
};

// Simulation parameters (must match shader uniform)
struct alignas(16) SimulationParams {
    vec2 gravity;
    vec2 worldSize;
    float deltaTime;
    float restitution;
    float particleRadius;
    uint32_t maxCollisionPairs;
    uint32_t particleCount;
    uint32_t substeps;
    uint32_t currentSubstep;
};

class ComputePhysics {
public:
    ComputePhysics(RenderDevice& device);
    ~ComputePhysics();

    void initialize(uint32_t maxParticles);
    void setParticles(const std::vector<GPUParticle>& particles);
    void updateSimulationParams(const SimulationParams& params);
    void computeStep();
    void readParticles(std::vector<GPUParticle>& outParticles);
    void cleanup();

    uint32_t getParticleCount() const { return particleCount_; }

private:
    RenderDevice& device_;
    
    // Compute pipeline resources
    VkDescriptorSetLayout descriptorSetLayout_ = VK_NULL_HANDLE;
    VkPipelineLayout pipelineLayout_ = VK_NULL_HANDLE;
    
    // Three separate compute pipelines
    VkPipeline integrationPipeline_ = VK_NULL_HANDLE;
    VkPipeline collisionDetectPipeline_ = VK_NULL_HANDLE;
    VkPipeline collisionResolvePipeline_ = VK_NULL_HANDLE;
    
    VkDescriptorPool descriptorPool_ = VK_NULL_HANDLE;
    VkDescriptorSet descriptorSet_ = VK_NULL_HANDLE;
    
    // Buffers
    VkBuffer particleBuffer_ = VK_NULL_HANDLE;
    VmaAllocation particleAlloc_ = VK_NULL_HANDLE;
    VkBuffer uniformBuffer_ = VK_NULL_HANDLE;
    VmaAllocation uniformAlloc_ = VK_NULL_HANDLE;
    
    // Collision detection buffers
    VkBuffer collisionPairBuffer_ = VK_NULL_HANDLE;
    VmaAllocation collisionPairAlloc_ = VK_NULL_HANDLE;
    VkBuffer collisionCountBuffer_ = VK_NULL_HANDLE;
    VmaAllocation collisionCountAlloc_ = VK_NULL_HANDLE;
    
    uint32_t maxParticles_ = 0;
    uint32_t particleCount_ = 0;
    uint32_t maxCollisionPairs_ = 0;
    
    void createBuffers();
    void updateDescriptorSet();
    void clearCollisionCount();
    uint32_t readCollisionCount();
};
