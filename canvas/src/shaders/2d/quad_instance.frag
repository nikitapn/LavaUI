#version 450
#extension GL_EXT_nonuniform_qualifier : require

// Instanced twin of quad.frag. `vKind` is `QuadRenderer::Kind`:
//   0 Sdf           — rounded-box distance field (rect / round-rect / circle).
//   1 Glyph         — coverage from the R8 atlas (`.r` * tint).
//   2 Image         — full-colour sample * tint, bindless.
//   3 Mesh          — unused here; arbitrary polygons stay on the indexed path.
//   4 Mask          — window corner punch: emit coverage as alpha, multiply
//                     dest, write nothing inside the shape.
//   5 Shadow        — the same rounded box, faded outwards over `vAux` px.
//   6 BlurComposite — frosted backdrop, sampled through the same SDF.
//
// Output is premultiplied; the pipeline blends ONE / ONE_MINUS_SRC_ALPHA.

layout(location = 0) in vec2 vLocal;
layout(location = 1) in vec2 vHalfSize;
layout(location = 2) in float vRadius;
layout(location = 3) in vec4 vColor;
layout(location = 4) flat in uint vKind;
layout(location = 5) flat in float vAux;
layout(location = 6) in vec2 vUv;
layout(location = 7) flat in uint vTextureIndex;
layout(location = 8) flat in float vDither;
layout(binding = 0) uniform sampler2D textures[];
layout(location = 0) out vec4 outColor;

float sdRoundBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// Interleaved gradient noise (Jimenez). Cheap, and stable across drivers in a
// way a `sin`-based hash is not — that one varies with the compiler's choice
// of transcendental and can shimmer between frames on some GPUs.
float ign(vec2 p) {
  return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

/// Breaks up the staircase an 8-bit ramp makes across a large area.
///
/// A gradient covering a screen crosses far fewer than 256 distinct values per
/// channel, so the steps land as visible bands — worst on the dark, slowly
/// varying ramps a desktop background is made of. Adding rather less than one
/// quantization step of noise before the framebuffer rounds turns each hard
/// edge into a dithered transition the eye reads as smooth.
///
/// Applied to the premultiplied result, because that is the value actually
/// being rounded into the framebuffer. Gated on `vDither` so only quads that
/// carry a gradient pay it: glyph coverage and sampled images have no banding
/// to fix, and noise on text is a downgrade.
vec3 dither(vec3 premultiplied) {
  if (vDither <= 0.0) return premultiplied;
  return premultiplied + (ign(gl_FragCoord.xy) - 0.5) * (1.0 / 255.0);
}

void main() {
  if (vKind == 5u) { // Shadow
    float d = sdRoundBox(vLocal, vHalfSize, vRadius);
    float fall = 1.0 - smoothstep(0.0, max(vAux, 1e-4), max(d, 0.0));
    float a = vColor.a * fall * fall;
    if (a <= 0.002) discard;
    // No RGB dither. A shadow is premultiplied black — `rgb = 0, a = falloff`
    // — and adding ±½ a quantization step to the colour (the trick that
    // hides bands on a gradient) writes a grey that is no longer
    // premultiplied. On a 1:1 DRM output those greys land as a dotted
    // rim along the iso-alpha of the SDF. Nested under another compositor
    // the extra filter hides it, which is why the bug only showed on a
    // real session. The falloff is tens of pixels, not a screen, so the
    // banding this was meant to hide is not there to begin with.
    outColor = vec4(vColor.rgb * a, a);
    return;
  }

  if (vKind == 4u) { // Mask
    float d = sdRoundBox(vLocal, vHalfSize, vRadius);
    float coverage = 1.0 - smoothstep(-max(fwidth(d), 1e-5),
                                     max(fwidth(d), 1e-5), d);
    if (coverage >= 0.999) discard;
    outColor = vec4(0.0, 0.0, 0.0, coverage);
    return;
  }

  if (vKind == 6u) { // BlurComposite
    float d = sdRoundBox(vLocal, vHalfSize, vRadius);
    float aa = max(fwidth(d), 1e-5);
    float coverage = 1.0 - smoothstep(-aa, aa, d);
    vec4 sampled = texture(textures[nonuniformEXT(vTextureIndex)], vUv) * vColor;
    float a = sampled.a * coverage;
    if (a <= 0.001) discard;
    outColor = vec4(sampled.rgb * a, a);
    return;
  }

  if (vKind == 2u) { // Image
    vec4 c = texture(textures[nonuniformEXT(vTextureIndex)], vUv) * vColor;
    if (c.a <= 0.001) discard;
    outColor = vec4(c.rgb * c.a, c.a);
    return;
  }

  float coverage;
  if (vKind == 1u) { // Glyph
    coverage = texture(textures[nonuniformEXT(vTextureIndex)], vUv).r;
  } else { // Sdf (kind 0); Mesh never reaches this shader
    float d = sdRoundBox(vLocal, vHalfSize, vRadius);
    // Sharp box: full coverage inside, none outside. SDF AA on r=0
    // eats ~1px on every edge — see quad.frag.
    if (vRadius < 0.5) {
      coverage = d <= 0.0 ? 1.0 : 0.0;
    } else {
      float aa = max(fwidth(d), 1e-5);
      coverage = 1.0 - smoothstep(-aa, aa, d);
    }
  }
  if (coverage <= 0.0) discard;
  vec4 c = vec4(vColor.rgb, vColor.a * coverage);
  outColor = vec4(dither(c.rgb * c.a), c.a);
}
