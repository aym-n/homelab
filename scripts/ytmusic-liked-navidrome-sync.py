#!/usr/bin/env python3
"""Sync YouTube Music liked songs into the Navidrome music directory."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path


def read_secret(value: str | None, path: Path) -> str | None:
    if value:
        return value.strip()
    if path.exists():
        return path.read_text(encoding="utf-8").strip()
    return None


def fail_auth(auth_file: Path, client_id_file: Path, client_secret_file: Path) -> int:
    print("YouTube Music liked sync is configured, but auth is incomplete.", file=sys.stderr)
    print(f"Expected OAuth token file: {auth_file}", file=sys.stderr)
    print(f"Expected client id file or YTMUSIC_CLIENT_ID: {client_id_file}", file=sys.stderr)
    print(f"Expected client secret file or YTMUSIC_CLIENT_SECRET: {client_secret_file}", file=sys.stderr)
    print("Setup: run ytmusicapi oauth, then place oauth.json and Google TV OAuth client credentials at those paths.", file=sys.stderr)
    return 1


def load_liked_songs(args: argparse.Namespace) -> dict:
    auth_file = Path(args.auth_file).expanduser()
    client_id_file = Path(args.client_id_file).expanduser()
    client_secret_file = Path(args.client_secret_file).expanduser()
    client_id = read_secret(os.environ.get("YTMUSIC_CLIENT_ID"), client_id_file)
    client_secret = read_secret(os.environ.get("YTMUSIC_CLIENT_SECRET"), client_secret_file)

    if not auth_file.exists() or not client_id or not client_secret:
        raise RuntimeError(fail_auth(auth_file, client_id_file, client_secret_file))

    try:
        from ytmusicapi import OAuthCredentials, YTMusic
    except ImportError as exc:
        print("ytmusicapi is not importable from this Python environment.", file=sys.stderr)
        print("Use the spotDL pipx venv Python, or install ytmusicapi in the runtime environment.", file=sys.stderr)
        raise RuntimeError(1) from exc

    ytmusic = YTMusic(
        str(auth_file),
        oauth_credentials=OAuthCredentials(client_id=client_id, client_secret=client_secret),
    )
    return ytmusic.get_liked_songs(limit=args.limit)


def normalize_tracks(payload: dict) -> list[dict]:
    tracks = payload.get("tracks") or payload.get("items") or []
    normalized: list[dict] = []
    for track in tracks:
        video_id = track.get("videoId")
        title = track.get("title")
        if not video_id or not title:
            continue
        artists = ", ".join(a.get("name", "") for a in track.get("artists", []) if a.get("name"))
        normalized.append(
            {
                "video_id": video_id,
                "title": title,
                "artists": artists,
                "url": f"https://music.youtube.com/watch?v={video_id}",
            }
        )
    return normalized


def load_archive(path: Path) -> set[str]:
    if not path.exists():
        return set()
    return {line.strip() for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip()}


def append_archive(path: Path, video_id: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"{video_id}\n")


def run_with_retries(command: list[str], max_retries: int) -> None:
    max_attempts = max_retries + 1
    for attempt in range(1, max_attempts + 1):
        result = subprocess.run(command, check=False)
        if result.returncode == 0:
            return
        if attempt == max_attempts:
            raise subprocess.CalledProcessError(result.returncode, command)
        print(f"Download failed; retrying attempt {attempt + 1}/{max_attempts}.")


def build_command(args: argparse.Namespace, track: dict) -> list[str]:
    if args.downloader == "spotdl":
        return [
            args.spotdl_bin,
            "--threads",
            str(args.threads),
            "download",
            track["url"],
        ]

    output_template = "%(artist,creator,uploader|Unknown Artist)s/%(title)s [%(id)s].%(ext)s"
    return [
        args.ytdlp_bin,
        "--extract-audio",
        "--audio-format",
        "mp3",
        "--embed-thumbnail",
        "--embed-metadata",
        "--no-overwrites",
        "--download-archive",
        str(Path(args.archive).expanduser()),
        "--paths",
        str(Path(args.music_dir).expanduser()),
        "--output",
        output_template,
        track["url"],
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--auth-file", default="~/.config/ytmusicapi/oauth.json")
    parser.add_argument("--client-id-file", default="~/.config/ytmusicapi/client_id")
    parser.add_argument("--client-secret-file", default="~/.config/ytmusicapi/client_secret")
    parser.add_argument("--music-dir", default="/data/compose/navidrome/music")
    parser.add_argument("--archive", default="/data/compose/navidrome/music/.ytmusic-liked-archive.txt")
    parser.add_argument("--spotdl-bin", default="~/.local/bin/spotdl")
    parser.add_argument("--ytdlp-bin", default="~/.local/share/pipx/venvs/spotdl/bin/yt-dlp")
    parser.add_argument("--downloader", choices=("spotdl", "yt-dlp"), default="spotdl")
    parser.add_argument("--threads", type=int, default=1)
    parser.add_argument("--max-retries", type=int, default=2)
    parser.add_argument("--limit", type=int, default=5000)
    parser.add_argument("--check", action="store_true", help="List pending items without downloading.")
    args = parser.parse_args()

    args.spotdl_bin = str(Path(args.spotdl_bin).expanduser())
    args.ytdlp_bin = str(Path(args.ytdlp_bin).expanduser())
    music_dir = Path(args.music_dir).expanduser()
    archive = Path(args.archive).expanduser()

    if args.threads < 1:
        print("--threads must be positive.", file=sys.stderr)
        return 2
    if args.max_retries < 0:
        print("--max-retries must be non-negative.", file=sys.stderr)
        return 2
    if not music_dir.is_dir():
        print(f"Music directory does not exist: {music_dir}", file=sys.stderr)
        return 1
    if args.downloader == "spotdl" and not os.access(args.spotdl_bin, os.X_OK):
        print(f"spotDL not executable: {args.spotdl_bin}", file=sys.stderr)
        return 1
    if args.downloader == "yt-dlp" and not os.access(args.ytdlp_bin, os.X_OK):
        print(f"yt-dlp not executable: {args.ytdlp_bin}", file=sys.stderr)
        return 1

    try:
        payload = load_liked_songs(args)
    except RuntimeError as exc:
        return int(exc.args[0]) if exc.args and isinstance(exc.args[0], int) else 1

    tracks = normalize_tracks(payload)
    archived = load_archive(archive)
    pending = [track for track in tracks if track["video_id"] not in archived]

    print(
        "YouTube Music liked songs: "
        f"fetched={len(tracks)}, archived={len(archived)}, pending={len(pending)}, downloader={args.downloader}."
    )
    if args.check:
        for track in pending[:10]:
            label = f"{track['artists']} - {track['title']}".strip(" -")
            print(f"  - {label} ({track['video_id']})")
        if len(pending) > 10:
            print(f"  ... {len(pending) - 10} more pending item(s)")
        print("Check only; no YouTube Music downloads were started.")
        return 0

    os.chdir(music_dir)
    for index, track in enumerate(pending, start=1):
        label = f"{track['artists']} - {track['title']}".strip(" -")
        print(f"Downloading YouTube Music liked song {index}/{len(pending)}: {label}")
        run_with_retries(build_command(args, track), args.max_retries)
        append_archive(archive, track["video_id"])

    print("YouTube Music liked sync complete.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
