# wlroots compositor playground

A minimal C++20/wlroots 0.19 compositor and a QEMU development VM. The first
milestone intentionally renders only a dark background; xdg-shell and input
handling come next.

## Start the VM

Host requirements: `qemu-system-x86_64`, `qemu-img`, `curl`, and `xorriso`.

```sh
scripts/vm-init
scripts/vm-run
```

The first boot downloads build dependencies and builds wlroots 0.19.3, so it
can take several minutes. Watch progress on the serial console. When cloud-init
finishes, the graphical QEMU window changes to the compositor's dark blue
background. QEMU's default grab release shortcut is `Ctrl+Alt+G`.

The source tree is shared read-only with the guest. Restarting the service
copies the latest source, rebuilds it, and launches it on the virtual DRM GPU:

```sh
scripts/vm-ssh sudo systemctl restart compositor
scripts/vm-ssh sudo journalctl -u compositor -f
```

The development account is `dev` with password `dev`. SSH is forwarded only to
localhost on port 2222. This deliberately convenient configuration is for an
isolated development VM, not production.

## Configuration

`$LAVA_CONFIG`, else `$XDG_CONFIG_HOME/lava/lava.conf`, else
`~/.config/lava/lava.conf`. INI-shaped, read at startup and again on `SIGHUP`;
unknown keys are reported and skipped, so a file written for a newer build
still starts an older one. See `src/config.hpp` for every key.

```ini
[core]
renderer = vulkan

[keyboard]
layout = us

[appearance]
# Window corner radius in pixels. 0 (the default) is square; clamped to 64.
corner-radius = 10
# Drop shadow under the *focused* window. blur 0 (the default) turns it off.
shadow-blur = 24
shadow-opacity = 0.35
shadow-offset-y = 4

[output DP-3]
mode = 2560x1440@144
position = 0,0
```

`corner-radius` applies to what the compositor draws — LavaUI clients and the
title bars above them — and takes effect on `SIGHUP` without restarting
anything, because it is a number the renderer reads per frame rather than a
property baked into a surface. Wayland clients keep square corners: their
pixels are their own buffer, composited by `wlr_scene`, which has no per-node
shader hook. Rounding those means compositing the scene by hand.

A Wayland window is therefore square *including* its title bar, and its shadow
is square too. Rounding only the bar would round two corners of a rectangle
whose other two stay sharp, and the shadow behind it could match one end or the
other but not both — square all the way round is the version that looks
finished rather than half-applied.

The shadow is cast by the **focused window only**, which is what says a window
is active — no border tint to go and look for. Unlike rounding it works for
Wayland clients as well, because a shadow is drawn on a surface *behind* the
window and needs nothing from the window's own pixels. It is a shape rather
than a blurred picture of anything: the compositor knows the rectangle a window
occupies, and a distance field describes what falls outside it exactly, so
nothing is sampled or blurred per frame.

## Useful commands

```sh
# Inspect first-boot provisioning
scripts/vm-ssh cloud-init status --wait
scripts/vm-ssh sudo journalctl -u cloud-final -f

# Rebuild without restarting
scripts/vm-ssh sudo /usr/local/sbin/build-compositor

# Reset the guest while retaining the downloaded base image
rm .vm/compositor.qcow2
scripts/vm-init
```

If `/dev/kvm` is accessible, `vm-run` uses hardware acceleration. Otherwise it
falls back to TCG emulation, which is substantially slower.
