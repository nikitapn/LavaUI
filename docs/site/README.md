# LavaUI docs site

The documentation site at lavaui.nikitapn.com. It is NPRPC's docs site
(`nprpc/docs/site`) with LavaUI's name on it: an NPRPC page handler renders
Mustache templates from an `api.json`, and htmx handles navigation and
search. There is no JavaScript build and no Node; the vendored scripts are
served as they are.

```sh
scripts/docs-api.sh                    # Swift modules + IDL + guides -> .build/docs/api.json
cd docs/site && swift build --product docs-server
DOCS_TEMPLATE_RELOAD=1 ./.build/debug/docs-server    # http://localhost:8080
```

`api.json` is reloaded when it changes, so rerunning `scripts/docs-api.sh`
shows up on the next request. A broken file keeps the last good copy and logs
why.

## Where the content comes from

`scripts/docs-api.sh` runs nprpc's **npdoc**, unchanged, on three inputs:

| Input | How |
|---|---|
| `LavaUI`, `LavaHost`, `LavaClient`, `LavaText`, `LavaMenu` | Swift symbol graphs, which the compiler writes during a build under `.build/docs/swift-build` (a scratch path of its own, so the extra flags do not invalidate `.build`) |
| `idl/lava.npidl` | `npidl --doc-json`, shown as "Control plane" |
| `docs/site/guides/*.md` | the guides |

It finds npdoc and npidl in the nprpc checkout (`third-party/nprpc` or
`../nprpc`); `NPDOC=` and `NPIDL=` override that. npdoc exists only where
nprpc's CMake found libclang, md4c and Boost.ProgramOptions.

The API pages are only as good as the `///` comments in the source. The home
page shows how many declarations each module documents.

### Guides

`guides/` holds the pages the site shows. Most are symlinks into `docs/`,
because much of `docs/` is design history and app notes that someone learning
the framework does not need. To publish a note, link it here:

```sh
ln -s ../../performance.md docs/site/guides/performance.md
```

The title is the file's first `# ` heading. Links between guides become site
links. A relative link to anything else (`issues.md`, `../AGENTS.md`) goes to
the file on GitHub. The reading order at the top of the sidebar is
`Site.guideOrder`; the rest are alphabetical.

## Layout

| Path | What |
|---|---|
| `Sources/DocsModel` | `api.json` → pages, URLs, anchors, cross-links, search. Identical to NPRPC's; tested in `Tests/`. |
| `Sources/DocsWeb` | routing, view models, template loading. `Site.swift` holds what differs from NPRPC's site: name, module list and order, guide order, the GitHub base URL. |
| `Sources/docs-server` | the executable |
| `templates/` | Mustache; `layout` wraps every full page |
| `web/` | static root: `style.css`, `code.js` (syntax highlighting), `vendor/` (htmx, highlight.js) |

To pick up a fix from NPRPC's site, copy the changed files across. Keep
`DocsModel` byte-identical, so that stays a plain copy.

## URLs

- `/api/swift/<Module>`: every top-level declaration in one module.
- `/api/swift/<Module>/<Type>`: one page per top-level declaration, and per
  anything with members. Members appear on their parent's page under an
  anchor.
- `/api/idl`: the control plane.
- `/guide/<name>`: `guides/<name>.md`.
- `/search?q=`: the header box fetches a short list as you type.

Inline code that names exactly one symbol, like `` `VStack` ``, becomes a
link to it.

## Configuration

| Variable | Default |
|---|---|
| `DOCS_API` | `../../.build/docs/api.json` |
| `DOCS_ROOT` | current directory (holds `templates/` and `web/`) |
| `DOCS_PORT` | `8080` |
| `DOCS_HOSTNAME` | `localhost` |
| `DOCS_TLS_CERT`, `DOCS_TLS_KEY` | unset: plain HTTP. `SIGHUP` re-reads them. |
| `DOCS_HTTP3` | unset; `1` also serves HTTP/3 (needs TLS) |
| `DOCS_TEMPLATE_RELOAD` | unset; `1` re-reads templates per request |

## Deploying

`deploy/deploy.sh` publishes the site the same way NPRPC's is published: to
the Docker host behind npquicrouter, on the shared `nprpc-runtime` image. It
builds `api.json` on this machine (the symbol graphs need LavaUI's own
packages to compile), compiles a release `docs-server` in `nprpc-dev`, and runs
the container on the server's loopback.

```sh
docs/site/deploy/deploy.sh --ssh debian@nikitapn.com
docs/site/deploy/deploy.sh --help
```

The images come from nprpc (`just build-dev-image`, `just
build-runtime-image`). The script refuses to deploy if the two differ.

### The hostname, once

For `lavaui.nikitapn.com` on loopback port 9444 (NPRPC's site uses 9443):

1. **DNS:** an `A` record (and `AAAA` for IPv6) pointing at the server.
2. **Router:** add a route to npquicrouter's config and restart it:
   ```json
   { "sni": "lavaui.nikitapn.com", "tcp_backend": "127.0.0.1:9444", "udp_backend": "127.0.0.1:9444" }
   ```
3. **Certificate:** once DNS resolves:
   ```sh
   sudo certbot certonly --webroot -w /var/www/acme -d lavaui.nikitapn.com \
     --deploy-hook 'docker kill -s HUP lavaui-docs'
   ```
4. **Deploy** with the script above.
