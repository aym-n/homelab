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
