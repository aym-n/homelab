#!/usr/bin/env bash
set -euo pipefail

urls=(
  https://home.aymn.systems
  https://dockge.aymn.systems
  https://photos.aymn.systems
  https://traefik.aymn.systems
  https://music.aymn.systems
)

for url in "${urls[@]}"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$url" || true)
  printf "%s %s\n" "$code" "$url"
done

echo "--- containers ---"
docker ps --format "{{.Names}}: {{.Status}}"
