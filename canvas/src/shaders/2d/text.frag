#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec4 fragColor;

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform sampler2D atlasTexture;

void main() {
    // Sample the glyph atlas texture  
    float alpha = texture(atlasTexture, fragUV).r;
    
    // Output colored text with alpha from the atlas
    outColor = vec4(fragColor.rgb, alpha);
    
    // Discard fully transparent pixels to avoid overdraw
    if (alpha < 0.01) {
        discard;
    }
}