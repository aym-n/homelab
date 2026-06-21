#!/bin/bash
set -euo pipefail
for dir in /home/aym-n/homelab/stacks/*/ /home/aym-n/homelab/dockge/; do
  for f in compose.yaml docker-compose.yaml docker-compose.yml; do
    if [ -f "$dir$f" ]; then
      echo "==> $dir$f"
      docker compose -f "$dir$f" up -d
      break
    fi
  done
done
