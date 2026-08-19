# Colour and blending

Which colour space each part of the renderer works in, and what that costs.
Worth reading before picking any alpha value, tuning a palette, or wondering
why something looks different here than in Figma.

## The short version

| Stage | Space |
|---|---|
| Authoring (`Color`, hex, a picker) | **sRGB** — `Color(r: 0.5)` is `#808080` |
| Storage (`Color.rgba8`, vertex attributes) | **sRGB**, 8-bit |
| Blending (every attachment is `*_UNORM`) | **sRGB**, the same encoded bytes |
| Output (swapchain, exported dmabuf) | **sRGB**, stored as-is |

Nothing in the 2D pipeline applies a transfer function. A colour authored as
`#808080` is packed as `0x80`, interpolated as `0x80`, blended as `0x80` and
handed to the compositor as `0x80`. Vertex shaders pass colours straight
through and the attachment stores what the fragment wrote.

This is what CSS, Skia, Cairo/GTK and Qt all do. We are no longer the outlier,
and a mockup's "90% opacity" now means here what it means in Figma.

The one deliberate exception is the CPU image downscale in
`Engine::decodeImage`, which uses `stbir_resize_uint8_srgb`. Resampling
averages *light*, and a big reduction is where getting that wrong is visible
(the classic too-dark album art). It decodes, resizes and re-encodes inside
the call; the bytes either side of it are sRGB like everything else.

Alpha is never encoded, here or anywhere. The sRGB curve is a perceptual
encoding of *luminance*, and alpha is a coverage fraction, not light.

## Why not linear

Blending in linear light is more physically correct, and until 2026-08-19
that is what this did: every attachment was `*_SRGB`, `srgb.glsl` decoded
vertex colours, and the attachment re-encoded on store.

It had to go, because it is incompatible with handing the frame to a
compositor. A Wayland buffer's alpha is **premultiplied in the buffer's own
encoding** — the contract is `rgb <= a` on the stored bytes. Premultiplying in
linear light and encoding afterwards stores `encode(L·a)`, and

```
encode(L·a) > encode(L)·a      for every 0 < a < 1
```

because the transfer curve is concave. Every partially transparent pixel was
shipped too bright. wlroots then blends those bytes with
`ONE / ONE_MINUS_SRC_ALPHA` and adds the excess on top of the desktop, which
is an *additive* overshoot — the result exceeded both the source and the
background and clipped to white.

The symptom was a light rim wherever an antialiased edge crossed onto the
transparent part of a surface: a dock icon or count badge lifting off the
plate, a rounded window corner. It was invisible at `a = 0` and `a = 1`, where
the identity holds exactly, and it scaled with the source's brightness, so
dark shapes looked fine and pale ones shouted. Measured on a white window's
corner arc over a near-black desktop: the arc read `255,255,255` against a
window body of `235,237,240`.

There is no way to keep linear blending and fix this short of an extra
full-screen re-premultiply pass, at 8-bit precision, every frame.

### What that cost

- **Blur** now averages encoded values. A Gaussian is properly an average of
  light, so frosted panels are slightly different — the same slightly-wrong
  every browser's `backdrop-filter` is.
- **Texture filtering and mipmaps** likewise.
- **Gradients** interpolate in encoded space. For a two-stop ramp between
  nearby colours the difference is small; a ramp across a hue is where it
  would show.

### What it did *not* cost

`Scene3D`. The old version of this document rejected a UNORM main pass on the
grounds that lighting in gamma space is wrong. That reasoning was mistaken:
lighting never used the blend unit. `Spatial.swift`'s `litColor` decodes with
`Color.linear`, multiplies, and re-encodes with `Color.fromLinear` on the CPU,
then sends an ordinary authored colour down the same wire as everything else.
It behaved identically before and after — verified by rendering the same scene
against both builds.

## Alpha means what you expect now

The old pipeline made low alpha nearly useless: the sRGB encode is
near-vertical near black, so a small linear residue became a large encoded
one, and the useful range of a window wash was 0.98–1.0. That is gone. What
shows through at alpha `a` is now simply `(1 − a)` of the background.

**Anything tuned against the old behaviour is now too solid.** A value chosen
to let 7% of the desktop through was ~0.99 before and is 0.93 now.
`TerminalPalette.windowAlpha` is the known one; see its comment.

## Text is no longer corrected

`quad.frag` used to bend glyph coverage (`pow(cov, mix(0.45, 2.0, lum))`)
because linear-correct blending landed half coverage on 0.735 once re-encoded,
making thin stems pale dark-on-light and clotted light-on-dark. The blend unit
now works in the space the coverage is authored in, so 0.5 stays 0.5 and the
correction would be the distortion. It was removed with the format change.

`quad_instance.frag`'s glyph path never had the bend. The two pipelines now
agree, which they did not before.

## The compositor blends too, and it is not ours

A window's alpha over the *desktop* is blended by wlroots, not by us.
Measured on wlroots' **Vulkan** renderer: it samples our `ARGB8888` and blends
it in **encoded space**, and its output buffer is stored without re-encoding.
Both the background rect colour and an opaque window fill survive the round
trip byte-exact, which they could not if a transfer function were applied at
either end.

An older version of this document claimed the Vulkan renderer imports as
`B8G8R8A8_SRGB` and blends linear. Whatever was once true, it is not the
behaviour of the renderer we run against — that claim is what made an
inconsistent pipeline look consistent on paper.

DRM fourccs carry no transfer function, so we cannot influence the choice, and
now we do not need to: matching the compositor's space is the whole point of
the change.

## 3D lighting converts explicitly

`Spatial.swift`'s `litColor` decodes the surface colour *and* every light
colour with `Color.linear`, multiplies there, and re-encodes with
`Color.fromLinear` before the result goes anywhere. Both conversions are
needed: a light's colour is as much a colour as the surface it falls on.

It converts back rather than emitting linear components because the wire
format is 8-bit sRGB. Handing it linear values would spend those 8 bits on
highlights instead of shadows, which is the one thing sRGB storage exists to
avoid.

This was a bug until 2026-08-14: the multiply ran on authored components, so
shading landed on `dec(base)·k^2.4` instead of `dec(base)·k` and a face at
half light came out at 44% of where it belonged. **Any `Scene3D` content
authored before that date was tuned against it.** With the default lights
(ambient 0.3, directional 0.9) over a 0.8 surface:

| face | before | after |
|---|---|---|
| unlit (N·L = 0) | 0.240 | 0.463 |
| half-lit | 0.600 | 0.703 |
| fully lit | 0.960 | 0.867 |

Shadows lift a lot, highlights come down slightly — the old version was
over-driving into the clamp. The net effect is flatter, so a scene that
looked right before will want less ambient rather than more: **0.078**
reproduces the old shadow depth exactly, against a default of 0.3.
