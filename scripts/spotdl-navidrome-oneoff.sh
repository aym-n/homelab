#!/usr/bin/env bash
set -euo pipefail

music_dir=/data/compose/navidrome/music
spotdl_bin=${SPOTDL_BIN:-$HOME/.local/bin/spotdl}
spotdl_archive_file=${SPOTDL_ARCHIVE_FILE:-$music_dir/.spotdl-archive.txt}
spotdl_threads=${SPOTDL_THREADS:-1}
spotdl_max_retries=${SPOTDL_MAX_RETRIES:-2}
spotdl_extra_args=${SPOTDL_EXTRA_ARGS:-}
runtime_dir=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
lock_file=${SPOTDL_LOCK_FILE:-$runtime_dir/spotdl-navidrome-sync.lock}
log_dir=${SPOTDL_LOG_DIR:-/tmp}
timestamp=$(date +%Y%m%d-%H%M%S)
log_file=${SPOTDL_LOG_FILE:-$log_dir/spotdl-navidrome-oneoff-$timestamp.log}
dry_run=0
urls=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--check|--dry-run] <spotify-playlist-url> [spotify-playlist-url...]

Run a one-off spotDL sync for one or more Spotify playlists without editing
the tracked Navidrome playlist config.

Options:
  --check, --dry-run  Validate configuration and print what would run without downloading.
  -h, --help          Show this help.

Environment:
  SPOTDL_BIN          spotDL executable. Default: $HOME/.local/bin/spotdl
  SPOTDL_THREADS      spotDL thread count. Default: 1
  SPOTDL_MAX_RETRIES  Retries per playlist before marking it failed. Default: 2
  SPOTDL_EXTRA_ARGS   Extra whitespace-separated arguments passed to spotDL.
  SPOTDL_LOG_DIR      Directory for timestamped logs. Default: /tmp
EOF
}

redact_text() {
  sed -E 's#(https://open[.]spotify[.]com/playlist/[^[:space:]?]+)[?][^[:space:]]+#\1?[redacted]#g'
}

redact_arg() {
  printf '%s\n' "$1" | redact_text
}

log() {
  redact_arg "$*" | tee -a "$log_file"
}

log_error() {
  redact_arg "$*" | tee -a "$log_file" >&2
}

run_spotdl() {
  local url=$1
  set +e
  "$spotdl_bin" --threads "$spotdl_threads" --archive "$spotdl_archive_file" "${extra_args[@]}" download "$url" 2>&1 \
    | redact_text \
    | tee -a "$log_file"
  local status=${PIPESTATUS[0]}
  set -e
  return "$status"
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
    --)
      shift
      while [[ $# -gt 0 ]]; do
        urls+=("$1")
        shift
      done
      break
      ;;
    -*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      urls+=("$1")
      ;;
  esac
  shift
done

if [[ ${#urls[@]} -eq 0 ]]; then
  echo "At least one Spotify playlist URL is required." >&2
  usage >&2
  exit 2
fi

if [[ ! $spotdl_threads =~ ^[0-9]+$ || $spotdl_threads -lt 1 ]]; then
  echo "SPOTDL_THREADS must be a positive integer; got: $spotdl_threads" >&2
  exit 1
fi

if [[ ! $spotdl_max_retries =~ ^[0-9]+$ ]]; then
  echo "SPOTDL_MAX_RETRIES must be a non-negative integer; got: $spotdl_max_retries" >&2
  exit 1
fi

for url in "${urls[@]}"; do
  if [[ ! $url =~ ^https://open[.]spotify[.]com/playlist/[^[:space:]]+ ]]; then
    echo "Expected a Spotify playlist URL; got: $(redact_arg "$url")" >&2
    exit 2
  fi
done

if [[ ! -x $spotdl_bin ]]; then
  echo "spotDL not found at $spotdl_bin. Install or upgrade with: pipx install spotdl --force" >&2
  exit 1
fi

if [[ ! -d $music_dir ]]; then
  echo "Navidrome music directory does not exist: $music_dir" >&2
  exit 1
fi

if ! mkdir -p "$log_dir"; then
  echo "Unable to create log directory: $log_dir" >&2
  exit 1
fi

if ! mkdir -p "$(dirname "$lock_file")"; then
  echo "Unable to create lock directory for $lock_file" >&2
  exit 1
fi

exec 9>"$lock_file"
if ! flock -n 9; then
  log_error "Another Navidrome playlist sync is already running; exiting without starting a second spotDL process."
  exit 1
fi

if command -v systemctl >/dev/null 2>&1 && systemctl --user --quiet is-active spotdl-navidrome-sync.service; then
  log_error "Scheduled sync service spotdl-navidrome-sync.service is active; exiting without starting a one-off sync."
  exit 1
fi

existing_spotdl=$(pgrep -u "$(id -u)" -fa '(^|/| )spotdl([[:space:]]|$)' || true)
if [[ -n $existing_spotdl ]]; then
  log_error "Another spotDL process is already running; exiting without starting a one-off sync."
  exit 1
fi

cd "$music_dir"

extra_args=()
if [[ -n $spotdl_extra_args ]]; then
  read -r -a extra_args <<< "$spotdl_extra_args"
fi

log "Configured one-off spotDL sync: playlists=${#urls[@]}, threads=$spotdl_threads, max_retries=$spotdl_max_retries, music_dir=$music_dir, archive=$spotdl_archive_file."
log "Log file: $log_file"

if [[ $dry_run -eq 1 ]]; then
  log "Dry run only; no downloads will be started."
  for index in "${!urls[@]}"; do
    playlist_number=$((index + 1))
    log "Would run playlist $playlist_number/${#urls[@]}: $(redact_arg "${urls[$index]}")"
  done
  exit 0
fi

failed_count=0

for index in "${!urls[@]}"; do
  playlist_number=$((index + 1))
  attempt=1
  max_attempts=$((spotdl_max_retries + 1))

  log "Downloading/updating playlist $playlist_number/${#urls[@]}: $(redact_arg "${urls[$index]}")"
  until run_spotdl "${urls[$index]}"; do
    if (( attempt >= max_attempts )); then
      log_error "spotDL failed for playlist $playlist_number/${#urls[@]} after $attempt attempt(s): $(redact_arg "${urls[$index]}")"
      failed_count=$((failed_count + 1))
      break
    fi

    attempt=$((attempt + 1))
    log "spotDL failed for playlist $playlist_number/${#urls[@]}; retrying attempt $attempt/$max_attempts."
  done
done

if (( failed_count > 0 )); then
  log_error "One-off Navidrome playlist sync completed with $failed_count failed playlist(s)."
  exit 1
fi

log "One-off Navidrome playlist sync complete."
