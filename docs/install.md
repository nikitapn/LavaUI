# Installing LavaUI

A Debian or Arch machine should be able to clone this repo, run one script,
and end up with a compositor and the Swift clients. NPRPC is a second
GitHub repo — fetched into `third-party/nprpc`, not vendored — because the
control plane is optional: windowed LavaUI still builds without it.

```sh
git clone --recurse-submodules https://github.com/nikitapn/LavaUI.git
cd LavaUI
./scripts/bootstrap.sh --yes          # debug compositor + clients
# or
./scripts/bootstrap.sh --yes --release
```

`bootstrap.sh` is four steps that can also be run on their own:

| Step | Script | What |
|---|---|---|
| 1 | `scripts/install-deps.sh` | Distro packages. Builds wlroots 0.19 into `/usr/local` when the distro does not have it (Debian 13 / Ubuntu 24.04 still ship 0.17/0.18; Arch extra has moved on to 0.20). Ubuntu 24.04 also gets `g++-14`: the default is GCC 13, which cannot parse nprpc's C++23 `this Self&`. |
| 2 | `scripts/install-swift.sh` | Swift 6.3+ if `swift` is missing or too old. Arch uses the distro package when it is new enough; otherwise the Ubuntu 24.04 tarball from swift.org (Debian has no Swift package). |
| 3 | `scripts/fetch-nprpc.sh` + `scripts/build-nprpc.sh` | Clone https://github.com/nikitapn/nprpc (or reuse `../nprpc`) and build `libnprpc.so` without QUIC/HTTP/3. |
| 4 | meson + `swift build` | Compositor in `build/` (or `build-release/`), clients in `.build/`. |

`--no-nprpc` skips the control plane. `--no-swift` stops after the C++ compositor. `--deps-only` is just the packages. `--check` runs `scripts/check-env.sh`.

A sibling checkout at `../nprpc` — the layout this repo was developed with — is still found automatically. `fetch-nprpc.sh` will symlink it into `third-party/nprpc` so meson does not need `-Dnprpc_root=`.

Then, if you want the apps on the desktop:

```sh
packaging/install.sh          # XDG desktop entries + ~/.local/bin
```

A session on a real GPU is `compositor/scripts/start-lava-compositor`. Nested in the Wayland session you are already in: `compositor/scripts/dev-run`.

## Packages

Canonical lists are `packaging/deps/debian.txt` and `packaging/deps/arch.txt`. `scripts/install-deps.sh --list` prints what this machine would install.

They cover four groups, not just the engine:

- **canvas / LavaUI** — Vulkan, GLFW, FreeType, HarfBuzz, GLM, GLib, libdbusmenu-glib, librsvg, cairo, X11, libdrm, Boost.Stacktrace
- **compositor** — wlroots 0.19, wayland, xkbcommon, pixman, libseat, libinput, libdisplay-info, libliftoff, libsystemd, seatd, Xwayland
- **NPRPC** — Boost headers + program_options, OpenSSL, liburing
- **apps** — libpulse (panel volume)

Software Vulkan (`mesa-vulkan-drivers` / `vulkan-swrast`) is installed so Docker and VMs have lavapipe. A real machine still needs its vendor ICD (`vulkan-radeon`, `nvidia-utils`, `vulkan-intel`).

`scripts/install-deps.sh --vm-host` adds qemu and xorriso for the install-test VM.

## NPRPC and meson

NPRPC is CMake, not meson. It is not a wrap, and it is not a git submodule: both would either drag MsQuic/BoringSSL in or force a clone on people who only want windowed LavaUI.

`scripts/build-nprpc.sh` configures it for what Lava actually calls:

```
-DNPRPC_ENABLE_QUIC=OFF -DNPRPC_ENABLE_HTTP3=OFF -DNPRPC_ENABLE_SSR=OFF
-DNPRPC_BUILD_TESTS=OFF -DNPRPC_BUILD_ROUTER=OFF
-DNPRPC_BUILD_TOOLS=ON          # npidl, for scripts/gen_stubs.sh
```

Only the `glaze` and `unordered_dense` submodules are initialised (SSH remotes in nprpc's `.gitmodules` are rewritten to HTTPS). `--install` runs `cmake --install` into `PREFIX` (default `/usr/local`).

Meson, Package.swift and `scripts/gen_stubs.sh` search, in order:

1. `-Dnprpc_root=` / `NPRPC_ROOT` / `NPRPC_SWIFT_PATH`
2. `third-party/nprpc`
3. `../nprpc`
4. a system `libnprpc` (meson only)

A tree that has the headers but no `libnprpc.so` is a warning, not a silent disable — run `scripts/build-nprpc.sh`.

## Docker

Two images, each running the same scripts a person would:

```sh
scripts/docker-test.sh            # debian + arch
scripts/docker-test.sh debian
scripts/docker-test.sh arch
```

Debian 13 builds wlroots 0.19 from source (trixie still has 0.18). Arch installs `wlroots0.19` when extra still has it, otherwise the same source build. Both run `meson test` and `swift test`; a failed test fails the image.

The first build downloads the Swift tarball (~1 GB) and compiles the engine twice (meson + SwiftPM). Later builds reuse those layers unless `scripts/` or `packaging/deps/` changed.

This does **not** start a compositor or look at pixels. It answers "do the packages and the two build systems still work on a clean Debian/Arch".

## VM

A QEMU guest that is Ubuntu 24.04 on purpose: oldest glibc Swift still publishes, and the Debian-family path that has to compile wlroots 0.19.

```sh
scripts/install-deps.sh --vm-host
scripts/vm-init
scripts/vm-run
```

First boot downloads build deps, wlroots, Swift and NPRPC — several minutes, watch the serial console. The graphical window is the compositor's DRM output on virtio-gpu (GLES2: virtio's Vulkan is not something we rely on). User `dev` / password `dev`, SSH on localhost:2222.

```sh
scripts/vm-ssh sudo journalctl -u lava-compositor -f
scripts/vm-ssh sudo systemctl restart lava-compositor   # rsync + rebuild
```

The source tree is 9p-mounted read-only. Restarting the unit copies it to `/opt/lava` and runs `scripts/bootstrap.sh --release` again. Reset the guest with `rm .vm/lava.qcow2 && scripts/vm-init`.

`compositor/scripts/vm-*` still work; they exec these.

## What this does not do

- It does not package `.deb` / `.pkg.tar`. `packaging/install.sh` is XDG desktop entries for a tree you already built.
- It does not install a display manager or replace the running compositor. `start-lava-compositor` is a DRM session you launch yourself.
- Headless Docker cannot exercise pointer input, decorations, or scanout. That is still a machine with a seat, or this VM's graphical window.
