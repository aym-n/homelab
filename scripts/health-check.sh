#!/bin/bash
set -euo pipefail
hosts=(home cloud vault photos hermes dockge traefik)
for h in "${hosts[@]}"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${h}.aymn.systems" http://127.0.0.1/ || echo fail)
  echo "$code ${h}.aymn.systems"
done
