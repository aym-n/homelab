# Homelab

Docker Compose configuration and helper scripts for the homelab.

## Layout

- `dockge/` - Dockge stack manager.
- `stacks/` - Service stacks and per-service configuration.
- `scripts/` - Operational helpers for startup, health checks, and media sync.

## Common Commands

```bash
~/homelab/scripts/apply-all.sh
~/homelab/scripts/health-check.sh
```

Use Docker Compose v2:

```bash
docker compose up -d
```

## Media Sync

Navidrome playlist sync uses spotDL and the local playlist file at:

```text
~/homelab/stacks/navidrome/playlists
```

Create it from the tracked example:

```bash
cp ~/homelab/stacks/navidrome/playlists.example ~/homelab/stacks/navidrome/playlists
```

Add one Spotify playlist URL per line. Blank lines and lines starting with `#` are ignored.

Manual sync:

```bash
~/homelab/scripts/spotdl-navidrome-sync.sh
```

Validate without downloading:

```bash
~/homelab/scripts/spotdl-navidrome-sync.sh --check
```

One-off playlist sync:

```bash
~/homelab/scripts/spotdl-navidrome-oneoff.sh SPOTIFY_PLAYLIST_URL
```

Timer management:

```bash
systemctl --user status spotdl-navidrome-sync.timer
systemctl --user list-timers spotdl-navidrome-sync.timer
journalctl --user -u spotdl-navidrome-sync.service -n 100 --no-pager
```
