# Omarchy Navidrome

**Navidrome in Quickshell—not another browser tab.**

Omarchy Navidrome is an Omarchy plugin for a self-hosted
[Navidrome](https://www.navidrome.org) library: a lightweight, keyboard-driven
music client that lives in your bar, follows your active Omarchy theme, and
streams from your own server through a plugin-owned backend. It speaks the
Subsonic API (1.16.1 with OpenSubsonic extensions) that Navidrome serves, so
there is no third-party account in the middle—your server, your credentials,
your music.

The plugin is code-complete pending live-server validation; see
[docs/PORT_STATUS.md](docs/PORT_STATUS.md) for the record and
[docs/NAVIDROME_PORT_PLAN.md](docs/NAVIDROME_PORT_PLAN.md) for the plan.

## Requirements

- Omarchy 4 with the Quickshell shell enabled
- A running Navidrome server you can reach by URL (for example
  `https://nav.example.com`), and an account on it
- Omarchy base tools: `secret-tool`, `openssl`, `systemctl`, and Python 3
- Rust (cargo) so the playback backend can build from source

The backend is built locally from the reviewed source and installed under
your home directory; nothing outside the plugin's own directories is
modified. See [docs/RELEASING.md](docs/RELEASING.md) for the build and
checksum story.

## Install from a fresh clone

From a checkout of this repository on an Omarchy 4 machine, with a Navidrome
server running:

```bash
./scripts/install-local.sh            # or: ./scripts/install-local.sh --section center|right
```

The command validates the manifest, builds and installs the plugin-owned
playback backend (compiled outside the plugin directory, in
`$XDG_CACHE_HOME/omarchy-navidrome/target`), installs its on-demand systemd
user unit, links the checkout at
`~/.config/omarchy/plugins/quickshell.navidrome`, and enables the bar widget
in the section you choose. It refuses to replace an existing plugin. To
install only the playback integration, run `./scripts/setup.sh` instead.

Neither path enables or starts the playback unit at login; the backend starts
when you play on this computer and idles out per its setting.

### First-run setup

Click the bar widget. If you are not connected, the client opens directly on
its guided connection screen: enter the server's base URL, your username, and
your password. The setup probes the actual server (`ping` and `getUser`)
before storing anything, and only on success writes the credential set to
your GNOME Keyring. A wrong password is reported as a typed error, not a
retry loop. If you prefer a terminal, `./scripts/setup-playback.sh` performs
the same guided flow (prompts, or `OMARCHY_NAVIDROME_SERVER_URL`,
`OMARCHY_NAVIDROME_USERNAME`, and `--password-file`/`OMARCHY_NAVIDROME_PASSWORD`
for unattended runs).

**Plain-HTTP honesty.** Many Navidrome instances run on plain local HTTP. The
plugin allows that but never pretends it is private: a setup warning tells
you plainly that the connection is NOT private whenever the server URL is not
HTTPS, and the credential model keeps that warning visible. TLS validation is
never bypassed; a self-signed certificate that fails validation is not
silently accepted.

## Keyboard shortcuts

`Ctrl+/` opens a themed shortcut reference inside the panel. The full list,
as the panel's own reference presents it:

| Keys | Action |
| --- | --- |
| `Ctrl+F` or `/` | Search everywhere (press again to toggle the current area / everywhere) |
| `Esc` | Leave search |
| `Alt+Left` | Go back |
| `Esc` | Leave Settings |
| `Ctrl+,` | Open Settings |
| `Alt+Shift+H` | Open Home |
| `Alt+Shift+Q` | Open Queue |
| `Ctrl+Shift+A` | Open the current artist |
| `Ctrl+Shift+B` | Open the current album |
| `Tab` / `F6` | Move between sidebar, search, the song list, and the player |
| Arrow keys | Move to a control / move through lists |
| `Enter` | Activate the highlighted control / open the selected item |
| `C` | Row actions (arrows or `Enter` to choose) |
| `Space` | Play or pause |
| `Ctrl+Left` / `Ctrl+Right` | Previous / next track |
| `Ctrl+Shift+L` | Open lyrics |
| `M` | Mute or restore volume |
| `Ctrl+S` | Toggle shuffle |
| `Ctrl+R` | Cycle repeat |
| `Shift+Left` / `Shift+Right` | Seek back / forward 10 seconds |
| `Ctrl+Up` / `Ctrl+Down` | Raise / lower volume 5% |
| `Esc, Esc` | Arm close / close |
| `Ctrl+H` | Hide visible shortcut hints |
| `Ctrl+/` | Show this reference |

The lyrics row is absent while the lyrics button is disabled in Settings.
After the first shortcut, matching controls light up and show the next key to
press (the shortcut-hint overlay); hold `Ctrl`, `Shift`, or `Alt` to see
those chords.

## What it does

- **Home.** Recently played, frequently played, and newest albums in bounded
  `getAlbumList2` windows, plus your starred songs from `getStarred2`.
- **Explore.** Random albums, genre browsing through `getGenres`, and your
  server's internet radio stations, kept visually separate from library songs.
- **Library.** Starred songs, albums, and artists from `getStarred2`, with
  consistent star state across bar, mini-player, and panel.
- **Artists and albums.** Artist pages list the artist's albums and top songs;
  album pages list their tracks.
- **Playlists.** Create, rename, edit contents, reorder, and delete
  Subsonic playlists.
- **Search.** One context-aware search field over bounded `search3` windows
  for songs, albums, artists, and playlists.
- **Built-in lyrics.** The player's lyrics surface reads embedded, external,
  and synced lyrics straight from `getLyricsBySongId`, with synced-line
  highlight following playback. No extra plugin needed.
- **Honest scrobbles.** A play count moves exactly when the server should
  record it: the engine submits `scrobble submission=true` at a track's
  natural end (or on skip/stop once the Audioscrobbler rule is met), never for
  seeks, shutdowns, or engine failures.
- **Persistent queue and resume.** Every queue change persists to the server
  with `savePlayQueue`; a new session restores the last queue and the exact
  position of a partially played track (bookmarks), so pressing Play resumes
  where you stopped.
- **Quality control.** Stream format and a bounded bit-rate cap applied by the
  server's transcoder, set in Settings.
- **Artwork.** Covers load through the server's `getCoverArt` behind a
  master switch; with artwork off the app becomes text-only and no art
  traffic leaves the machine.
- **Lightweight by design.** A bar widget, a lazy-loaded panel, and a
  supervised backend process—no browser engine, no second shell, no resident
  helper. Methodology and recorded numbers: [docs/BENCHMARK.md](docs/BENCHMARK.md).

## Remove it completely

Run the bundled uninstaller from outside the plugin directory:

```bash
cd "$HOME" && "$HOME/.config/omarchy/plugins/quickshell.navidrome/scripts/uninstall.sh"
```

It disables and removes the plugin, stops and removes the user service,
restarts the shell, and deletes all plugin-owned configuration, cached audio,
backend build files, installed binaries, playback state, runtime sockets, old
configuration backups, and matching GNOME Keyring entries — including the
stored Navidrome server credential set.

If you prefer to inspect and paste the main steps individually:

```bash
plugin_dir="$HOME/.config/omarchy/plugins/quickshell.navidrome"
cd "$HOME"
omarchy plugin disable quickshell.navidrome 2>/dev/null || true
"$plugin_dir/scripts/remove-runtime.sh" --purge
omarchy plugin remove quickshell.navidrome --yes
omarchy restart shell
```

The cleanup deliberately leaves unrelated software alone, including any other
Omarchy plugin.
