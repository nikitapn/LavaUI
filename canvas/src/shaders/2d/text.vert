#version 450

// Per-vertex attributes (for quad vertices)
layout(location = 0) in vec2 inPosition;

// Per-instance attributes
layout(location = 1) in vec2 inInstancePosition;  // Glyph world position
layout(location = 2) in vec2 inUVTopLeft;
layout(location = 3) in vec2 inUVBottomRight;
layout(location = 4) in vec2 inSize;              // Glyph dimensions in pixels
layout(location = 5) in vec4 inColor;

layout(location = 0) out vec2 fragUV;
layout(location = 1) out vec4 fragColor;

layout(push_constant) uniform PushConstants {
    mat4 projectionMatrix;
    vec2 viewportSize;
} pc;

void main() {
    // Calculate world position: instance position + scaled quad vertex
    // inPosition is quad vertex (0,0) to (1,1)
    // inSize is glyph dimensions in pixels (width, height)
    // inInstancePosition is where to place this glyph on screen
    vec2 worldPosition = inInstancePosition + (inPosition * inSize);
    
    // Convert to normalized device coordinates
    vec2 ndc = (worldPosition / pc.viewportSize) * 2.0 - 1.0;
    // ndc.y = -ndc.y; // Flip Y coordinate for screen space
    
    gl_Position = vec4(ndc, 0.0, 1.0);
    
    // Interpolate UV coordinates across the quad
    // Flip V coordinate to match OpenGL texture coordinate convention
    vec2 correctedUV = vec2(
        mix(inUVTopLeft.x, inUVBottomRight.x, inPosition.x),
        mix(inUVTopLeft.y, inUVBottomRight.y, inPosition.y)
    );
    // fragUV = mix(inUVTopLeft, inUVBottomRight, inPosition);
    fragUV = correctedUV;
    fragColor = inColor;
}