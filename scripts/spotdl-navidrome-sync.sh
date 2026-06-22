#!/usr/bin/env bash
set -euo pipefail

repo_dir=/home/aym-n/homelab
music_dir=/data/compose/navidrome/music
spotdl_bin=${SPOTDL_BIN:-$HOME/.local/bin/spotdl}
playlists_file=${PLAYLISTS_FILE:-$repo_dir/stacks/navidrome/playlists}
sources_file=${SOURCES_FILE:-$repo_dir/stacks/navidrome/sources}
spotdl_archive_file=${SPOTDL_ARCHIVE_FILE:-$music_dir/.spotdl-archive.txt}
spotdl_threads=${SPOTDL_THREADS:-1}
spotdl_max_retries=${SPOTDL_MAX_RETRIES:-1}
spotdl_extra_args=${SPOTDL_EXTRA_ARGS:-}
spotdl_generate_lrc=${SPOTDL_GENERATE_LRC:-0}
spotdl_lyrics_providers=${SPOTDL_LYRICS_PROVIDERS:-genius}
runtime_dir=${XDG_RUNTIME_DIR:-/tmp}
lock_file=${SPOTDL_LOCK_FILE:-$runtime_dir/spotdl-navidrome-sync.lock}
dry_run=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check|--dry-run]

Sync configured Spotify sources into $music_dir.

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

case "${spotdl_generate_lrc,,}" in
  1|true|yes|on)
    spotdl_generate_lrc=1
    ;;
  0|false|no|off)
    spotdl_generate_lrc=0
    ;;
  *)
    echo "SPOTDL_GENERATE_LRC must be one of: 1, 0, true, false, yes, no, on, off; got: $spotdl_generate_lrc" >&2
    exit 1
    ;;
esac

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

config_files=()
[[ -e $playlists_file ]] && config_files+=("$playlists_file")
[[ -e $sources_file ]] && config_files+=("$sources_file")

