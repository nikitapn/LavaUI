# LavaSpotify setup guide

LavaSpotify is a LavaUI client for browsing Spotify catalog art and controlling
playback through **Spotify Connect**. Audio is played by **spotifyd** (or any
other Connect device), not by the LavaUI process and not by the Web Playback
SDK.

This guide is the full install path for a Linux machine with **PulseAudio**
(or PipeWire’s Pulse compatibility layer). It records the two logins, the
redirect URI, and the spotifyd panics we already hit once so the next machine
does not have to rediscover them.

## Architecture

```
LavaSpotify (Swift / LavaUI)
  │  catalog: client credentials or seed/oembed
  │  control: user OAuth → Web API Player
  │
  ├── GET  /v1/search, /v1/albums/{id}     metadata + covers
  └── PUT  /v1/me/player/play?device_id=…  start track on a Connect device
                    │
                    ▼
              spotifyd (librespot)
                    │
                    ▼
              PulseAudio / PipeWire
```

| Piece | Role |
| --- | --- |
| **LavaSpotify** | UI, cover cache, OAuth for the *control* token, Player API |
| **spotifyd** | Connect speaker; decrypts and plays audio via Pulse |
| **Web Playback SDK** | Not used (browser + Widevine DRM; wrong stack) |

There are **two independent Spotify logins**:

1. **LavaSpotify** — authorization-code + PKCE so the app can call `/me/player/*`.
2. **spotifyd** — `spotifyd authenticate` so the daemon is bound to your account
   and appears in `GET /me/player/devices`.

Zeroconf alone (`Spotifyd@hostname` on the LAN) is not enough for the Web API
device list. The daemon must finish its own OAuth and stay running.

## Prerequisites

