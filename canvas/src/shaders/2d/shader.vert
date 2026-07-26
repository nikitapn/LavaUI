#version 450

layout(location = 0) in vec2 in_position;
layout(location = 1) in vec2 in_texCoord;

layout(binding = 0) uniform UboView {
    mat4 viewProj;
} uboView;

layout(binding = 1) uniform UboInstance {
    mat4 model;
} uboInstance;

layout(location = 0) out vec2 texCoord;

void main() {
  texCoord = in_texCoord;

  vec4 position = uboView.viewProj * uboInstance.model * vec4(in_position, 0.0, 1.0);
  gl_Position = position;
}
