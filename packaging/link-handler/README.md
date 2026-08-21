# Links open on the workspace you are on

`xdg-open https://…` from an app on workspace 2 puts the page in whichever
browser window you last touched — often one on workspace 1. This replaces the
default `x-scheme-handler/http` handler with one that keeps the link where you
are.

## Why the browser has to be told

Chrome is a singleton. A second `google-chrome URL` process does not draw
anything; it hands its command line to the running instance, which opens the
URL in `BrowserList::GetLastActive()`. That is process-global and purely
temporal — no part of the path knows what a workspace is, so the compositor is
never asked.

The compositor already assigns every *new* window to the workspace that is
current when it is created (`Toplevel::Toplevel`, `compositor/src/main.cpp`).
So only one thing is missing: making Chrome's idea of "last active" agree with
where you are, before it is handed the URL.

`lava-open-link` does that in two cases:

| On this workspace | What happens |
|---|---|
| A browser window (minimized counts) | `lavactl focus-app` restores and focuses it, then a plain launch opens a tab **in that window** |
| None | `--new-window`, which the compositor places **here** |

## Install

```sh
swift build -c release --product lavactl
install -Dm755 .build/release/lavactl ~/.local/bin/lavactl
install -Dm755 packaging/link-handler/lava-open-link ~/.local/bin/lava-open-link
install -Dm644 packaging/link-handler/lava-open-link.desktop \
    ~/.local/share/applications/lava-open-link.desktop
update-desktop-database ~/.local/share/applications
xdg-settings set default-web-browser lava-open-link.desktop
```

Check it took:

```sh
xdg-settings get default-web-browser     # lava-open-link.desktop
xdg-open https://example.com             # lands on the workspace you are on
```

To undo, one line: `xdg-settings set default-web-browser google-chrome.desktop`.

## Knobs

All environment variables, all with working defaults:

| Variable | Default | For |
|---|---|---|
| `LAVA_BROWSER` | `google-chrome-stable` | The browser to launch |
| `LAVA_BROWSER_APP_ID` | `google-chrome` | Its `app_id`, as `lavactl windows` prints it |
| `LAVA_BROWSER_SETTLE` | `1` | Seconds between focusing the window and handing over the URL |
| `LAVACTL` | `lavactl` | Path to the CLI |

`LAVA_BROWSER_SETTLE` is the one with a real trade-off. Chrome updates its
last-active window from the Wayland keyboard-focus event, and the URL-carrying
process races it. A second is far longer than the event needs and still shorter
than a cold start, so it is a delay you only pay when the browser is already
running and about to be reused. Drop it to `0.2` if it feels slow; if links
start landing in the wrong window again, that is the thing to put back.

## Firefox

Set two variables — `LAVA_BROWSER=firefox`, `LAVA_BROWSER_APP_ID=firefox` —
and it should behave the same way. Untested: Firefox's remote-command path is
not Chrome's, and `--new-window` may not survive it.
