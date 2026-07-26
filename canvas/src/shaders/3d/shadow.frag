
#version 450

// No explicit output needed for depth-only rendering
// The hardware automatically writes gl_FragCoord.z to the depth buffer

void main() {
  // Empty - depth is automatically written by hardware
  // This is more efficient than manual depth output
}
