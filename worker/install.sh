#!/usr/bin/env bash
# Genie Jutsu worker install (shared by the Dockerfile AND the Phase-1 "install onto network volume" path).
#   PREFIX=/opt/jutsu  bash install.sh          # image build
#   PREFIX=/workspace/jutsu bash install.sh     # onto a RunPod network volume (persists across pods)
# Installs: Python venv, torch 2.13.0+cu130, ComfyUI v0.39.1 (>= 0.39 required: light H3 VAE, lower H3 peak VRAM, w6a8, ID-V2V, lighter SeedVR2), pinned custom nodes, SageAttention 2.2.0
# (built for sm_120 Blackwell, best-effort), hf_transfer. NO model weights (see config/models.manifest.json).
set -euo pipefail
PREFIX=${PREFIX:-/opt/jutsu}
COMFY_REF=${COMFY_REF:-v0.39.1}            # never below v0.39.0
TORCH_VER=${TORCH_VER:-2.13.0}
TORCHVISION_VER=${TORCHVISION_VER:-0.28.0}
CUDA_TAG=${CUDA_TAG:-cu130}
SAGE_REF=${SAGE_REF:-v2.2.0}
export TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST:-"8.9;12.0"}   # Ada (4090/L40S) + Blackwell (5090 / PRO 6000)
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$PREFIX"
if [ -f "$PREFIX/.install-ok-$COMFY_REF-$TORCH_VER" ]; then echo "[install] already installed in $PREFIX"; exit 0; fi
PY=${PY:-python3.12}
command -v uv >/dev/null 2>&1 || pip install -q uv || true
if command -v uv >/dev/null 2>&1; then uv venv -p "$PY" "$PREFIX/venv"; PIP="uv pip install -p $PREFIX/venv/bin/python"; else "$PY" -m venv "$PREFIX/venv"; PIP="$PREFIX/venv/bin/pip install"; fi
# Oct 8: a pod died on a single pypi.nvidia.com timeout (uv default 30 s x 3 retries). Longer timeout, more retries, and 4 tries.
export UV_HTTP_TIMEOUT=${UV_HTTP_TIMEOUT:-300} UV_HTTP_RETRIES=${UV_HTTP_RETRIES:-8} UV_CONCURRENT_DOWNLOADS=${UV_CONCURRENT_DOWNLOADS:-8}
retry() { local n; for n in 1 2 3 4; do "$@" && return 0; echo "[install] attempt $n failed: $*; retrying in $((n * 15))s"; sleep $((n * 15)); done; return 1; }
retry $PIP "torch==$TORCH_VER" "torchvision==$TORCHVISION_VER" torchaudio --index-url "https://download.pytorch.org/whl/$CUDA_TAG"
[ -d "$PREFIX/ComfyUI" ] || git clone --depth 1 --branch "$COMFY_REF" https://github.com/comfyanonymous/ComfyUI.git "$PREFIX/ComfyUI"
retry $PIP -r "$PREFIX/ComfyUI/requirements.txt"
retry $PIP hf_transfer huggingface_hub websocket-client opencv-python-headless triton
grep -vE '^\s*(#|$)' "$HERE/custom_nodes.txt" | while read -r url pin dir; do
  if [ -n "${dir:-}" ]; then                       # zip entry: <url> <sha256> <dir>  (Comfy Registry / HF hosted packs)
    d="$PREFIX/ComfyUI/custom_nodes/$dir"
    if [ ! -d "$d" ]; then
      tmpz=$(mktemp --suffix=.zip)
      curl -fsSL "$url" -o "$tmpz"
      echo "$pin  $tmpz" | sha256sum -c --quiet - || { echo "[install] FATAL sha256 mismatch for $dir"; exit 1; }
      mkdir -p "$d" && python3 -m zipfile -e "$tmpz" "$d" && rm -f "$tmpz"
      rm -rf "$d/__pycache__"
    fi
  else                                             # git entry: <url> <commit>
    d="$PREFIX/ComfyUI/custom_nodes/$(basename "$url")"
    if [ ! -d "$d" ]; then git clone "$url" "$d"; fi
    git -C "$d" fetch --depth 1 origin "$pin" 2>/dev/null || true
    git -C "$d" checkout -q "$pin" || echo "[install] WARN could not pin $(basename "$url") to $pin"
  fi
  [ -f "$d/requirements.txt" ] && $PIP -r "$d/requirements.txt" || true
done
# SageAttention 2.2.0 (2x attention on Blackwell; KJ PathchSageAttentionKJ / --use-sage-attention). Needs nvcc, not a GPU.
# Uses $PIP (uv venvs have no pip module: `python -m pip` failed on the first Phase-1 pod).
if command -v nvcc >/dev/null 2>&1; then
  ( tmp=$(mktemp -d) && git clone --depth 1 --branch "$SAGE_REF" https://github.com/thu-ml/SageAttention.git "$tmp/sage" \
    && cd "$tmp/sage" && $PIP setuptools wheel ninja packaging \
    && EXT_PARALLEL=4 NVCC_APPEND_FLAGS="--threads 8" MAX_JOBS=8 $PIP --no-build-isolation . ) \
    && echo "[install] SageAttention $SAGE_REF built" || echo "[install] WARN SageAttention build failed: ComfyUI falls back to PyTorch SDPA"
else
  echo "[install] WARN nvcc not found: skipping SageAttention (SDPA fallback)"
fi
cp "$HERE/extra_model_paths.yaml" "$PREFIX/ComfyUI/extra_model_paths.yaml"
"$PREFIX/venv/bin/python" -c "import torch; print('[install] torch', torch.__version__, 'cuda', torch.version.cuda)"
touch "$PREFIX/.install-ok-$COMFY_REF-$TORCH_VER"
echo "[install] done -> $PREFIX"
