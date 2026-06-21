#!/usr/bin/env bash
set -euo pipefail

music_dir=/data/compose/navidrome/music
spotdl_bin=${SPOTDL_BIN:-$HOME/.local/bin/spotdl}

if [[ $# -eq 0 ]]; then
  echo "Usage: $0 download <spotify-url-or-playlist>" >&2
  exit 2
fi

if [[ ! -x $spotdl_bin ]]; then
  echo "spotDL not found at $spotdl_bin. Install or upgrade with: pipx install spotdl --force" >&2
  exit 1
fi

cd "$music_dir"
exec "$spotdl_bin" "$@"
