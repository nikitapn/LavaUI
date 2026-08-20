#!/usr/bin/env bash
# Build the Debian and/or Arch images. A successful image means
# install-deps + nprpc + meson test + swift test all passed inside it.
#
#   scripts/docker-test.sh            # both
#   scripts/docker-test.sh debian
#   scripts/docker-test.sh arch
#
# Reuses a sibling ../nprpc or an existing third-party/nprpc so the image
# does not have to hit GitHub for NPRPC. Pass LAVA_NPRPC_REF to pin a tag.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/lava.sh
source "$here/lib/lava.sh"

targets=()
if [[ $# -eq 0 ]]; then
  targets=(debian arch)
else
  for a in "$@"; do
    case "$a" in
      debian|arch) targets+=("$a") ;;
      -h|--help)
        sed -n '2,12p' "$0" | sed 's/^# \?//'
        exit 0
        ;;
      *) lava_die "unknown target: $a (debian|arch)" ;;
    esac
  done
fi

command -v docker >/dev/null || lava_die "docker not on PATH"

# Populate third-party/nprpc in the build context when we already have it.
"$here/fetch-nprpc.sh"

for t in "${targets[@]}"; do
  tag="lava-test:$t"
  file="$LAVA_ROOT/docker/$t.Dockerfile"
  lava_info "building $tag from $file (this downloads Swift the first time)"
  docker build \
    --file "$file" \
    --tag "$tag" \
    --build-arg "LAVA_SWIFT_VERSION=$LAVA_SWIFT_VERSION" \
    "$LAVA_ROOT"
  lava_info "$tag ok"
done

lava_info "all requested images built"