- Linux, PulseAudio or PipeWire-with-`pipewire-pulse`
- Spotify **Premium** (Player API and spotifyd both require it)
- A [Spotify Developer](https://developer.spotify.com/dashboard) app
- Build deps for this repo (Vulkan, Swift, canvas engine) as for `HelloWorld` /
  `TraceLoom`

## 1. Spotify Developer dashboard

1. Create an app at https://developer.spotify.com/dashboard
2. Note **Client ID** and **Client Secret**
3. Under Redirect URIs, add **exactly**:

   ```
   http://127.0.0.1:17321/callback
   ```

   LavaSpotify listens on that loopback port during Account → Log in. A
   mismatch (trailing slash, `localhost` vs `127.0.0.1`, wrong port) fails the
   OAuth exchange.

4. Development Mode notes (February 2026+):
   - App owner needs Premium
   - Browse endpoints such as `GET /browse/new-releases` are gone
   - Search `limit` max is **10**
   - Catalog still works via search + single-album fetch

Optional second redirect if you use spotifyd’s default OAuth port:

```
http://127.0.0.1:8000/login
```

(Only needed for `spotifyd authenticate`; check current spotifyd docs if the
path differs on your version.)

## 2. Environment for LavaSpotify

```bash
export SPOTIFY_CLIENT_ID="…"
export SPOTIFY_CLIENT_SECRET="…"

# Optional: substring for Connect device selection (default is already "spotifyd")
export SPOTIFY_DEVICE_NAME="spotifyd"

# Optional: override OAuth redirect (must still match the dashboard)
# export SPOTIFY_REDIRECT_URI="http://127.0.0.1:17321/callback"

# Optional: stress the image cache (KB)
# export LAVA_IMAGE_BUDGET_KB=4096
```

Put these in your shell profile or a small env file you `source` before
`swift run Spotify`. Client credentials alone load the live catalog; playback
needs the user login in step 5.

## 3. Build and run LavaSpotify

From the repo root (same as other LavaUI apps):

```bash
cd canvas && ninja -C .build.Debug   # if the engine is not built yet
cd .. && swift build --product Spotify
swift run Spotify
```

Executable product name: `Spotify` (target `SpotifyApp`).

Without credentials the app falls back to a **seed catalog** + oembed covers so
the image cache can still be exercised offline.

User tokens are stored at:

```
~/.config/LavaSpotify/tokens.json    # mode 0600
```

Non-secret preferences (theme palette id, …) use LavaUI `AppSettings`:

```
~/.config/LavaSpotify/settings.json
```

Log out from **Account → Log out** to delete tokens only; settings stay.

## 4. Install and configure spotifyd (PulseAudio)

### Package

Arch example (adjust for your distro):

```bash
sudo pacman -S spotifyd
# spotifyd 0.4.x has: spotifyd authenticate
```

### Config

```bash
mkdir -p ~/.config/spotifyd
```

`~/.config/spotifyd/spotifyd.conf`:

```toml
[global]
backend = "pulseaudio"
device_name = "spotifyd"
bitrate = 160
use_mpris = true

# Uncomment to pin a sink if "default" is wrong:
# device = "default"
```

**Do not leave the default Rodio backend** on a headless/user systemd service
without a working default device. Rodio failing to open a device panics:

```text
Message: called `Result::unwrap()` on an `Err` value: NoDeviceAvailable
Location: .../librespot-playback-.../audio_backend/rodio.rs
```

Pulse (or ALSA with an explicit device) avoids that crash loop.

### systemd user service

The distro unit often starts spotifyd with no config. Override it:

```bash
mkdir -p ~/.config/systemd/user/spotifyd.service.d
```

`~/.config/systemd/user/spotifyd.service.d/override.conf`:

```ini
[Service]
ExecStart=
ExecStart=/usr/bin/spotifyd --no-daemon --config-path=%h/.config/spotifyd/spotifyd.conf
# Pulse/PipeWire socket for this user session
Environment=PULSE_SERVER=unix:%t/pulse/native
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now spotifyd
systemctl --user status spotifyd --no-pager
```

Healthy log lines look like authentication success and a Pulse/ALSA backend
**without** `NoDeviceAvailable` or `application panicked`.

### Authenticate spotifyd (second login)

```bash
spotifyd authenticate
# browser OAuth; default oauth port 8000
systemctl --user restart spotifyd
journalctl --user -u spotifyd -n 30 --no-pager
```

You want something like:

```text
Login via OAuth as user …
Authenticated as '…' !
```

and **no** panic after “Using audio device”.

Confirm zeroconf if curious:

```bash
avahi-browse -art | grep -i spotify
# often: Spotifyd@hostname or the configured device_name
```

Zeroconf proves LAN advertisement; **`GET /me/player/devices` is the truth** for
LavaSpotify (see below).

## 5. Connect LavaSpotify to spotifyd

1. Start LavaSpotify with `SPOTIFY_CLIENT_ID` / `SECRET` set.
2. **Account → Log in to Spotify…** (browser; callback on port 17321).
3. Ensure spotifyd is active and authenticated (step 4).
4. **Account → Refresh devices**.
5. Status / sidebar should show a device whose name contains `spotifyd`
   (or whatever `SPOTIFY_DEVICE_NAME` matches).
6. Open an album and click a track (or **Play**).

Player bar footer: `Connect · <device name>`. Progress polls from
`GET /me/player`.

### Device selection rules

1. Unrestricted device whose name contains `SPOTIFY_DEVICE_NAME` (default
   `spotifyd`).
2. Else active unrestricted device.
3. Else first unrestricted device.
4. Empty list → user-facing hint to run `spotifyd authenticate` and restart.

## 6. Menu map

| Menu | Action |
| --- | --- |
| Account → Log in to Spotify… | LavaSpotify user OAuth (control token) |
| Account → Log out | Clear `~/.config/LavaSpotify/tokens.json` |
| Account → Refresh devices | Re-query Connect device list |
| Help → Setup | Dump a short checklist on stderr |
| LavaSpotify → Reload Catalog | Re-fetch home shelves |

## 7. Scopes and API surface

LavaSpotify requests (user token):

- `user-read-playback-state`
- `user-modify-playback-state`
- `user-read-currently-playing`

Playback calls:

- `GET /v1/me/player/devices`
- `PUT /v1/me/player/play` — prefer **album `context_uri` + offset** so the
  Connect device advances to the next track when one ends (a lone
  `uris: [one track]` stops after that song)
- `PUT /v1/me/player/pause`
- `POST /v1/me/player/next` / `previous`
- `GET /v1/me/player` (poll; updates now-playing when the device advances)

Catalog (client credentials or user token):

- `GET /v1/search` (limit ≤ 10 after Feb 2026)
- `GET /v1/albums/{id}`

Seed mode without API secrets uses oembed + canned tracklists; play uses
`spotify:album:…` context + track index when track ids are not real Spotify
ids.

## 8. Troubleshooting

### `GET /me/player/devices` is `[]` but spotifyd is running

LavaSpotify is logged in; **spotifyd is not bound to the account** (or has
crashed). Run:

```bash
spotifyd authenticate
systemctl --user restart spotifyd
systemctl --user status spotifyd
```

Then Refresh devices. LAN zeroconf without credentials never fills this list.

### spotifyd panic: `NoDeviceAvailable` (rodio.rs)

Backend cannot open audio. Force Pulse:

```toml
# ~/.config/spotifyd/spotifyd.conf
backend = "pulseaudio"
```

and the systemd override with `PULSE_SERVER=unix:%t/pulse/native`. Confirm the
user Pulse/PipeWire session is running (`pactl info`).

### spotifyd restart loop (status 101)

Read:

```bash
journalctl --user -u spotifyd -n 50 --no-pager
```

Fix the first panic (usually audio); the second unwrap in `main_loop` is
fallout from the player thread dying.

### OAuth login times out / “Missing code”

- Redirect URI in the dashboard must match exactly
  `http://127.0.0.1:17321/callback`
- Port 17321 free; only one login attempt at a time
- Browser completed allow; loopback page says you can close the tab

### Play fails with 404 NO_ACTIVE_DEVICE

No device selected or device offline. Refresh devices; ensure spotifyd is
`active` and listed. Transfer/play includes `device_id` when resolved.

### Wrong device (phone/desktop instead of spotifyd)

Set `device_name = "spotifyd"` in spotifyd.conf and
`SPOTIFY_DEVICE_NAME=spotifyd`. Restart spotifyd and Refresh devices.

### Covers missing / placeholders forever

Network to Spotify CDN; check
`~/.cache/` LavaSpotify covers directory (CoverCache). Seed mode needs
outbound HTTPS for oembed + image hosts.

### Catalog 403 on old “new releases” path

Fixed in code: live home uses search shelves only (Feb 2026 removals). Rebuild
if you are on an older tree that still called `/browse/new-releases`.

## 9. Quick checklist (new machine)

```bash
# --- Spotify app ---
# Dashboard: redirect http://127.0.0.1:17321/callback
export SPOTIFY_CLIENT_ID=…
export SPOTIFY_CLIENT_SECRET=…

# --- spotifyd + Pulse ---
sudo pacman -S spotifyd   # or distro equivalent
mkdir -p ~/.config/spotifyd ~/.config/systemd/user/spotifyd.service.d
# write spotifyd.conf (backend = pulseaudio, device_name = spotifyd)
# write override.conf (ExecStart with --config-path, PULSE_SERVER)
systemctl --user daemon-reload
spotifyd authenticate
systemctl --user enable --now spotifyd

# --- LavaSpotify ---
swift run Spotify
# Account → Log in → Refresh devices → click a track
```

## 10. Related code

| Path | Responsibility |
| --- | --- |
| `Sources/SpotifyApp/` | Window, menus, UI, session |
| `Sources/SpotifyCore/SpotifyClient.swift` | Catalog + Player API |
| `Sources/SpotifyCore/OAuth.swift` | User PKCE login, token store |
| `Sources/SpotifyCore/CoverCache.swift` | Download covers for `ImageStore` |
| `Sources/SpotifyCore/SeedCatalog.swift` | Offline/oembed fallback |

## 11. What we deliberately do not do

- Embed the **Web Playback SDK** (MSE + Widevine in a browser/WebView)
- Stream raw track bytes from the public Web API (not offered)
- Treat LavaSpotify login as sufficient for audio without spotifyd (or another
  Connect endpoint)

Playback policy: LavaUI controls; spotifyd speaks.
