#!/usr/bin/env bash
# Compatibility wrapper — use packaging/install.sh for every app.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
exec "$here/../install.sh" LavaWeather "$@"