if [[ ${#config_files[@]} -eq 0 ]]; then
  echo "No sync config found; nothing to sync."
  echo "Create $playlists_file from playlists.example, or $sources_file from sources.example."
  exit 0
fi

spotdl_queries=()
spotdl_query_labels=()
spotdl_query_user_auth=()

trim_line() {
  local value=$1
  value=${value//$'\r'/}
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

display_query() {
  local query=$1
  case "$query" in
    http://*|https://*)
      printf '<url redacted>'
      ;;
    spotify:*)
      printf '<spotify uri redacted>'
      ;;
    *)
      printf '%s' "$query"
      ;;
  esac
}

for config_file in "${config_files[@]}"; do
  if [[ ! -r $config_file ]]; then
    echo "Sync config is not readable: $config_file" >&2
    exit 1
  fi

  while IFS= read -r raw_line || [[ -n $raw_line ]]; do
    line=$(trim_line "$raw_line")

    [[ -z $line ]] && continue
    [[ $line == \#* ]] && continue

    case "$line" in
      spotify-liked|spotify-saved|liked|saved)
        spotdl_queries+=("saved")
        spotdl_query_labels+=("Spotify liked/saved tracks")
        spotdl_query_user_auth+=(1)
        ;;
      spotify\ *)
        query=$(trim_line "${line#spotify }")
        if [[ -z $query ]]; then
          echo "Invalid empty Spotify source in $config_file" >&2
          exit 1
        fi
        spotdl_query_labels+=("Spotify source")
        if [[ $query == "saved" || $query == "liked" ]]; then
          spotdl_queries+=("saved")
          spotdl_query_user_auth+=(1)
        else
          spotdl_queries+=("$query")
          spotdl_query_user_auth+=(0)
        fi
        ;;
      http://*|https://*|spotify:*)
        spotdl_queries+=("$line")
        spotdl_query_labels+=("Spotify URL")
        spotdl_query_user_auth+=(0)
        ;;
      *)
        echo "Unsupported sync source in $config_file: $line" >&2
        echo "Use Spotify URLs or 'spotify-liked'." >&2
        exit 1
        ;;
    esac
  done < "$config_file"
done

if [[ ${#spotdl_queries[@]} -eq 0 ]]; then
  echo "No active sync sources found in ${config_files[*]}; nothing to sync."
  exit 0
fi

if [[ ! -x $spotdl_bin ]]; then
  echo "spotDL not found at $spotdl_bin. Install or upgrade with: pipx install spotdl --force" >&2
  exit 1
fi

cd "$music_dir"

extra_args=()
if [[ -n $spotdl_extra_args ]]; then
  read -r -a extra_args <<< "$spotdl_extra_args"
fi

lyrics_args=()
read -r -a lyrics_providers <<< "$spotdl_lyrics_providers"
if [[ ${#lyrics_providers[@]} -gt 0 && ${lyrics_providers[0],,} != "none" ]]; then
  lyrics_args+=(--lyrics "${lyrics_providers[@]}")
fi
if [[ $spotdl_generate_lrc -eq 1 ]]; then
  has_synced_provider=0
  for provider in "${lyrics_providers[@]}"; do
    if [[ ${provider,,} == "synced" ]]; then
      has_synced_provider=1
      break
    fi
  done
  if [[ $has_synced_provider -ne 1 ]]; then
    echo "SPOTDL_GENERATE_LRC requires SPOTDL_LYRICS_PROVIDERS to include synced." >&2
    echo "Keep SPOTDL_GENERATE_LRC=0 to avoid syncedlyrics NetEase/Megalobiz timeouts." >&2
    exit 1
  fi
  lyrics_args+=(--generate-lrc)
fi

echo "Configured Navidrome music sync: spotdl_sources=${#spotdl_queries[@]}, threads=$spotdl_threads, max_retries=$spotdl_max_retries, generate_lrc=$spotdl_generate_lrc, lyrics_providers=$spotdl_lyrics_providers, music_dir=$music_dir, spotdl_archive=$spotdl_archive_file."

if [[ $dry_run -eq 1 ]]; then
  echo "Dry run only; no downloads will be started."
  echo "Would run spotDL sequentially with: $spotdl_bin [lyrics args] --threads $spotdl_threads --max-retries $spotdl_max_retries --archive $spotdl_archive_file [extra args] [source auth args] download <source>"
  for index in "${!spotdl_queries[@]}"; do
    auth_prefix=""
    [[ ${spotdl_query_user_auth[$index]} -eq 1 ]] && auth_prefix="--user-auth "
    echo "  - ${spotdl_query_labels[$index]}: ${auth_prefix}download $(display_query "${spotdl_queries[$index]}")"
  done
  exit 0
fi

for index in "${!spotdl_queries[@]}"; do
  source_number=$((index + 1))
  attempt=1
  max_attempts=$((spotdl_max_retries + 1))
  source_args=()
  if [[ ${spotdl_query_user_auth[$index]} -eq 1 ]]; then
    source_args+=(--user-auth)
  fi

  echo "Downloading/updating ${spotdl_query_labels[$index]} $source_number/${#spotdl_queries[@]}."
  until "$spotdl_bin" "${lyrics_args[@]}" --threads "$spotdl_threads" --max-retries "$spotdl_max_retries" --archive "$spotdl_archive_file" "${extra_args[@]}" "${source_args[@]}" download "${spotdl_queries[$index]}"; do
    if (( attempt >= max_attempts )); then
      echo "spotDL failed for source $source_number/${#spotdl_queries[@]} after $attempt attempt(s)." >&2
      exit 1
    fi

    attempt=$((attempt + 1))
    echo "spotDL failed for source $source_number/${#spotdl_queries[@]}; retrying attempt $attempt/$max_attempts."
  done
done

echo "Navidrome music sync complete."
