#!/usr/bin/env bash
# Genie Jutsu RunPod entrypoint (template "genie-jutsu-comfy"). Pod boot -> render-ready -> auto-queue slate -> auto-terminate.
# 1) network volume at /workspace (RunPod mounts it there) holds models/, jutsu/ (venv+ComfyUI+nodes), slate/ (graphs+inputs)
# 2) watchdog FIRST (cost cap + hard seconds + 900s idle linger) so even a failed install can't burn money
# 3) pinned install (idempotent marker; ~0s on a filled volume)  4) model sync, sha256 verified, present files skipped
# 5) ComfyUI on $COMFY_PORT with health check  6) copy slate inputs -> ComfyUI/input, queue every run in the slate
# Never echoes RUNPOD_API_KEY / HF_TOKEN.
set -euo pipefail
export JUTSU_BOOT_T0=$(date +%s)
VOL=${JUTSU_VOLUME:-/workspace}
SRC=${JUTSU_SRC:-$VOL/jutsu-src}                 # repo worker files + manifests copied here by the fill job (or baked /opt/jutsu-src)
[ -d "$SRC" ] || SRC=/opt/jutsu-src
PORT=${COMFY_PORT:-8188}; URL=http://127.0.0.1:$PORT
PREFIX_DIR=${JUTSU_PREFIX:-}                     # baked image (ghcr genie-jutsu-worker) ships the venv at /opt/jutsu
[ -n "$PREFIX_DIR" ] || { [ -x /opt/jutsu/venv/bin/python ] && PREFIX_DIR=/opt/jutsu || PREFIX_DIR=$VOL/jutsu; }
# Generic runtime inputs (no rebuild, no network volume): each may be a local path, an http(s) URL, or base64 in *_B64.
#   JUTSU_MANIFEST / JUTSU_MANIFEST_B64      model manifest json        (fallback: $SRC/models.manifest.json)
#   JUTSU_SLATE_BUNDLE_URL                   tar.gz with slate.json, graphs/, inputs/  (unpacked to $VOL/slate)
#   JUTSU_SLATE / JUTSU_SLATE_B64            slate json
fetch_to() {  # fetch_to <value> <dest>: path -> copy, URL -> curl (retry), else no-op
  local v="$1" d="$2"; [ -z "$v" ] && return 1; mkdir -p "$(dirname "$d")"
  case "$v" in http://*|https://*) curl -fsSL --retry 5 --retry-delay 3 -o "$d" "$v" ;; *) [ -f "$v" ] && { [ "$v" = "$d" ] || cp "$v" "$d"; } ;; esac
}
mkdir -p "$VOL/slate"
if [ -n "${JUTSU_SLATE_BUNDLE_URL:-}" ]; then
  fetch_to "$JUTSU_SLATE_BUNDLE_URL" /tmp/slate_bundle.tgz && tar -xzf /tmp/slate_bundle.tgz -C "$VOL/slate" && echo "[entry] slate bundle unpacked"
  [ -f "$VOL/slate/models.manifest.json" ] && : "${JUTSU_MANIFEST:=$VOL/slate/models.manifest.json}"
  [ -f "$VOL/slate/slate.json" ] && : "${JUTSU_SLATE:=$VOL/slate/slate.json}"
fi
MANIFEST=$VOL/slate/models.manifest.json
if [ -n "${JUTSU_MANIFEST_B64:-}" ]; then echo "$JUTSU_MANIFEST_B64" | base64 -d > "$MANIFEST"
elif ! fetch_to "${JUTSU_MANIFEST:-}" "$MANIFEST"; then MANIFEST=$SRC/models.manifest.json; fi
[ -f "$MANIFEST" ] || { echo "[entry] no model manifest (set JUTSU_MANIFEST or JUTSU_SLATE_BUNDLE_URL)"; }
if [ -n "${JUTSU_SLATE_B64:-}" ]; then echo "$JUTSU_SLATE_B64" | base64 -d > "$VOL/slate/slate.json"; JUTSU_SLATE=$VOL/slate/slate.json
elif [ -n "${JUTSU_SLATE:-}" ] && [ "${JUTSU_SLATE#http}" != "$JUTSU_SLATE" ]; then fetch_to "$JUTSU_SLATE" "$VOL/slate/slate.json"; JUTSU_SLATE=$VOL/slate/slate.json; fi
SLATE=${JUTSU_SLATE:-$VOL/slate/universal_3subject.json}
GRAPHS=${JUTSU_GRAPHS:-$VOL/slate/graphs}
LOG=$VOL/logs/boot-$(date +%Y%m%d-%H%M%S).log; mkdir -p "$VOL/logs"; exec > >(tee -a "$LOG") 2>&1
echo "[entry] pod=${RUNPOD_POD_ID:-local} vol=$VOL src=$SRC port=$PORT mode=${JUTSU_MODE:-slate}"
IDLE=${JUTSU_IDLE_SECONDS:-900}; [ "${JUTSU_MODE:-slate}" = fill ] && IDLE=86400   # fill: only $ cap + max seconds apply
WD=(python3 "$SRC/pod_boot.py" watchdog --url "$URL" --idle "$IDLE" --max-usd "${JUTSU_MAX_USD:-2.80}" --rate "${JUTSU_RATE_USD_HR:-2.49}")
[ -n "${JUTSU_MAX_SECONDS:-}" ] && WD+=(--max-seconds "$JUTSU_MAX_SECONDS")
[ "${JUTSU_DRY_RUN:-0}" = 1 ] && WD+=(--dry-run)
"${WD[@]}" &
fail() { echo "[entry] FAIL: $*"; [ "${JUTSU_DRY_RUN:-0}" = 1 ] || python3 -c "import sys; sys.path.insert(0,'$SRC'); import pod_boot; pod_boot.terminate(False)"; exit 1; }
if [ "${JUTSU_MODE:-slate}" = fill ]; then          # one-time volume fill (CPU pod is enough): install + models, then stop
  PREFIX=$PREFIX_DIR bash "$SRC/install.sh" || fail install
  python3 "$SRC/pod_boot.py" sync --manifest "$MANIFEST" --slate "$SLATE" --root "$VOL" --verify sha256 || fail sync
  echo "[entry] FILL DONE"; python3 -c "import sys; sys.path.insert(0,'$SRC'); import pod_boot; pod_boot.terminate(${JUTSU_DRY_RUN:-0}==1)"; exit 0
fi
[ -x "$PREFIX_DIR/venv/bin/python" ] || PREFIX=$PREFIX_DIR bash "$SRC/install.sh" || fail install
python3 "$SRC/pod_boot.py" sync --manifest "$MANIFEST" --slate "$SLATE" --root "$VOL" --graphs "$GRAPHS" --verify "${JUTSU_VERIFY:-sha256}" || fail sync
MODEL_ROOT=$VOL JUTSU_PREFIX=$PREFIX_DIR COMFY_PORT=$PORT bash "$SRC/start.sh" &
python3 "$SRC/pod_boot.py" health --url "$URL" --timeout "${JUTSU_HEALTH_TIMEOUT:-900}" || fail health
if [ "${JUTSU_AUTOQUEUE:-1}" = 1 ] && [ -f "$SLATE" ]; then
  mkdir -p "$PREFIX_DIR/ComfyUI/input"; cp -n "$VOL"/slate/inputs/* "$PREFIX_DIR/ComfyUI/input/" 2>/dev/null || true
  python3 "$SRC/pod_boot.py" queue --url "$URL" --slate "$SLATE" --graphs "$GRAPHS" || fail queue
fi
wait
