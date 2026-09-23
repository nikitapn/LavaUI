#!/usr/bin/env bash
# Collect LavaUI's public API and the site's guides into .build/docs/api.json,
# for the documentation site under docs/site.
#
# The extractor is nprpc's npdoc, unchanged: it takes Swift symbol graphs,
# npidl's --doc-json and a directory of Markdown guides. Point NPDOC / NPIDL at
# particular builds to override the search:
#
#   NPDOC=/path/to/npdoc NPIDL=/path/to/npidl scripts/docs-api.sh
#
# Swift has no standalone extractor that copes with C++ interop, so the
# compiler writes the symbol graphs during an ordinary build. That build has a
# scratch path of its own (.build/docs/swift-build): the extra -Xswiftc flags
# would otherwise invalidate every module in .build and the next plain
# `swift build` would recompile the lot.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/lava.sh
source "$ROOT/scripts/lib/lava.sh"

OUT="$ROOT/.build/docs"
# The modules an app imports. LavaIDL is generated from idl/lava.npidl, which
# is documented as IDL instead; the *Core targets belong to their apps.
MODULES=(LavaUI LavaHost LavaClient LavaText LavaMenu)

NPRPC_ROOT_DIR="$(lava_find_nprpc_root || true)"
[[ -n $NPRPC_ROOT_DIR ]] || lava_die "nprpc not found (third-party/nprpc or ../nprpc); see scripts/fetch-nprpc.sh"

# npdoc is built only where nprpc's CMake found libclang, md4c and Boost, so it
# is not necessarily in the build dir npidl comes from: take the newest.
if [[ -z ${NPDOC:-} ]]; then
  NPDOC="$(ls -t "$NPRPC_ROOT_DIR"/.build*/npdoc/npdoc 2>/dev/null | head -n1 || true)"
fi
[[ -x ${NPDOC:-} ]] || lava_die "npdoc not found under $NPRPC_ROOT_DIR/.build*/npdoc/; build it there (cmake --build <dir> --target npdoc) or set NPDOC="

NPIDL="$(lava_find_npidl || true)"
[[ -x ${NPIDL:-} ]] || lava_die "npidl not found; build nprpc (scripts/build-nprpc.sh) or set NPIDL="
"$NPIDL" --help 2>&1 | grep -q -- --doc-json \
  || lava_die "$NPIDL predates --doc-json; rebuild it or set NPIDL= to a newer one"

mkdir -p "$OUT/swift-symbols"
graphs=()
for module in "${MODULES[@]}"; do
  lava_info "symbol graph: $module"
  swift build --package-path "$ROOT" --target "$module" \
    --scratch-path "$OUT/swift-build" \
    -Xswiftc -emit-symbol-graph -Xswiftc -emit-symbol-graph-dir -Xswiftc "$OUT/swift-symbols" \
    -Xswiftc -symbol-graph-minimum-access-level -Xswiftc public
  graphs+=(--swift-symbols "$OUT/swift-symbols/$module.symbols.json")
done

"$NPIDL" --doc-json --output-dir "$OUT" "$ROOT/idl/lava.npidl"

# docs/site/guides holds the pages the site shows, most of them links to the
# notes in docs/: much of docs/ is design history nobody learning the
# framework needs.
"$NPDOC" --root "$ROOT" \
  "${graphs[@]}" \
  --idl "$OUT/lava.doc.json" \
  --guides "$ROOT/docs/site/guides" \
  --out "$OUT/api.json"

lava_info "API docs: $OUT/api.json"
