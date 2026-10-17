# jutsu-worker: ComfyUI GPU worker for the Genie Jutsu "Genjutsu" engines (H3 / SCAIL-2 / Wan-Animate-2 / LTX / SeedVR2).
# NO MODELS ARE BAKED IN: weights live on a RunPod network volume (config/models.manifest.json,
# downloaded once by worker/bootstrap_volume.py). Keeps the image ~10 GB so FlashBoot / pulls stay fast.
#
#   docker build -f worker/Dockerfile -t <registry>/jutsu-worker:0.1 .      (context = repo root)
#
# Base: RunPod's stable CUDA 13.0 image (runpodctl, SSH, Jupyter preinstalled). CUDA 13 is required for
# torch cu130, whose cuBLASLt registers the scaled_mm_nvfp4 kernel (5090: 15 s H3 clip 755 s -> 518 s).
FROM runpod/base:1.4.0-cuda1300-ubuntu2404

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    HF_HUB_ENABLE_HF_TRANSFER=1 \
    JUTSU_PREFIX=/opt/jutsu \
    TORCH_CUDA_ARCH_LIST="8.9;12.0" \
    PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True

RUN apt-get update && apt-get install -y --no-install-recommends \
        git git-lfs ffmpeg libgl1 libglib2.0-0 python3.12 python3.12-venv python3.12-dev build-essential ninja-build curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY worker/custom_nodes.txt worker/install.sh worker/extra_model_paths.yaml worker/start.sh worker/bootstrap_volume.py worker/assemble_uploads.sh worker/patches/latentsync_audio_patch.py config/models.manifest.json /opt/jutsu-src/
# torch 2.13.0+cu130, ComfyUI v0.39.1, KJNodes, VHS, Spectrum-MiniMax-H3, LTXVideo, rgthree, RES4LYF, Fill-Nodes,
# controlnet_aux, Video-Depth-Anything, SageAttention 2.2.0 (sm_89 + sm_120), Veda-on-ComfyUI, Viggle-Animate-H3 + HyperFlow
# (Comfy Registry zips, sha256-pinned), H3-X2-Detailed (HF zip), FlashVSR_Ultra_Fast. SAM3/SeedVR2/SCAIL-2/H3/VACE nodes are native.
RUN PREFIX=/opt/jutsu bash /opt/jutsu-src/install.sh && rm -rf /root/.cache

EXPOSE 8188
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s CMD curl -fs http://127.0.0.1:8188/system_stats || exit 1
CMD ["bash", "/opt/jutsu-src/start.sh"]
