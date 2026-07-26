#version 450

layout(location = 0) in vec3 inPosition;

// Dynamic uniform buffer for model matrix
layout(binding = 1) uniform UboInstance {
    mat4 model;
    mat4 normalMatrix;
} uboInstance;

layout(push_constant) uniform LightPushConstants {
    mat4 lightVP;
};

layout(location = 0) out vec3 outPos;

void main(){
  gl_Position = lightVP * uboInstance.model * vec4(inPosition, 1.0);
}
