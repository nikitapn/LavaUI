# Packaging Lava apps for the desktop

Freedesktop desktop entries + icons so **LavaLauncher** (and rofi, Plasma, …)
can find the apps built from this tree.

System packages, NPRPC, Docker and the install-test VM are **not** this
directory — see `docs/install.md` and `packaging/deps/`.

## Install

```bash
# Build the products you care about (release is what install.sh looks for)
swift build -c release --product LavaView
swift build -c release --product LavaWeather
swift build -c release --product LavaTerm
swift build -c release --product LavaEditor
swift build -c release --product LavaSpotify
swift build -c release --product TraceLoom
swift build -c release --product LavaSettings

# Register everything listed in apps.conf
packaging/install.sh

# Or a subset
packaging/install.sh LavaTerm LavaSpotify

# Debug binaries instead of release
LAVA_BIN_DIR=.build/debug packaging/install.sh
```

Writes under your XDG dirs:

| Path | What |
|---|---|
| `~/.local/share/applications/<product>.desktop` | Launcher entry |
| `~/.local/share/icons/hicolor/scalable/apps/<icon>.svg` | Icon |
| `~/.local/bin/<product>` | Symlink to the binary |

Apps that speak the compositor control plane get `Exec=env LAVA_CLIENT=1 …`.

## Add an app

1. Add a row to `apps.conf` (fields documented there).
2. Drop `icons/<icon-name>.svg` (512×512, same rounded-tile family).
3. `packaging/install.sh <ProductName>` after a release build.

## Apps that open files

An app that should be offered for a double-clicked file declares a
`MimeType` in the tenth field of its `apps.conf` row. That, and only that,
also puts `%F` on the entry's `Exec`, so the desktop has somewhere to put the
filename — see LavaView's row. Leave the field off for an app that takes no
arguments: a field code a launcher cannot fill is a spec violation, and some
launchers refuse the entry outright rather than ignoring it.

`install.sh` also registers the app as the **default** handler for every type
it declares, and prints which ones it claimed. Pass `--no-default` to install
the entry without touching any association.

Find the type names with `gio info -a standard::content-type FILE`. Not with
`xdg-mime query filetype`, which shells out to file(1) and can answer with a
name shared-mime-info does not use — registering that spelling silently
associates nothing.
