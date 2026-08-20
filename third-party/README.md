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

When `pkg-config` cannot see `wlroots-0.19`, `scripts/build-wlroots.sh`
clones 0.19.3 here and installs it to `/usr/local`. Debian 13 and Ubuntu
24.04 still ship 0.18/0.17; Arch extra has moved on to 0.20. A machine
that still has `wlroots0.19` installed skips this.
