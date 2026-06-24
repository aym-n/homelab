#!/usr/bin/env python3
import json
import os
import re
import subprocess
import unicodedata
from pathlib import Path

ROOT = Path(os.environ.get("EXPLO_POSTPROCESS_ROOT", "/data"))
CONFIG = Path(os.environ.get("EXPLO_CONFIG_DIR", "/opt/explo/config"))
ALBUM_ARTIST = os.environ.get("EXPLO_ALBUM_ARTIST", "Various Artists")
AUDIO_EXTS = {".mp3"}


def norm(value):
    value = unicodedata.normalize("NFKD", value or "").encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]+", "", value)


def ffprobe(path):
    output = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-show_entries",
            "stream=index,codec_type,codec_name,disposition:format_tags=title,artist,album,album_artist,albumartist,compilation,TCMP",
            "-of",
            "json",
            str(path),
        ],
        text=True,
    )
    return json.loads(output)


def load_cover_index():
    index = {}
    for cache in (CONFIG / "cache").glob("*.json"):
        try:
            data = json.loads(cache.read_text())
        except Exception:
            continue

        for track in data.get("tracks", []):
            cover = track.get("coverPath")
            if not cover:
                continue

            cover_path = Path(cover)
            if not cover_path.exists():
                continue

            keys = {
                norm(track.get("title")),
                norm("{}{}".format(track.get("title", ""), track.get("release", ""))),
                norm("{}{}".format(track.get("title", ""), track.get("artist", ""))),
            }
            for key in keys:
                if key:
                    index.setdefault(key, cover_path)
    return index


def has_embedded_art(info):
    return any(stream.get("codec_type") == "video" for stream in info.get("streams", []))


def tags_from(info):
    return info.get("format", {}).get("tags", {}) or {}


def cover_for(path, tags, cover_index):
    title = tags.get("title") or tags.get("TITLE") or path.stem.split("-")[0]
    album = tags.get("album") or tags.get("ALBUM") or ""
    artist = tags.get("artist") or tags.get("ARTIST") or ""
    for key in (norm("{}{}".format(title, album)), norm("{}{}".format(title, artist)), norm(title)):
        if key in cover_index:
            return cover_index[key]
    return None


def rewrite(path, cover=None):
    tmp = path.with_name(path.stem + ".postprocess.mp3")
    if tmp.exists():
        tmp.unlink()

    cmd = ["ffmpeg", "-y", "-v", "error", "-i", str(path)]
    if cover is not None:
        cmd += ["-i", str(cover), "-map", "0:a", "-map", "1:v", "-c:a", "copy", "-c:v", "mjpeg"]
    else:
        cmd += ["-map", "0", "-c", "copy"]

    cmd += [
        "-f",
        "mp3",
        "-id3v2_version",
        "3",
        "-metadata",
        "album_artist={}".format(ALBUM_ARTIST),
        "-metadata",
        "albumartist={}".format(ALBUM_ARTIST),
        "-metadata",
        "compilation=1",
        "-metadata",
        "TCMP=1",
        "-metadata:s:v",
        "title=Album cover",
        "-metadata:s:v",
        "comment=Cover (front)",
        str(tmp),
    ]
    subprocess.check_call(cmd)
    os.replace(tmp, path)


def main():
    cover_index = load_cover_index()
    processed = 0
    missing_cover = []
    failed = []

    for path in sorted(ROOT.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in AUDIO_EXTS:
            continue
        if path.name.endswith(".tmp") or ".postprocess" in path.name:
            continue

        try:
            info = ffprobe(path)
            tags = tags_from(info)
            album_artist = tags.get("album_artist") or tags.get("albumartist") or tags.get("ALBUMARTIST")
            needs_tags = album_artist != ALBUM_ARTIST or tags.get("compilation") != "1"
            needs_art = not has_embedded_art(info)
            if not needs_tags and not needs_art:
                continue

            cover = None
            if needs_art:
                cover = cover_for(path, tags, cover_index)
                if cover is None:
                    missing_cover.append(str(path))
                    if not needs_tags:
                        continue

            rewrite(path, cover)
            processed += 1
        except Exception as exc:
            failed.append("{}: {}".format(path, exc))

    print(json.dumps({"processed": processed, "missing_cover": missing_cover, "failed": failed}))


if __name__ == "__main__":
    main()
