#!/usr/bin/env python3
"""Cheap preflight before Glancebar's full test suite on the worker host.

Exit 0 when the host is ready; 75 when the suite should defer (owner active or
the machine is temporarily overloaded). Other exits are explicit probe errors.
If focus-guard is not installed, only load is checked so generic CI keeps working.
"""
from __future__ import annotations

import os
import math
import shutil
import subprocess
import sys

DEFER = 75


def focus_guard_bin() -> str | None:
    for path in (os.path.expanduser("~/.local/bin/focus-guard"), shutil.which("focus-guard") or ""):
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def load_defer_reason() -> str | None:
    try:
        load1, _, _ = os.getloadavg()
    except (AttributeError, OSError) as exc:
        raise RuntimeError(f"cannot read system load: {exc}") from exc
    ncpu = os.cpu_count()
    if not ncpu or not math.isfinite(load1) or load1 < 0:
        raise RuntimeError("invalid system load or logical CPU count")
    if load1 > ncpu:
        return f"1-minute load {load1:.2f} exceeds {ncpu} logical CPU(s)"
    return None


def probe_focus_guard(fg: str, stderr) -> int:
    try:
        proc = subprocess.run([fg, "active"], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"test-host readiness: focus-guard probe failed: {exc}", file=stderr)
        return 2
    if proc.returncode == 0:
        detail = (proc.stdout or proc.stderr or "owner active").strip().split("\n", 1)[0]
        print(
            f"test-host readiness: deferred: focus-guard reports owner active ({detail})",
            file=stderr,
        )
        return DEFER
    if proc.returncode == 1:
        return 0
    msg = (proc.stderr or proc.stdout or f"unexpected exit {proc.returncode}").strip()
    print(f"test-host readiness: focus-guard probe error: {msg}", file=stderr)
    return 2


def check(*, stderr=None) -> int:
    if stderr is None:
        stderr = sys.stderr
    try:
        why = load_defer_reason()
    except RuntimeError as exc:
        print(f"test-host readiness: probe error: {exc}", file=stderr)
        return 2
    if why:
        print(f"test-host readiness: deferred: {why}", file=stderr)
        return DEFER
    fg = focus_guard_bin()
    if fg is None:
        return 0
    return probe_focus_guard(fg, stderr)


def main() -> None:
    raise SystemExit(check())


if __name__ == "__main__":
    main()
