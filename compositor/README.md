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
