#!/usr/bin/env bash
set -euo pipefail

repo_dir=/home/aym-n/homelab
music_dir=/data/compose/navidrome/music
spotdl_bin=${SPOTDL_BIN:-$HOME/.local/bin/spotdl}
playlists_file=${PLAYLISTS_FILE:-$repo_dir/stacks/navidrome/playlists}
sources_file=${SOURCES_FILE:-$repo_dir/stacks/navidrome/sources}
spotdl_archive_file=${SPOTDL_ARCHIVE_FILE:-$music_dir/.spotdl-archive.txt}
spotdl_threads=${SPOTDL_THREADS:-1}
spotdl_max_retries=${SPOTDL_MAX_RETRIES:-2}
spotdl_extra_args=${SPOTDL_EXTRA_ARGS:-}
ytmusic_python_bin=${YTMUSIC_PYTHON_BIN:-$HOME/.local/share/pipx/venvs/spotdl/bin/python}
ytmusic_sync_bin=${YTMUSIC_SYNC_BIN:-$repo_dir/scripts/ytmusic-liked-navidrome-sync.py}
ytmusic_auth_file=${YTMUSIC_AUTH_FILE:-$HOME/.config/ytmusicapi/oauth.json}
ytmusic_client_id_file=${YTMUSIC_CLIENT_ID_FILE:-$HOME/.config/ytmusicapi/client_id}
ytmusic_client_secret_file=${YTMUSIC_CLIENT_SECRET_FILE:-$HOME/.config/ytmusicapi/client_secret}
ytmusic_archive_file=${YTMUSIC_ARCHIVE_FILE:-$music_dir/.ytmusic-liked-archive.txt}
ytmusic_limit=${YTMUSIC_LIMIT:-5000}
ytmusic_downloader=${YTMUSIC_DOWNLOADER:-spotdl}
runtime_dir=${XDG_RUNTIME_DIR:-/tmp}
lock_file=${SPOTDL_LOCK_FILE:-$runtime_dir/spotdl-navidrome-sync.lock}
dry_run=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check|--dry-run]

Sync configured Spotify and YouTube Music sources into $music_dir.

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
ytmusic_liked=0

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
      ytmusic-liked|youtube-music-liked)
        ytmusic_liked=1
        ;;
      http://*|https://*|spotify:*)
        spotdl_queries+=("$line")
        spotdl_query_labels+=("Spotify URL")
        spotdl_query_user_auth+=(0)
        ;;
      *)
        echo "Unsupported sync source in $config_file: $line" >&2
        echo "Use Spotify URLs, 'spotify-liked', or 'ytmusic-liked'." >&2
        exit 1
        ;;
    esac
  done < "$config_file"
done

if [[ ${#spotdl_queries[@]} -eq 0 && $ytmusic_liked -eq 0 ]]; then
  echo "No active sync sources found in ${config_files[*]}; nothing to sync."
  exit 0
fi

if [[ ${#spotdl_queries[@]} -gt 0 || $ytmusic_downloader == "spotdl" ]]; then
  if [[ ! -x $spotdl_bin ]]; then
    echo "spotDL not found at $spotdl_bin. Install or upgrade with: pipx install spotdl --force" >&2
    exit 1
  fi
fi

if [[ $ytmusic_liked -eq 1 && ! -x $ytmusic_sync_bin ]]; then
  echo "YouTube Music sync helper is not executable: $ytmusic_sync_bin" >&2
  exit 1
fi

if [[ $ytmusic_liked -eq 1 && ! -x $ytmusic_python_bin ]]; then
  echo "YouTube Music Python runtime is not executable: $ytmusic_python_bin" >&2
  exit 1
fi

cd "$music_dir"

extra_args=()
if [[ -n $spotdl_extra_args ]]; then
  read -r -a extra_args <<< "$spotdl_extra_args"
fi

echo "Configured Navidrome music sync: spotdl_sources=${#spotdl_queries[@]}, ytmusic_liked=$ytmusic_liked, threads=$spotdl_threads, max_retries=$spotdl_max_retries, music_dir=$music_dir, spotdl_archive=$spotdl_archive_file."

if [[ $dry_run -eq 1 ]]; then
  echo "Dry run only; no downloads will be started."
  if [[ ${#spotdl_queries[@]} -gt 0 ]]; then
    echo "Would run spotDL sequentially with: $spotdl_bin --threads $spotdl_threads --archive $spotdl_archive_file [extra args] download <source>"
    for index in "${!spotdl_queries[@]}"; do
      auth_suffix=""
      [[ ${spotdl_query_user_auth[$index]} -eq 1 ]] && auth_suffix=" --user-auth"
      echo "  - ${spotdl_query_labels[$index]}: download${auth_suffix} $(display_query "${spotdl_queries[$index]}")"
    done
  fi
  if [[ $ytmusic_liked -eq 1 ]]; then
    "$ytmusic_python_bin" "$ytmusic_sync_bin" \
      --check \
      --auth-file "$ytmusic_auth_file" \
      --client-id-file "$ytmusic_client_id_file" \
      --client-secret-file "$ytmusic_client_secret_file" \
      --music-dir "$music_dir" \
      --archive "$ytmusic_archive_file" \
      --spotdl-bin "$spotdl_bin" \
      --threads "$spotdl_threads" \
      --max-retries "$spotdl_max_retries" \
      --limit "$ytmusic_limit" \
      --downloader "$ytmusic_downloader"
  fi
  exit $?
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
  until "$spotdl_bin" --threads "$spotdl_threads" --archive "$spotdl_archive_file" "${extra_args[@]}" download "${source_args[@]}" "${spotdl_queries[$index]}"; do
    if (( attempt >= max_attempts )); then
      echo "spotDL failed for source $source_number/${#spotdl_queries[@]} after $attempt attempt(s)." >&2
      exit 1
    fi

    attempt=$((attempt + 1))
    echo "spotDL failed for source $source_number/${#spotdl_queries[@]}; retrying attempt $attempt/$max_attempts."
  done
done

if [[ $ytmusic_liked -eq 1 ]]; then
  "$ytmusic_python_bin" "$ytmusic_sync_bin" \
    --auth-file "$ytmusic_auth_file" \
    --client-id-file "$ytmusic_client_id_file" \
    --client-secret-file "$ytmusic_client_secret_file" \
    --music-dir "$music_dir" \
    --archive "$ytmusic_archive_file" \
    --spotdl-bin "$spotdl_bin" \
    --threads "$spotdl_threads" \
    --max-retries "$spotdl_max_retries" \
    --limit "$ytmusic_limit" \
    --downloader "$ytmusic_downloader"
fi

echo "Navidrome music sync complete."
