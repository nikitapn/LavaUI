#version 450

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 outColor;

layout(binding = 2) uniform sampler2D texSampler;

// Push constants for render parameters
layout(push_constant) uniform PushConstants {
    int useTexture;
    vec3 solidColor;
} pushConstants;

void main() {
    if (pushConstants.useTexture == 1) {
        vec4 texColor = texture(texSampler, texCoord);
        outColor = texColor;
        // Shadow map visualization (for debugging)
        // vec4 texColor = texture(texSampler, texCoord);
        // float depth = texColor.r;
        // float enhanced = pow(depth, 0.5); // Gamma correction for better visibility
        // outColor = vec4(enhanced, enhanced, enhanced, 1.0);
    } else {
        // Use solid color from push constants
        outColor = vec4(pushConstants.solidColor, 1.0);
    }
}
