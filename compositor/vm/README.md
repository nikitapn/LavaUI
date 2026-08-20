The install-test VM now lives at the repo root: `vm/cloud-init`,
`scripts/vm-init`, `scripts/vm-run`, `scripts/vm-ssh`.

It mounts the whole LavaUI tree (meson is at the root, not in this
directory) and runs `scripts/bootstrap.sh`. See `docs/install.md`.
