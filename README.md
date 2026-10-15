# genie-jutsu-worker
Slim RunPod/ComfyUI worker image: ComfyUI v0.39.1 + pinned custom nodes (worker/custom_nodes.txt), torch cu130, CUDA 13 base.
No model weights and no secrets are included. Built by GitHub Actions to `ghcr.io/<owner>/genie-jutsu-worker`.
Runtime env: JUTSU_MANIFEST (model manifest path), JUTSU_SLATE, JUTSU_MAX_USD, JUTSU_RATE_USD_HR, JUTSU_IDLE_SECONDS. Port 8188.
