#!/usr/bin/env bash
set -euo pipefail

repo_dir=/home/aym-n/homelab
music_dir=/data/compose/navidrome/music
spotdl_bin=${SPOTDL_BIN:-$HOME/.local/bin/spotdl}
playlists_file=${PLAYLISTS_FILE:-$repo_dir/stacks/navidrome/playlists}
spotdl_threads=${SPOTDL_THREADS:-1}
spotdl_max_retries=${SPOTDL_MAX_RETRIES:-2}
spotdl_extra_args=${SPOTDL_EXTRA_ARGS:-}
runtime_dir=${XDG_RUNTIME_DIR:-/tmp}
lock_file=${SPOTDL_LOCK_FILE:-$runtime_dir/spotdl-navidrome-sync.lock}
dry_run=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check|--dry-run]

Sync Spotify playlist URLs from $playlists_file into $music_dir.

Options:
  --check, --dry-run  Validate configuration and print what would run without downloading.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check|--dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [[ ! $spotdl_threads =~ ^[0-9]+$ || $spotdl_threads -lt 1 ]]; then
  echo "SPOTDL_THREADS must be a positive integer; got: $spotdl_threads" >&2
  exit 1
fi

if [[ ! $spotdl_max_retries =~ ^[0-9]+$ ]]; then
  echo "SPOTDL_MAX_RETRIES must be a non-negative integer; got: $spotdl_max_retries" >&2
  exit 1
fi

if [[ ! -e $playlists_file ]]; then
  echo "No playlist config found at $playlists_file; nothing to sync."
  echo "Create it from $repo_dir/stacks/navidrome/playlists.example."
  exit 0
fi

if [[ ! -r $playlists_file ]]; then
  echo "Playlist config is not readable: $playlists_file" >&2
  exit 1
fi

if [[ ! -x $spotdl_bin ]]; then
  echo "spotDL not found at $spotdl_bin. Install or upgrade with: pipx install spotdl --force" >&2
  exit 1
fi

if [[ ! -d $music_dir ]]; then
  echo "Navidrome music directory does not exist: $music_dir" >&2
  exit 1
fi

if ! mkdir -p "$(dirname "$lock_file")"; then
  echo "Unable to create lock directory for $lock_file" >&2
  exit 1
fi

exec 9>"$lock_file"
if ! flock -n 9; then
  echo "Another Navidrome playlist sync is already running; exiting without starting a second spotDL process."
  exit 0
fi

urls=()
while IFS= read -r line || [[ -n $line ]]; do
  line=${line//$'\r'/}
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}

  [[ -z $line ]] && continue
  [[ $line == \#* ]] && continue

  urls+=("$line")
done < "$playlists_file"

if [[ ${#urls[@]} -eq 0 ]]; then
  echo "No playlist URLs found in $playlists_file; nothing to sync."
  exit 0
fi

cd "$music_dir"

extra_args=()
if [[ -n $spotdl_extra_args ]]; then
  read -r -a extra_args <<< "$spotdl_extra_args"
fi

echo "Configured spotDL sync: playlists=${#urls[@]}, threads=$spotdl_threads, max_retries=$spotdl_max_retries, music_dir=$music_dir."

if [[ $dry_run -eq 1 ]]; then
  echo "Dry run only; no downloads will be started."
  echo "Would run spotDL sequentially with: $spotdl_bin --threads $spotdl_threads [extra args] download <playlist-url>"
  exit 0
fi

for index in "${!urls[@]}"; do
  playlist_number=$((index + 1))
  attempt=1
  max_attempts=$((spotdl_max_retries + 1))

  echo "Downloading/updating playlist $playlist_number/${#urls[@]}."
  until "$spotdl_bin" --threads "$spotdl_threads" "${extra_args[@]}" download "${urls[$index]}"; do
    if (( attempt >= max_attempts )); then
      echo "spotDL failed for playlist $playlist_number/${#urls[@]} after $attempt attempt(s)." >&2
      exit 1
    fi

    attempt=$((attempt + 1))
    echo "spotDL failed for playlist $playlist_number/${#urls[@]}; retrying attempt $attempt/$max_attempts."
  done
done

echo "Navidrome playlist sync complete."
