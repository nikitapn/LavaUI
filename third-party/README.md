# Third-party checkouts

This directory is for source trees Lava builds but does not vendor.

## nprpc

The compositor control plane and `LavaClient` talk NPRPC over shared memory.
That code lives in a separate repo:

https://github.com/nikitapn/nprpc

`scripts/fetch-nprpc.sh` puts it here (or symlinks a sibling `../nprpc`,
which is the layout this project was developed with). Meson, Package.swift
and `scripts/gen_stubs.sh` all look in this order:

1. `NPRPC_ROOT` / `NPRPC_SWIFT_PATH`
2. `third-party/nprpc`
3. `../nprpc`

It is gitignored on purpose. A windowed LavaUI build does not need it;
`meson setup` without it still produces a compositor, just without a
control plane. Only `unordered_dense` and `glaze` are fetched as
submodules — Lava does not enable QUIC or HTTP/3.

```sh
scripts/fetch-nprpc.sh
scripts/build-nprpc.sh
```

## wlroots

The compositor builds wlroots itself, as a static meson subproject:
`wlroots.wrap` pins 0.19.3 and `packagefiles/wlroots/` holds patches of
ours on top. `meson setup` clones it into `third-party/wlroots` on first
run and applies them; that checkout is gitignored, the wrap and the
patches are not. `-Dwlroots=system` links the installed `wlroots-0.19`
instead, without the patches.

Meson applies the patches only when it fetches, so a `third-party/wlroots`
that was already there is used as it is. `compositor/meson.build` checks for
the first patch and refuses an unpatched tree; delete the directory and
set up again.

The patches:

- `0001-backend-drm-copy-cursor-on-the-CPU…` — on a hybrid laptop the
  output wired to the NVIDIA GPU never got a hardware cursor. wlroots blits
  the cursor on the secondary GPU, which needs that GPU's renderer to draw
  into something its cursor plane takes; nvidia-drm's cursor plane takes
  only LINEAR and NVIDIA's Vulkan driver renders only block-linear, so every
  cursor image failed with "Failed to pick cursor plane format" and the
  output fell back to a software cursor. The patch copies the (already
  LINEAR) cursor buffer on the CPU into a LINEAR dumb buffer on that device
  instead. Upstream has only
  [!5478](https://gitlab.freedesktop.org/wlroots/wlroots/-/merge_requests/5478),
  which gives up on the hardware cursor sooner and more quietly.

When the system build is wanted and `pkg-config` cannot see `wlroots-0.19`,
`scripts/build-wlroots.sh` clones 0.19.3 into `third-party/wlroots-system`
and installs it to `/usr/local`. Debian 13 and Ubuntu 24.04 still ship
0.18/0.17; Arch extra has moved on to 0.20.
