#version 450
#extension GL_EXT_nonuniform_qualifier : require

// See quad.vert. Coverage / sample paths:
//   kind 0 — rounded-box SDF (rect / round-rect / circle / stroked line).
//   kind 1 — glyph coverage from the R8 atlas (`.r` * tint).
//   kind 2 — full-color image (RGBA sample * tint). The vertex selects an
//            entry in the frame's bindless descriptor table.
//   kind 3 — flat-filled mesh (arbitrary polygon). The triangle boundary
//            already *is* the shape's edge, so there is no distance function
//            to evaluate — full coverage everywhere the rasterizer covers.
//
// Solid shapes still sample the bound texture (usually a white texel), so one
// descriptor table is enough.
//
// Output is **premultiplied** and the pipeline blends with ONE /
// ONE_MINUS_SRC_ALPHA. Over an opaque target that is identical to straight
// alpha with SRC_ALPHA / ONE_MINUS_SRC_ALPHA, so nothing about the normal path
// changes. It matters for content blur: that renders a subtree into a target
// cleared to transparent black and then runs a Gaussian over it, and a Gaussian
// may only be applied to premultiplied colour. Averaging straight alpha pulls
// the colour of fully transparent texels — black — into every edge, which shows
// up as a dark halo around everything blurred.
layout(location = 0) in vec2      vLocal;
layout(location = 1) in vec2      vHalfSize;
layout(location = 2) in float     vRadius;
layout(location = 3) in vec4      vColor;
layout(location = 4) flat in uint vKind;
layout(location = 5) flat in float vAux;
layout(location = 6) in vec2      vUv;
layout(location = 7) flat in uint vTextureIndex;

layout(binding = 0) uniform sampler2D uTextures[];

layout(location = 0) out vec4 outColor;

// Signed distance to a rounded box centred at the origin.
float sdRoundBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
  vec4 c;

  if (vKind == 5u) {
    // Drop shadow: the same rounded box, faded outwards over `vAux` pixels.
    //
    // A distance field is already the exact thing a blur approximates — how
    // far a pixel is from the shape — so the falloff is a curve over that
    // distance rather than a pass over an image of the window. `smoothstep`
    // rather than a straight ramp because a linear edge reads as a band; this
    // is not a Gaussian, and at these radii nobody can tell.
    float ds = sdRoundBox(vLocal, vHalfSize, vRadius);
    float blur = max(vAux, 1e-4);
    float fall = 1.0 - smoothstep(0.0, blur, max(ds, 0.0));
    float av = vColor.a * fall * fall;
    if (av <= 0.002) {
      discard;
    }
    outColor = vec4(vColor.rgb * av, av);
    return;
  }

  if (vKind == 4u) {
    // Window corner mask. Drawn with the mask pipeline, where the blend is
    // `dst *= src.a` — so this emits coverage as alpha and nothing else, and
    // the colour is multiplied by zero on its way in.
    //
    // The inverse of every other path here: those discard where a shape is
    // empty, and empty is exactly what this one has to write. A corner the
    // shape does not cover is a corner that must end up transparent, so the
    // discard is on the *inside* instead — the interior is left untouched
    // rather than multiplied by an almost-one, which would otherwise dim a
    // whole window by a rounding error every frame.
    float dm = sdRoundBox(vLocal, vHalfSize, vRadius);
    float aam = max(fwidth(dm), 1e-5);
    float covm = 1.0 - smoothstep(-aam, aam, dm);
    if (covm >= 0.999) {
      discard;
    }
    outColor = vec4(0.0, 0.0, 0.0, covm);
    return;
  }

  if (vKind == 6u) {
    // Frosted backdrop, cut to the shape of the panel it sits under.
    //
    // Both halves at once, which is why it needs its own kind: the blur result
    // is sampled through `vUv` while `vLocal` stays in SDF space, so the
    // composite can have corners. Square ones were visible as bright tabs
    // poking out from behind every rounded glass panel — the frost is a
    // rectangle and the fill over it is not.
    //
    // The source is opaque and premultiplied (it is a capture of the frame),
    // so coverage scales colour and alpha together.
    float db = sdRoundBox(vLocal, vHalfSize, vRadius);
    float aab = max(fwidth(db), 1e-5);
    float covb = 1.0 - smoothstep(-aab, aab, db);
    if (covb <= 0.0) {
      discard;
    }
    vec4 cb = texture(uTextures[nonuniformEXT(vTextureIndex)], vUv) * vColor;
    float ab = cb.a * covb;
    if (ab <= 0.001) {
      discard;
    }
    outColor = vec4(cb.rgb * ab, ab);
    return;
  }

  if (vKind == 2u) {
    // Image: vLocal holds UV; multiply by vertex color as tint.
    c = texture(uTextures[nonuniformEXT(vTextureIndex)], vLocal) * vColor;
    if (c.a <= 0.001) {
      discard;
    }
  } else if (vKind == 3u) {
    c = vColor;
    if (c.a <= 0.001) {
      discard;
    }
  } else {
    float cov;
    if (vKind == 1u) {
      cov = texture(uTextures[nonuniformEXT(vTextureIndex)], vLocal).r;
      // Text is the one place linear-correct blending looks wrong. The
      // attachment is sRGB, so the blend unit works in linear light, and at
      // half coverage that lands on 0.735 rather than 0.5 once re-encoded:
      // thin stems go pale dark-on-light and clot light-on-dark. Shape edges
      // (below) are wide enough that nobody notices; glyph stems are not.
      //
      // The blend unit is not ours to change without splitting the render pass
      // per text batch, so bend the coverage instead. Which way to bend
      // depends on whether the glyph is darker or lighter than what is behind
      // it, and the glyph's own lightness stands in for that — UI text sits on
      // a contrasting background almost by definition. Same trick as Skia's
      // gamma LUT, minus the table.
      //
      // Exponents are tuned by eye. 0.35/2.2 would match a gamma-space blend
      // exactly at cov = 0.5; both are pulled toward 1.0 to soften it. The
      // assumption fails for text on a low-contrast or frosted backdrop, which
      // is where this would have to become a framebuffer fetch.
      float lum = sqrt(dot(vColor.rgb, vec3(0.2126, 0.7152, 0.0722)));
      cov = pow(cov, mix(0.45, 2.0, lum));
    } else {
      float d = sdRoundBox(vLocal, vHalfSize, vRadius);
      // fwidth gives ~1px of screen-space falloff, so edges antialias without
      // MSAA. Clamped away from zero so degenerate (zero-area) quads don't NaN.
      float aa = max(fwidth(d), 1e-5);
      cov = 1.0 - smoothstep(-aa, aa, d);
    }

    if (cov <= 0.0) {
      discard;
    }
    c = vec4(vColor.rgb, vColor.a * cov);
  }

  outColor = vec4(c.rgb * c.a, c.a);
}
