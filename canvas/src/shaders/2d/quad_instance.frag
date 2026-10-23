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
// Sdf, Image and BlurComposite also take glass (`vGlass`, zero when off): the
// two that sample a texture bend it at the rim, and all three light the rim.
//
// Output is premultiplied; the pipeline blends ONE / ONE_MINUS_SRC_ALPHA, in
// sRGB-encoded space rather than linear light — see the note in quad.frag for
// why the buffer handover requires that.

layout(location = 0) in vec2 vLocal;
layout(location = 1) in vec2 vHalfSize;
layout(location = 2) in float vRadius;
layout(location = 3) in vec4 vColor;
layout(location = 4) flat in uint vKind;
layout(location = 5) flat in float vAux;
layout(location = 6) in vec2 vUv;
layout(location = 7) flat in uint vTextureIndex;
layout(location = 8) flat in float vDither;
layout(location = 9) flat in float vAdapt;
layout(location = 10) flat in vec2 vGlass;
layout(location = 11) flat in vec2 vUvPerPx;
layout(binding = 0) uniform sampler2D textures[];
layout(location = 0) out vec4 outColor;

/// Adaptive frost (`vAdapt`): backdrop luma below the knee is left alone,
/// and at full strength white comes out at the ceiling. Tuned by eye against
/// the HelloWorld glass demo, not derived — low enough that light text on the
/// glass stays legible over a white page, high enough to still read as glass.
const float kAdaptKnee = 0.45;
const float kAdaptCeiling = 0.62;
/// How far red and blue part from green on a refracting rim, as a fraction of
/// the displacement there. From shaderplay's glass.frag, tuned by eye.
const float kDispersion = 0.12;

float sdRoundBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

// ─── Glass ───────────────────────────────────────────────────────────────────
//
// A rim of `kBezel` pixels inside the outline, curved like a quarter circle:
// flat across the face, steepest at the edge. What sits under it is bent
// inward along the outline's normal, and it catches a light from the top left.

const float kBezel = 20.0;

/// How steep the rim is here, 0 on the face to 1 at the outline, and the
/// outward normal it bends along.
///
/// The normal is analytic — a screen-space gradient of `d` is quantized per
/// 2x2 quad and shimmers — and taken from a box rounded by at least the bezel
/// rather than by the outline's own radius. The outline's own normal snaps from
/// one axis to the other along a corner's diagonal, and a bezel wider than the
/// corner shows that miter as a seam through everything below. Past the bezel
/// `bend` is zero, so where this normal goes to zero nothing reads it.
float glassBend(float d, out vec2 n) {
  float rn = min(max(vRadius, kBezel), min(vHalfSize.x, vHalfSize.y));
  vec2 qn = max(abs(vLocal) - vHalfSize + rn, 0.0);
  n = qn / max(length(qn), 1e-6) * sign(vLocal);
  float t = clamp(1.0 + d / kBezel, 0.0, 1.0);
  return 1.0 - sqrt(1.0 - t * t);
}

/// How much white the rim adds here, 0…1, at strength `vGlass.y`.
///
/// Specular along the whole rim rather than at its outline: a tight lobe
/// facing the light from the top left (y points down), a weaker one on the far
/// side, both fading as the bezel flattens into the face. Plus a thin line at
/// the outline itself, all the way round.
float glassRim(float d, vec2 n, float bend) {
  float facing = dot(n, normalize(vec2(-0.6, -0.8)));
  float spec = pow(abs(facing), 6.0) * (facing > 0.0 ? 1.0 : 0.45);
  float band = 1.0 - smoothstep(0.0, 1.5, -d);
  return clamp((0.55 * spec * bend + 0.25 * band) * vGlass.y, 0.0, 1.0);
}

/// This quad's texture at `vUv`, bent inward at the rim by up to `vGlass.x`
/// pixels — inward, so the read never leaves the rect the UVs describe.
///
/// Red bends a little less than green and blue a little more, so edges in
/// what is under the glass fringe where the rim bends them hardest. On the
/// flat face the offset is zero and the two extra taps are skipped.
vec4 glassSample(vec2 n, float bend) {
  vec2 offset = n * (vGlass.x * bend) * vUvPerPx;
  vec2 uv = vUv - offset;
  vec4 s = texture(textures[nonuniformEXT(vTextureIndex)], uv);
  if (offset != vec2(0.0)) {
    vec2 disperse = offset * kDispersion;
    s.r = texture(textures[nonuniformEXT(vTextureIndex)], uv + disperse).r;
    s.b = texture(textures[nonuniformEXT(vTextureIndex)], uv - disperse).b;
  }
  return s;
}

