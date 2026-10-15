#!/usr/bin/env bash
# Reassembles files the box uploads through ComfyUI in <=90 MB parts (ComfyUI's default upload cap is 100 MB and the
# RunPod HTTP proxy is not meant for huge single bodies). Used for character-pack LoRAs that are not on Hugging Face.
#   input/jutsu_parts/<name>.part000 ... + <name>.parts.json {"name","parts","sha256","dest"}  ->  /models/<dest>/<name>
# On success writes input/jutsu_parts/<name>.ok (the runner polls it via /view); on a hash mismatch writes <name>.bad.
set -uo pipefail
MODELS=${MODELS_DIR:-/models}
IN=${1:-${JUTSU_PREFIX:-/opt/jutsu}/ComfyUI/input/jutsu_parts}
mkdir -p "$IN"
while true; do
  for j in "$IN"/*.parts.json; do
    [ -e "$j" ] || continue
    name=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['name'])" "$j")
    n=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['parts'])" "$j")
    sha=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['sha256'])" "$j")
    dest=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('dest','loras'))" "$j")
    case "$name$dest" in */..*|..*|*/*/*) echo "[assemble] refusing odd path $name $dest"; mv "$j" "$j.rejected"; continue;; esac
    have=$(ls "$IN/$name".part[0-9][0-9][0-9] 2>/dev/null | wc -l)
    [ "$have" -ge "$n" ] || continue
    tmp="$MODELS/$dest/.$name.tmp"; mkdir -p "$MODELS/$dest"
    cat $(ls "$IN/$name".part[0-9][0-9][0-9] | sort) > "$tmp"
    if [ "$(sha256sum "$tmp" | cut -d' ' -f1)" = "$sha" ]; then
      mv "$tmp" "$MODELS/$dest/$name"; rm -f "$IN/$name".part[0-9][0-9][0-9]; mv "$j" "$IN/$name.done.json"; echo ok > "$IN/$name.ok"
      echo "[assemble] $name -> /models/$dest ($n parts, sha256 ok)"
    else
      rm -f "$tmp"; echo bad > "$IN/$name.bad"; mv "$j" "$j.bad"; echo "[assemble] $name sha256 MISMATCH"
    fi
  done
  sleep 3
done
