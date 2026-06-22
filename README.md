# Homelab

Unified Docker Compose stacks for aym-n homelab.

## Layout
- `dockge/` - Stack management UI (https://dockge.aymn.systems)
- `stacks/` - Individual service stacks managed by Dockge
- `scripts/apply-all.sh` - Boot-time stack startup

## Commands
```bash
~/homelab/scripts/apply-all.sh      # start all stacks
~/homelab/scripts/health-check.sh   # local routing smoke test
cd ~/homelab/stacks/traefik && docker compose up -d
```

Use `docker compose` v2 only (never `docker-compose` v1).

## Navidrome tools
Download Spotify tracks or playlists into the Navidrome music library with the host spotDL install:

```bash
~/homelab/scripts/spotdl-navidrome.sh download '<spotify-url-or-playlist>'
```

Upgrade spotDL with:

```bash
pipx install spotdl --force
```

### Music source sync

Create the local playlist config from the tracked example, then replace the placeholder with your Spotify playlist URL:

```bash
cp ~/homelab/stacks/navidrome/playlists.example ~/homelab/stacks/navidrome/playlists
$EDITOR ~/homelab/stacks/navidrome/playlists
```

The real playlist file is `~/homelab/stacks/navidrome/playlists` and is ignored by git. Add one Spotify playlist URL per line; blank lines and lines beginning with `#` are skipped.

For named sources, copy the tracked source example:

```bash
cp ~/homelab/stacks/navidrome/sources.example ~/homelab/stacks/navidrome/sources
$EDITOR ~/homelab/stacks/navidrome/sources
```

The real source file is `~/homelab/stacks/navidrome/sources` and is ignored by git. Supported entries:

- `spotify <spotify-url>` syncs a Spotify playlist, album, artist, or track URL.
- `spotify-liked` syncs Spotify Liked Songs / Saved Tracks with `spotdl download --user-auth saved`.
- `ytmusic-liked` syncs YouTube Music Liked Songs through `ytmusicapi.get_liked_songs()` and downloads the exact YouTube Music video URLs.

Spotify liked songs require spotDL OAuth. Run the sync manually once, complete the Spotify browser login, then leave the timer to reuse the cached auth:

```bash
~/homelab/scripts/spotdl-navidrome-sync.sh --check
~/homelab/scripts/spotdl-navidrome-sync.sh
```

YouTube Music liked songs require ytmusicapi OAuth. As of late 2024, ytmusicapi also needs a Google OAuth client created as `TVs and Limited Input devices`.

Default local auth paths:

- `~/.config/ytmusicapi/oauth.json`
- `~/.config/ytmusicapi/client_id`
- `~/.config/ytmusicapi/client_secret`

Setup commands:

```bash
mkdir -p ~/.config/ytmusicapi
cd ~/.config/ytmusicapi
~/.local/share/pipx/venvs/spotdl/bin/ytmusicapi oauth
$EDITOR client_id
$EDITOR client_secret
```

Auth files, OAuth tokens, browser headers, cookies, and real source files are ignored by git. You can override paths with `YTMUSIC_AUTH_FILE`, `YTMUSIC_CLIENT_ID_FILE`, and `YTMUSIC_CLIENT_SECRET_FILE`.

The sync script is intentionally conservative to avoid overlapping runs and OOMs:

- `SPOTDL_THREADS=1` by default; passed to spotDL as `--threads`.
- `SPOTDL_MAX_RETRIES=2` by default; retries each playlist sequentially before failing.
- `SPOTDL_EXTRA_ARGS` can pass extra whitespace-separated spotDL options.
- `SPOTDL_LOCK_FILE` can override the default lock at `$XDG_RUNTIME_DIR/spotdl-navidrome-sync.lock` or `/tmp/spotdl-navidrome-sync.lock`.
- `YTMUSIC_LIMIT=5000` controls how many YouTube Music liked songs are listed.
- `YTMUSIC_PYTHON_BIN=~/.local/share/pipx/venvs/spotdl/bin/python` uses the spotDL pipx environment that already contains `ytmusicapi`.
- `YTMUSIC_DOWNLOADER=spotdl` downloads exact YouTube Music URLs with spotDL; set `yt-dlp` only if you want direct yt-dlp extraction.

Run a sync manually with either command:

```bash
~/homelab/scripts/spotdl-navidrome-sync.sh
systemctl --user start spotdl-navidrome-sync.service
```

Validate configuration without downloading:

```bash
~/homelab/scripts/spotdl-navidrome-sync.sh --check
```

Run manually with reduced or increased spotDL threads:

```bash
SPOTDL_THREADS=1 ~/homelab/scripts/spotdl-navidrome-sync.sh
SPOTDL_THREADS=2 SPOTDL_MAX_RETRIES=1 ~/homelab/scripts/spotdl-navidrome-sync.sh
```

Manage the hourly timer with:

```bash
systemctl --user enable --now spotdl-navidrome-sync.timer
systemctl --user status spotdl-navidrome-sync.timer
systemctl --user list-timers spotdl-navidrome-sync.timer
journalctl --user -u spotdl-navidrome-sync.service -n 100 --no-pager
```