/// White at `rim` laid over a premultiplied colour. Over, not added: added
/// light on a translucent fill would store rgb above alpha, which the buffer
/// handover forbids (see quad.frag) and wlroots draws as a bright fringe.
vec4 overRim(vec4 premultiplied, float rim) {
  return vec4(premultiplied.rgb * (1.0 - rim) + rim,
              premultiplied.a + rim * (1.0 - premultiplied.a));
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
    // A square composite only reaches this kind to adapt or for glass (see
    // `pushBlurResultImage`), and must keep the hard edge the plain image
    // path gives it — SDF antialiasing on r=0 eats a pixel all round.
    float coverage = vRadius < 0.5 ? (d <= 1e-4 ? 1.0 : 0.0)
                                   : 1.0 - smoothstep(-aa, aa, d);
    if (coverage <= 0.001) discard;

    // Glass bends the backdrop at the rim (a compositor plate's refraction,
    // or a view's `.glassEffect()`); a content blur has none and composites
    // unchanged.
    vec4 sampled;
    vec3 rimAdd = vec3(0.0);
    if (vGlass != vec2(0.0)) {
      vec2 n;
      float bend = glassBend(d, n);
      sampled = glassSample(n, bend);
      rimAdd = vec3(glassRim(d, n, bend));
    } else {
      sampled = texture(textures[nonuniformEXT(vTextureIndex)], vUv);
    }
    sampled *= vColor;
    float a = sampled.a * coverage;
    if (a <= 0.001) discard;

    // Bright-backdrop compression. Frost over a white page blurs to white,
    // and white glass on white is no glass at all: the panel's own tint adds
    // nothing, its edge vanishes, and light text on it is unreadable. The
    // sample *is* a local average of the backdrop — that is what a blur is —
    // so the decision is made here, per pixel, rather than from one average
    // of the whole panel: a panel straddling a white window and a dark
    // wallpaper adapts on each side, and nothing flips as windows move.
    //
    // A soft-knee highlight compressor on luma: untouched below `kAdaptKnee`,
    // then `knee + x / (1 + k·x)`, which leaves the knee with slope 1 (no
    // visible seam), rises monotonically (a brighter backdrop never comes out
    // darker — a plain mix toward a ceiling does exactly that, and inverts
    // highlights), and lands white on `top`. Colour is scaled rather than
    // mixed toward grey, so a bright yellow stays yellow.
    //
    // Luma of sRGB-encoded values, deliberately: blending happens in encoded
    // space (see quad.frag), so this is the brightness the eye is shown.
    vec3 rgb = sampled.rgb;
    float hi = 0.0;
    float luma = dot(rgb, vec3(0.2126, 0.7152, 0.0722));
    if (vAdapt > 0.0 && luma > kAdaptKnee) {
      float top = mix(1.0, kAdaptCeiling, vAdapt);
      float x = luma - kAdaptKnee;
      float k = 1.0 / (top - kAdaptKnee) - 1.0 / (1.0 - kAdaptKnee);
      rgb *= (kAdaptKnee + x / (1.0 + k * x)) / luma;
      hi = smoothstep(kAdaptKnee, 1.0, luma) * vAdapt;
    }
    // The rim lightens the edge, which is exactly what cannot show on a
    // bright backdrop — so as the backdrop brightens it turns into a shade.
    vec3 rim = mix(rimAdd, -rimAdd * 0.6, hi);
    outColor = vec4(clamp(rgb + rim, 0.0, 1.0) * a, a);
    return;
  }

  if (vKind == 2u) { // Image
    if (vGlass != vec2(0.0)) {
      // Glass on a picture bends the picture itself, and cuts it to the
      // outline the rim is measured from. Hard-edged when square, as the
      // plain path is.
      float d = sdRoundBox(vLocal, vHalfSize, vRadius);
      float aa = max(fwidth(d), 1e-5);
      float coverage = vRadius < 0.5 ? (d <= 1e-4 ? 1.0 : 0.0)
                                     : 1.0 - smoothstep(-aa, aa, d);
      if (coverage <= 0.001) discard;
      vec2 n;
      float bend = glassBend(d, n);
      vec4 c = glassSample(n, bend) * vColor;
      float a = c.a * coverage;
      outColor = overRim(vec4(c.rgb * a, a), glassRim(d, n, bend) * coverage);
      if (outColor.a <= 0.001) discard;
      return;
    }
    vec4 c = texture(textures[nonuniformEXT(vTextureIndex)], vUv) * vColor;
    if (c.a <= 0.001) discard;
    outColor = vec4(c.rgb * c.a, c.a);
    return;
  }

  float coverage;
  float rim = 0.0;
  if (vKind == 1u) { // Glyph
    coverage = texture(textures[nonuniformEXT(vTextureIndex)], vUv).r;
  } else { // Sdf (kind 0); Mesh never reaches this shader
    float d = sdRoundBox(vLocal, vHalfSize, vRadius);
    // A fill has nothing under it to bend, so glass on one is the rim alone —
    // drawn over the tint, which is why a glass view puts it here and not
    // on the backdrop beneath, where the tint would bury it.
    if (vGlass.y > 0.0) {
      vec2 n;
      rim = glassRim(d, n, glassBend(d, n));
    }
    // The antialias width comes from the *unfolded* field — see quad.frag.
    float aa = max(fwidth(d), 1e-5);
    // vAux > 0 asks for an outline of that width instead of a fill.
    if (vAux > 0.0) d = abs(d + vAux * 0.5) - vAux * 0.5;
    // Sharp box: full coverage inside, none outside. SDF AA on r=0
    // eats ~1px on every edge — see quad.frag, including why a sub-pixel
    // band is the one case that must antialias instead.
    if (vRadius < 0.5 && (vAux <= 0.0 || vAux >= 1.0)) {
      coverage = d <= 1e-4 ? 1.0 : 0.0;
    } else {
      coverage = 1.0 - smoothstep(-aa, aa, d);
    }
  }
  if (coverage <= 0.0) discard;
  vec4 c = vec4(vColor.rgb, vColor.a * coverage);
  outColor = vec4(dither(c.rgb * c.a), c.a);
  if (rim > 0.0) outColor = overRim(outColor, rim * coverage);
}
