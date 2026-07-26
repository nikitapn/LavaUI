#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inTexCoord;

layout(binding = 0) uniform UboView {
    mat4 viewProj;
    mat4 shadowViewProj;
    vec3 lightPos;
    vec3 lightColor;
} uboView;

// Dynamic uniform buffer for model matrix
layout(binding = 1) uniform UboInstance {
    mat4 model;
    mat4 normalMatrix;
} uboInstance;

layout(location = 0) out vec3 outPos;
layout(location = 1) out vec3 outNormal;
layout(location = 2) out vec2 outTexCoord;
layout(location = 3) out vec4 shadowCoord;

void main() {
    outPos = (uboInstance.model * vec4(inPosition, 1.0)).xyz;
    outNormal = normalize(mat3(uboInstance.normalMatrix) * inNormal);
    outTexCoord = inTexCoord;

    vec4 worldPosition = uboInstance.model * vec4(inPosition, 1.0);
    
    // Transform to shadow map space
    vec4 shadowPos = uboView.shadowViewProj * worldPosition;
    
    // Convert from NDC [-1,1] to texture coordinates [0,1]
    shadowCoord.xyz = shadowPos.xyz * 0.5 + 0.5;
    shadowCoord.w = shadowPos.w;
    
    gl_Position = uboView.viewProj * worldPosition;
}
