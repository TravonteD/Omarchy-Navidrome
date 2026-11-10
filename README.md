# Omarchy Navidrome

**Navidrome in Quickshell—not another browser tab.**

Omarchy Navidrome brings your self-hosted Navidrome library into a fast,
lightweight Omarchy plugin: music skipping the browser, following your active
Omarchy theme, with a mini player in the bar.

This is a port of the proven Omarchy Spotify plugin to Navidrome's Subsonic
API. It is in active development; see
[docs/NAVIDROME_PORT_PLAN.md](docs/NAVIDROME_PORT_PLAN.md) for the plan and
[docs/PORT_STATUS.md](docs/PORT_STATUS.md) for what works today.

## Install (development build)

```bash
omarchy plugin add /home/tray/Projects/Omarchy-Navidrome/main --enable
```

Requires Omarchy 4 and a running Navidrome server. Point the first-run setup
at your server's base URL and sign in once; credentials are stored in your
keyring. (Until the port's setup flow ships, point the plugin at your
checkout path in `omarchy plugin add` for a development build.)

## Remove it completely

Run the bundled uninstaller from outside the plugin directory:

```bash
cd "$HOME" && "$HOME/.config/omarchy/plugins/quickshell.navidrome/scripts/uninstall.sh"
```

It disables and removes the plugin, stops and removes both user services,
restarts the shell, and deletes all plugin-owned configuration, cached audio,
backend build files, installed binaries, playback state, runtime sockets, old
configuration backups, and matching GNOME Keyring entries.

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
Omarchy plugin such as Omasing.

## What carries over from the Spotify plugin

- **Lightweight by design.** About 60 MB of shell memory instead of a
  browser-sized client.
- **Made for Omarchy.** Everything follows your current theme automatically,
  including light themes.
- **A full keyboard-driven app.** `Ctrl+F`/`/` to search, `Tab`/`F6` to move
  between sidebar, search, song list, and player, arrows to move, `Enter` to
  activate, `Space` to play/pause, `Ctrl+Left/Right` between songs,
  `Ctrl+Up/Down` for volume. `Ctrl+/` lists every shortcut; the panel keeps
  the same shortcut-hint overlay you may already know from Omarchy Spotify.
- **Lyrics, planned built-in.** The port's lyrics view will read embedded and
  server-side lyrics (synced or plain text) straight from Navidrome,
  replacing the Omasing handoff used by the Spotify plugin.

## Roadmap highlights

The port replaces Spotify-only pieces—OAuth, Connect devices, rate-limit
cooldowns—with their Navidrome equivalents: password auth into the keyring,
local streaming through the plugin's Rust backend, honest scrobbles at
natural track end, and server-persisted play queues with bookmark-accurate
resume. Artwork, playlists, stars, search, and the queue carry over with the
same behavior standards the Spotify implementation earned.

Screenshots will be updated to Navidrome content during the port.
