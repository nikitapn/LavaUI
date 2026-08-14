# Colour and blending

Which colour space each part of the renderer works in, and what that costs.
Worth reading before picking any alpha value, tuning a palette, or wondering
why something looks different here than in Figma.

## The short version

| Stage | Space |
|---|---|
| Authoring (`Color`, hex, a picker) | **sRGB** — `Color(r: 0.5)` is `#808080` |
| Storage (`Color.rgba8`, vertex attributes) | **sRGB**, 8-bit |
| Blending (every attachment is `*_SRGB`) | **linear light** |
| Output (swapchain, exported dmabuf) | **sRGB**, encoded by the attachment |

Vertex shaders decode with `srgb.glsl`; the attachment re-encodes on store. So
a colour makes a round trip and arrives unchanged, but everything that happens
*between* two colours — alpha compositing, gradients, blur, antialiasing —
happens on linear values.

Alpha is never encoded, here or anywhere. The sRGB curve is a perceptual
encoding of *luminance*, and alpha is a coverage fraction, not light. The
Vulkan spec applies the transfer function to RGB only. When alpha behaves
surprisingly it is never because alpha was encoded — it is because the
*colours* it was blended against were linear.

## Why linear

Three things need it, and they are not negotiable:

- **Blur.** A Gaussian is an average of light. Averaging encoded values
  darkens the result; the frosted-glass panels would go muddy.
- **3D lighting.** `Scene3D` shades faces by a light amount. Multiplying is
  only meaningful on linear values (see the known gap below).
- **Texture filtering and mipmaps**, which average texels for the same reason
  a blur does.

## What it costs: alpha does not mean what people expect

This is the part that surprises everyone, so it gets the space.

Almost every UI toolkit composites alpha on the **encoded** values — CSS and
every browser, Skia (so Chrome, Android, Flutter), Cairo/GTK, Qt, and most
Wayland compositors. A designer's mental model of "90% opacity", and every
mockup handed to you, assumes a gamma-space blend. **We are the outlier.**

The difference is not subtle, because the sRGB encode is near-vertical near
black: a small linear residue becomes a large encoded one. Black at alpha `a`
over a wallpaper around 0.8 sRGB:

| alpha | what shows through | in a browser |
|---|---|---|
| 0.90 | 0.27 — grey haze | 0.08 |
| 0.96 | 0.17 | 0.03 |
| 0.98 | 0.11 | 0.02 |
| 0.99 | 0.07 | 0.01 |
| 0.995 | 0.04 | 0.004 |

So **the useful range of a window wash is 0.98–1.0**, and anything below that
is haze rather than tint. `TerminalPalette.windowAlpha` carries this warning
at its definition because 0.99 otherwise reads as an absurd value.

The same applies to every `.opacity()` inside a Lava app, and to animated
fades — a dialog fading 0→1 has a visibly different curve under linear than a
designer expects.

You cannot split the difference. Matching a gamma blend needs
`encode(B·(1−a)) = B_srgb·(1−α)`, and solving for `a` leaves `B` in the
answer — the correction depends on what is *behind* the window. Picking the
blend space is a real choice, not a tunable.

### The alternative we did not take

A UNORM main pass with explicit linearisation only in the blur would give
CSS-like alpha, make gradients interpolate like Figma, and remove the text
hack below. It was rejected because `Scene3D` has lights, and lighting in
gamma space is wrong in a way no amount of tuning fixes. If the 3D path ever
goes away, this is worth revisiting.

## Text is deliberately corrected

`quad.frag` bends glyph coverage before the blend
(`pow(cov, mix(0.45, 2.0, lum))`). Linear-correct blending makes thin stems
pale dark-on-light and clotted light-on-dark; the blend unit is not ours to
change without splitting the render pass per text batch, so the coverage is
bent instead. The exponent is chosen from the glyph's own lightness, which
stands in for the background it contrasts against.

This is the same trick Skia's gamma LUT performs, and the same reason browsers
blend text in gamma space. It is a deliberate inaccuracy that looks right.
Shape edges are left alone — they are wide enough that nobody notices.

## The compositor blends too, and it is not ours

A window's alpha over the *desktop* is blended by wlroots, not by us, and
which space that happens in depends on the renderer:

- **Vulkan** imports our `ARGB8888` as `B8G8R8A8_SRGB` → blends linear.
- **GLES2** samples it as plain `RGBA8` → blends gamma, like a browser.

DRM fourccs carry no transfer function, so we cannot influence the choice.
`start-lava-compositor` asks for Vulkan and `dev-run` used to leave the
default, which is GLES2 — so a translucency tuned nested looked roughly five
times more solid than it did on the desktop it shipped to. `dev-run` now pins
Vulkan. **If the two sessions ever disagree about a translucency again, check
the renderer banner in each log first.**

## 3D lighting converts explicitly

`Spatial.swift`'s `litColor` decodes the surface colour *and* every light
colour with `Color.linear`, multiplies there, and re-encodes with
`Color.fromLinear` before the result goes anywhere. Both conversions are
needed: a light's colour is as much a colour as the surface it falls on.

It converts back rather than emitting linear components because the wire
format is 8-bit and `spatial.vert` linearises unconditionally. Handing it
linear values would decode twice *and* spend those 8 bits on highlights
instead of shadows, which is the one thing sRGB storage exists to avoid.

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
