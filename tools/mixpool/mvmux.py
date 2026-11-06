#!/usr/bin/env python3
"""mvmux — attach Apple Music lossless audio to a pulled music video.

Usage: mvmux.py <mv.mp4> <song.m4a> [-o out.m4v] [--keep-original-audio]

Finds the time offset between the MV's own audio and the lossless song by
cross-correlating downsampled mono mixes, then muxes: video stream copied,
ALAC in place of (or alongside) the original AAC. If the correlation peak is
weak the edits differ: it says so and exits non-zero without writing.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

SR = 11025  # correlation sample rate: plenty for second-scale alignment


def decode_mono(path: str, rate: int = SR) -> np.ndarray:
    with tempfile.TemporaryDirectory() as d:
        wav = str(Path(d) / "mono.f32")
        subprocess.run(
            ["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(rate),
             "-f", "f32le", "-y", wav],
            check=True,
        )
        return np.fromfile(wav, dtype=np.float32)


def best_offset(mv: np.ndarray, song: np.ndarray) -> tuple[int, float]:
    """Lag L (samples at SR) such that song(t) ~= mv(t - L), plus peak quality."""
    n = 1 << int(np.ceil(np.log2(len(mv) + len(song))))
    a = np.fft.rfft(mv, n)
    b = np.fft.rfft(song, n)
    corr = np.fft.irfft(a * np.conj(b), n)
    peak = int(np.argmax(corr))
    if peak > n // 2:
        peak -= n
    quality = float(corr[peak] / (np.linalg.norm(mv) * np.linalg.norm(song) + 1e-9))
    return peak, quality


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("mv")
    ap.add_argument("song")
    ap.add_argument("-o", "--out")
    ap.add_argument("--keep-original-audio", action="store_true")
    ap.add_argument("--min-quality", type=float, default=0.35)
    args = ap.parse_args()

    mv, song = decode_mono(args.mv), decode_mono(args.song)
    lag, quality = best_offset(mv, song)
    print(f"correlation quality {quality:.2f}, lag {lag} samples = {lag / SR:+.3f} s")
    if quality < args.min_quality:
        sys.exit(
            f"edits differ (quality {quality:.2f} < {args.min_quality}); "
            "keeping the MV's own audio"
        )

    out = args.out or str(Path(args.song).with_suffix(".m4v").with_name(
        Path(args.mv).stem + " [lossless].m4v"))
    cmd = ["ffmpeg", "-v", "error", "-y"]
    if lag >= 0:
        cmd += ["-i", args.mv, "-itsoffset", f"{lag / SR:.3f}", "-i", args.song]
    else:
        cmd += ["-i", args.mv, "-ss", f"{-lag / SR:.3f}", "-i", args.song]
    cmd += ["-map", "0:v:0", "-map", "1:a:0"]
    if args.keep_original_audio:
        cmd += ["-map", "0:a:0"]
    cmd += ["-c:v", "copy", "-c:a", "copy", "-shortest", "-movflags", "+faststart", out]
    subprocess.run(cmd, check=True)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
