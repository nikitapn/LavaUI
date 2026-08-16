#version 450

// Fullscreen triangle (no vertex buffer). Used by Dual Kawase.
// UV is 0..1 over the visible NDC square (Vulkan Y-down, origin top-left).

layout(location = 0) out vec2 vUV;

void main() {
  // Vertices: (0,0), (2,0), (0,2) → NDC (-1,-1), (3,-1), (-1,3).
  vec2 pos = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
  vUV = pos;
  gl_Position = vec4(pos * 2.0 - 1.0, 0.0, 1.0);
}
