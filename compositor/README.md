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

## The shell

The compositor starts the panel and the dock itself, once the Wayland socket
and the control plane are up, and keeps them running. Not a session manager
reading autostart files — these are as much part of this desktop as the window
frames are, and a session that came up without them would be a bug rather than
a configuration.

Two failures, handled separately because they look nothing alike. A component
that **ends** is seen through `SIGCHLD`, which the compositor gets because it
is the parent. A component that is **still running and has stopped drawing** is
invisible to the operating system, so clients say so themselves: every LavaUI
client sends `Heartbeat` every two seconds, from inside its frame loop rather
than from the thread that times it — a beat that has to pass through the loop
that draws is the only kind that proves the loop is turning. Miss enough of
them and the component is asked to go, then made to.

Either way it comes back, after a delay that grows if it keeps happening
(250 ms → 20 s) and with a point past which the compositor stops trying and
says why. Only the components it started are watched; every other client sends
heartbeats too and they are ignored, so there is no supervised mode for a
client to get wrong.

`[shell]` in the config points them elsewhere or turns one off, and
`LAVA_NO_SHELL=1` turns the lot off for one run — which is what you want when
running the dock under a debugger.

A session is two builds, though: the compositor and canvas are meson's, the
components are SwiftPM's, and a component is found by searching beside the
compositor, then `.build/debug`, then `.build/release`, then PATH. Debug first
means a release compositor left to itself comes up running debug components,
and says nothing about it — the numbers you then measure are half of one build
and half of the other. `LAVA_SHELL_DIR` settles it by naming the directory to
look in first, and `scripts/dev-run -r` sets it while building both halves
release, so the flag is the whole of what you have to remember.

Every client also costs shared memory before it has drawn anything: two nprpc
rings, one each way, created by the compositor and resident for the life of
the window. They are asked for at 4 MiB in `control_plane.cpp` rather than
left at nprpc's 1 MiB default, and only because of `CaptureSurface` — a
screenshot is a whole window as a PNG in one reply, measured at 542 KiB for a
1280×720 window with album art, and a ring that cannot carry one turns the
agent's screenshot into a timeout. Everything else here is input events,
`Present` and heartbeats, which would fit a hundred times over.

That memory comes back when a window closes and does *not* when the process
is killed — one that runs no destructor removes nothing, and a client ending
with `exit()` is no different, which is how every LavaUI client ends. So both
halves are swept by whoever comes next rather than by whoever left: a new
compositor clears stale `nprpc_*` rings before creating its own, and a new
client clears stale `lava-arena-*` before creating its own. The second is a
sweep per client rather than per session because the arenas that pile up are
launcher invocations — dozens between one compositor start and the next.
`/dev/shm` filling up is a thing that used to happen and no longer should.

**Alt+P** opens the application launcher, which is *not* supervised: it is
spawned per invocation and exits as soon as it has launched something or been
dismissed, the way rofi does. A LavaUI client reaches its first frame in about
200 ms, so there is nothing to gain from keeping one resident and holding an
arena for the time nobody is launching anything. It is found in the same places
a supervised component is — beside the compositor, then this repo's SwiftPM
build directory, then PATH.

The list it shows comes from freedesktop desktop entries, which is the only
registry of installed applications Linux has: a directory walk over
`applications/` under each XDG data directory. `Sources/LavaShell` is where
that is implemented, and it is shared with the dock, so an entry the launcher
can read is one the dock can find an icon for.

## Configuration

`$LAVA_CONFIG`, else `$XDG_CONFIG_HOME/lava/lava.conf`, else
`~/.config/lava/lava.conf`. INI-shaped, read at startup and again on `SIGHUP`;
unknown keys are reported and skipped, so a file written for a newer build
still starts an older one. See `src/config.hpp` for every key.

Most of it can now be changed without a text editor: `swift run LavaSettings`
opens a panel over the control plane that applies each change to the *running*
compositor and then writes it here. That write is surgical — it replaces the
values it changes and leaves every other line, comments included, exactly where
you put them — so a hand-tuned file survives being edited by the app, and vice
versa. What it cannot change is what `SIGHUP` cannot either: the `[core]` GPU
settings, which are read once while the backend is being created.

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

Which windows get a bar at all is the client's decision, taken by whether it
asks. A client that creates an `xdg-decoration` object is told "server side"
and gets our frame; one that never creates one is drawing its own header —
GTK has no `xdg-decoration` support at all and always does — and a bar from us
would be the second on the window. X11 says the same thing through its Motif
hint. There is no protocol for a client to advertise *where* its draggable
part is, and none is needed: the client sees the press land on its own header
and sends `xdg_toplevel.move`, which starts the same interactive move a drag
on our title bar does. `_NET_WM_MOVERESIZE` is the X11 spelling.

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
