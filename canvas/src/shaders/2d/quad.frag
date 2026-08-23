#version 450
#extension GL_EXT_nonuniform_qualifier : require

// See quad.vert. Coverage / sample paths:
//   kind 0 — rounded-box SDF (rect / round-rect / circle / stroked line).
//            `vAux` > 0 makes it an outline of that width instead of a fill.
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
// Output is **premultiplied** and the pipeline blends colour with ONE /
// ONE_MINUS_SRC_ALPHA. Over an opaque target that is identical to straight
// alpha with SRC_ALPHA / ONE_MINUS_SRC_ALPHA, so nothing about the normal path
// changes. It matters for content blur: that renders a subtree into a target
// cleared to transparent black, and every stage that follows averages texels —
// the filtered capture blit, then the Dual Kawase pyramid down and back up. A
// weighted average may only be taken of premultiplied colour. Averaging
// straight alpha pulls the colour of fully transparent texels — black — into
// every edge, which shows up as a dark halo around everything blurred.
//
// The *alpha* channel blends ONE / ONE_MINUS_SRC_ALPHA for a separate reason,
// unrelated to premultiplication: `over` on alpha is `a_s + a_d * (1 - a_s)`,
// with no factor of a_s on the source term.
//
// Everything here is in **sRGB-encoded** space, not linear light: the colour
// attachment is UNORM, vertex colours arrive as authored, and sampled textures
// are UNORM too, so no transfer function is applied anywhere in the pipeline.
//
// That is deliberate, and it is what the surface handover requires. The engine
// renders into a dma-buf a wlroots compositor blends with premultiplied
// ONE / ONE_MINUS_SRC_ALPHA on the raw bytes, in encoded space. Wayland's
// premultiplied contract therefore lives in *bytes*: a pixel must satisfy
// `rgb <= a` after encoding. Premultiplying in linear light and letting an
// sRGB attachment encode on the way out does not — `encode(L*a) > encode(L)*a`
// for every 0 < a < 1, because the transfer curve is concave — so every
// partially transparent pixel shipped too bright and the compositor added the
// excess on top of the desktop. That was a light rim around any antialiased
// edge crossing onto the transparent part of a surface, clipping to white on
// pale shapes and invisible on dark ones. Blending in the space the buffer is
// encoded in is what every other UI toolkit does, and for the same reason.
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
      // Coverage straight through. This used to be bent by a luminance-keyed
      // exponent to undo linear-light blending — the attachment was sRGB, so
      // half coverage re-encoded to 0.735 and thin stems went pale
      // dark-on-light. The attachment is UNORM now and the blend unit works
      // in the same encoded space the coverage is authored in, so 0.5 stays
      // 0.5 and the correction would be the distortion.
      cov = texture(uTextures[nonuniformEXT(vTextureIndex)], vLocal).r;
    } else {
      float d = sdRoundBox(vLocal, vHalfSize, vRadius);
      // Taken before the fold below. `abs` creases the field along the middle
      // of a stroked band, and `fwidth` measured across that crease reports a
      // slope the geometry does not have — a bright seam down the centre of
      // any border more than a pixel or two wide.
      float aa = max(fwidth(d), 1e-5);
      // `vAux` > 0 asks for an outline of that width rather than a fill.
      // Folding the distance about a line half a width inside the edge leaves
      // exactly the band between the edge and `vAux` short of it, so the
      // border lies wholly within the rect it was given — the same place CSS
      // and SwiftUI put one. Nothing else changes: the inner boundary is the
      // true inward offset of the shape, so a rounded rect gets a concentric
      // arc of radius `vRadius - vAux`, and a border thicker than the radius
      // fills its corners solid, which is what that offset degenerates to.
      if (vAux > 0.0) {
        d = abs(d + vAux * 0.5) - vAux * 0.5;
      }
      // A sharp box must not pay the SDF antialias. Pixel centres sit
      // 0.5px inside a d=0 edge, so smoothstep(-aa, aa, d) lands around
      // 0.75 and every side of a panel or a fill reads as a 1px hole
      // (the neighbour is clear, or another window). Rounded shapes
      // keep the falloff — that is what the radius is for. The quad
      // is already padded 1px (`pushBox`) so the discarded outside
      // still has fragments to reject.
      //
      // A square border's edges are axis-aligned on both sides of the band,
      // so it wants the same crisp treatment: antialiasing a whole-pixel
      // hairline from both directions would halve its alpha and wash it out.
      //
      // A band *thinner* than a pixel is the exception, and has to antialias.
      // Hard coverage can only answer 0 or 1, so the honest rendering of a
      // half-pixel border — a line at half alpha — is not available to it. It
      // is worse than that: at width 0.5 the folded distance is exactly 0 at
      // every pixel centre along the edge, so each of the four sides is
      // decided by whichever way the rounding falls. That drew a box with one
      // edge.
      //
      // The epsilon covers the same tie for wider bands. Every half-integer
      // width puts the inner edge on a pixel centre too; without it a 1.5px
      // border comes out 2px on some sides and 1px on others, for the same
      // reason and with the same floating-point luck deciding which.
      if (vRadius < 0.5 && (vAux <= 0.0 || vAux >= 1.0)) {
        cov = d <= 1e-4 ? 1.0 : 0.0;
      } else {
        cov = 1.0 - smoothstep(-aa, aa, d);
      }
    }

    if (cov <= 0.0) {
      discard;
    }
    c = vec4(vColor.rgb, vColor.a * cov);
  }

  outColor = vec4(c.rgb * c.a, c.a);
}
