#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inTexCoord;
layout(location = 3) in vec4 shadowCoord;

layout(location = 0) out vec4 outColor;

layout(binding = 0) uniform UboView {
  mat4 viewProj;
  mat4 shadowViewProj;
  vec3 lightPos;
  vec3 lightColor;
} uboView;

layout(binding = 2) uniform sampler2D shadowMapSampler;

// Push constants for material properties
layout(push_constant) uniform PushConstants {
  vec4 solidColor;
  int useTexture;
  int reserve1; // Padding to align to 16 bytes
  int reserve2; // Padding to align to 16 bytes
  int reserve3; // Padding to align to 16 bytes
} pushConstants;

void main() {
  vec4 materialColor = vec4(1.0);
  if (pushConstants.useTexture == 1) {
    // materialColor = texture(textureSampler, inTexCoord);
  } else {
    materialColor = pushConstants.solidColor;
  }

  // Lighting calculation
  vec3 normal = normalize(inNormal);
  vec3 lightDir = normalize(uboView.lightPos - inPosition);
  
  // Ambient light (prevents pure black)
  vec3 ambient = 0.3 * uboView.lightColor;
  
  // Diffuse lighting
  float diff = max(dot(normal, lightDir), 0.0);
  vec3 diffuse = diff * uboView.lightColor;

  // Shadow calculation
  float visibility = 1.0;
  
  // Perform perspective divide for shadow coordinates
  vec3 projCoords = shadowCoord.xyz / shadowCoord.w;
  
  // Check if we're within shadow map bounds
  if (projCoords.x >= 0.0 && projCoords.x <= 1.0 && 
      projCoords.y >= 0.0 && projCoords.y <= 1.0 && 
      projCoords.z <= 1.0) {
    
    // Sample the shadow map depth
    float shadowMapDepth = texture(shadowMapSampler, projCoords.xy).r;
    
    // Add small bias to prevent shadow acne
    float bias = 0.005;
    
    // Compare current fragment depth with shadow map depth
    if (projCoords.z - bias > shadowMapDepth) {
      visibility = 0.3; // In shadow
    }
  }

  // Combine lighting
  vec3 lighting = ambient + visibility * diffuse;

  outColor = vec4(materialColor.rgb * lighting, materialColor.a);
}
