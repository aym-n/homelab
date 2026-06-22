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

For named Spotify sources, copy the tracked source example:

```bash
cp ~/homelab/stacks/navidrome/sources.example ~/homelab/stacks/navidrome/sources
$EDITOR ~/homelab/stacks/navidrome/sources
```

The real source file is `~/homelab/stacks/navidrome/sources` and is ignored by git. Supported entries:

- `spotify <spotify-url>` syncs a Spotify playlist, album, artist, or track URL.
- `spotify-liked` syncs Spotify Liked Songs / Saved Tracks with `spotdl download --user-auth saved`.

Spotify liked songs require spotDL OAuth. Run the sync manually once, complete the Spotify browser login, then leave the timer to reuse the cached auth:

```bash
~/homelab/scripts/spotdl-navidrome-sync.sh --check
~/homelab/scripts/spotdl-navidrome-sync.sh
```

The sync script is intentionally conservative to avoid overlapping runs, OOMs, and accidental music deletion:

- `SPOTDL_THREADS=1` by default; passed to spotDL as `--threads`.
- `SPOTDL_MAX_RETRIES=2` by default; retries each source sequentially before failing.
- `SPOTDL_EXTRA_ARGS` can pass extra whitespace-separated spotDL options.
- `SPOTDL_LOCK_FILE` can override the default lock at `$XDG_RUNTIME_DIR/spotdl-navidrome-sync.lock` or `/tmp/spotdl-navidrome-sync.lock`.
- `SPOTDL_GENERATE_LRC=1` by default; passes `--lyrics synced --generate-lrc` so spotDL writes synced `.lrc` sidecar files when lyrics are available.
- `SPOTDL_LYRICS_PROVIDERS=synced` controls the whitespace-separated lyrics providers used with `--lyrics`.

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
