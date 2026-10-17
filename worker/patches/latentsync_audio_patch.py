"""Idempotent patch for ComfyUI-LatentSyncWrapper @360d528 (Oct 16 A100 crash:
"TorchCodec is required for save_with_torchcodec"). torchaudio>=2.9 routes save/load through TorchCodec, and
torchvision 0.28 has no io.write_video/io.read_video. Replaced with soundfile / imageio-ffmpeg.
Audio: PCM_16 WAV, numpy [samples, channels], clipped to +-1.   Usage: python latentsync_audio_patch.py <pack_dir>"""
import pathlib, re, sys

MARK = "# JUTSU_PATCH_v1"
HELPERS = MARK + '''
import numpy as _jnp, soundfile as _jsf
def _jutsu_save_wav(path, waveform, sample_rate):
    """torchaudio.save replacement: [channels, samples] -> PCM_16 wav via soundfile ([samples, channels], clipped +-1)."""
    a = waveform.detach().cpu().float().numpy() if hasattr(waveform, "detach") else _jnp.asarray(waveform, dtype=_jnp.float32)
    if a.ndim == 3: a = a[0]
    if a.ndim == 1: a = a[None, :]
    _jsf.write(str(path), _jnp.clip(a.T, -1.0, 1.0), int(sample_rate), subtype="PCM_16", format="WAV")
def _jutsu_load_wav(path, *a, **k):
    """torchaudio.load replacement -> (float32 tensor [channels, samples], sr)."""
    import torch as _t
    d, sr = _jsf.read(str(path), dtype="float32", always_2d=True)
    return _t.from_numpy(d.T.copy()), sr
def _jutsu_write_video(path, frames_uint8, fps):
    import imageio
    with imageio.get_writer(str(path), fps=fps, codec="libx264", macro_block_size=1, ffmpeg_params=["-crf", "13"], ffmpeg_log_level="error") as w:
        for f in frames_uint8: w.append_data(f.numpy() if hasattr(f, "numpy") else f)
def _jutsu_read_video(path):
    import imageio, torch as _t
    r = imageio.get_reader(str(path), "ffmpeg"); fr = [x for x in r]; r.close()
    return _t.from_numpy(_jnp.stack(fr))
'''


NOLOOP_MARK = "# JUTSU_NOLOOP_v1"
NOLOOP = """        """ + NOLOOP_MARK + """: baseline policy forbids looping/ping-ponging frames to fit longer audio; reject instead
        import os as _jos
        if _jos.environ.get("JUTSU_LS_NO_LOOP", "1") != "0" and len(whisper_chunks) > len(video_frames) + int(_jos.environ.get("JUTSU_LS_LOOP_TOL", "1")):
            raise RuntimeError(f"JUTSU no-loop: audio needs {len(whisper_chunks)} frames, video has {len(video_frames)} (duration mismatch)")
"""


def patch_noloop(pack):
    p = pathlib.Path(pack) / "latentsync/pipelines/lipsync_pipeline.py"; s = p.read_text()
    if NOLOOP_MARK in s:
        print("[ls-patch] no-loop already patched"); return
    sig = "    def loop_video(self, whisper_chunks: list, video_frames: np.ndarray):\n"
    assert sig in s, "upstream changed: loop_video signature"
    p.write_text(s.replace(sig, sig + NOLOOP, 1)); print("[ls-patch] no-loop guard added to loop_video")


def patch(pack):
    patch_noloop(pack)
    p = pathlib.Path(pack) / "nodes.py"; s = p.read_text()
    if MARK in s:
        print("[ls-patch] already patched"); return 0
    s = s.replace("import torchaudio\n", "import torchaudio\n" + HELPERS, 1)
    n_save = len(re.findall(r"torchaudio\.save\(", s)); n_load = len(re.findall(r"torchaudio\.load\(", s))
    s = re.sub(r"torchaudio\.save\(", "_jutsu_save_wav(", s); s = re.sub(r"torchaudio\.load\(", "_jutsu_load_wav(", s)
    old_w = "io.write_video(temp_video_path, frames_cpu, fps=25, video_codec='h264')"
    old_r = "io.read_video(output_video_path, pts_unit='sec')[0]"
    assert old_w in s and old_r in s, "upstream changed: re-check pin"
    s = s.replace(old_w, "_jutsu_write_video(temp_video_path, frames_cpu, 25)").replace(old_r, "_jutsu_read_video(output_video_path)")
    left = re.findall(r"torchaudio\.(?:save|load)\(|io\.(?:write|read)_video\(", s)
    assert not left, left
    p.write_text(s); print(f"[ls-patch] patched nodes.py: torchaudio.save x{n_save}, torchaudio.load x{n_load}, write_video, read_video"); return 0


if __name__ == "__main__":
    sys.exit(patch(sys.argv[1]))
