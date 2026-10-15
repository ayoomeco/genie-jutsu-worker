#!/usr/bin/env bash
# Worker entrypoint. Finds the model root on the attached network volume, links it to /models, starts ComfyUI.
# Optional dead-man switch: JUTSU_MAX_SECONDS=N terminates THIS pod after N seconds using the pod-scoped
# RUNPOD_API_KEY that RunPod injects into every pod (no user key ever leaves the box).
set -euo pipefail
for root in "${MODEL_ROOT:-}" /runpod-volume /workspace; do
  if [ -n "$root" ] && [ -d "$root/models" ]; then MODEL_ROOT=$root; break; fi
done
MODEL_ROOT=${MODEL_ROOT:-/workspace}
ln -sfn "$MODEL_ROOT/models" /models
JUTSU=${JUTSU_PREFIX:-}
for p in "$JUTSU" /opt/jutsu "$MODEL_ROOT/jutsu"; do
  if [ -n "$p" ] && [ -x "$p/venv/bin/python" ]; then JUTSU=$p; break; fi
done
echo "[start] models=$MODEL_ROOT/models jutsu=$JUTSU"
if [ -n "${JUTSU_MAX_SECONDS:-}" ] && [ -n "${RUNPOD_POD_ID:-}" ]; then
  ( sleep "$JUTSU_MAX_SECONDS"; echo "[start] dead-man switch: terminating pod $RUNPOD_POD_ID";
    (command -v runpodctl >/dev/null && runpodctl remove pod "$RUNPOD_POD_ID") || \
    curl -s -X DELETE -H "Authorization: Bearer ${RUNPOD_API_KEY:-}" "https://rest.runpod.io/v1/pods/$RUNPOD_POD_ID" ) &
fi
# Box-uploaded files (character LoRAs) arrive in <=90 MB parts via ComfyUI /upload/image; reassemble in the background
HERE=$(cd "$(dirname "$0")" && pwd)
if [ -f "$HERE/assemble_uploads.sh" ] && ! pgrep -f assemble_uploads.sh >/dev/null; then
  JUTSU_PREFIX=$JUTSU bash "$HERE/assemble_uploads.sh" "$JUTSU/ComfyUI/input/jutsu_parts" &
fi
# GPU-profile flags (see research: KJ chunking + cu130 nvfp4 matter far more than Sage on a 5090)
FLAGS=(--listen 0.0.0.0 --port "${COMFY_PORT:-8188}" --disable-auto-launch --preview-method none)
# Global Sage is OPT-IN (JUTSU_GLOBAL_SAGE=1): recipes pick attention per model (ModelAttentionBackend / KJ patches), and a
# global flag would silently change what the speed ladder measures.
if [ "${JUTSU_GLOBAL_SAGE:-0}" = 1 ]; then "$JUTSU/venv/bin/python" -c "import sageattention" 2>/dev/null && FLAGS+=(--use-sage-attention) || true; fi
[ -n "${COMFY_EXTRA_FLAGS:-}" ] && FLAGS+=(${COMFY_EXTRA_FLAGS})
# FlashVSR node reads ComfyUI/models/FlashVSR-v1.1 directly (ignores extra_model_paths) and calls snapshot_download when that
# dir is missing. Phase 1: ComfyUI started before the background download created it -> no link -> HF 429. Link ALWAYS.
mkdir -p /models/FlashVSR-v1.1 && ln -sfn /models/FlashVSR-v1.1 "$JUTSU/ComfyUI/models/FlashVSR-v1.1" || true
cd "$JUTSU/ComfyUI"
exec "$JUTSU/venv/bin/python" main.py "${FLAGS[@]}"
