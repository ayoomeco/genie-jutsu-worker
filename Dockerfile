# Genie Jutsu slim worker: ComfyUI + pinned custom nodes. NO models, NO secrets.
# Models are fetched at pod boot from a manifest supplied at runtime ($JUTSU_MANIFEST or <volume>/slate/models.manifest.json).
FROM runpod/base:1.4.0-cuda1300-ubuntu2404
ENV DEBIAN_FRONTEND=noninteractive PYTHONUNBUFFERED=1 HF_HUB_ENABLE_HF_TRANSFER=1 JUTSU_PREFIX=/opt/jutsu \
    TORCH_CUDA_ARCH_LIST="8.9;12.0" PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
RUN apt-get update && apt-get install -y --no-install-recommends git git-lfs ffmpeg libgl1 libglib2.0-0 \
      python3.12 python3.12-venv python3.12-dev build-essential ninja-build curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY worker/ /opt/jutsu-src/
RUN PREFIX=/opt/jutsu bash /opt/jutsu-src/install.sh && rm -rf /root/.cache /tmp/* \
    && find /opt/jutsu -name '__pycache__' -prune -exec rm -rf {} + \
    && chmod +x /opt/jutsu-src/*.sh
EXPOSE 8188
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s CMD curl -fs http://127.0.0.1:8188/system_stats || exit 1
CMD ["bash", "/opt/jutsu-src/entrypoint.sh"]
