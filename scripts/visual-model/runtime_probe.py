#!/usr/bin/env python3
"""Measure one Core ML tower in a fresh process and print aggregate JSON only."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import resource
import statistics
import subprocess
import time
from typing import Any

import coremltools as ct
import numpy as np
from PIL import Image, ImageDraw


IMAGE_SIZE = 384


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--tower", choices=("image", "text"), required=True)
    parser.add_argument("--tokens-file", type=Path)
    parser.add_argument("--token-case", default="case-02")
    parser.add_argument("--compute-units", default="ALL")
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--iterations", type=int, default=30)
    return parser.parse_args()


def directory_bytes(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def current_rss_bytes() -> int | None:
    try:
        value = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(os.getpid())],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return int(value) * 1024
    except (OSError, subprocess.CalledProcessError, ValueError):
        return None


def peak_rss_bytes() -> int:
    # Darwin reports ru_maxrss in bytes (Linux reports KiB).
    value = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    return value if os.uname().sysname == "Darwin" else value * 1024


def image_payload() -> dict[str, Any]:
    image = Image.new("RGB", (IMAGE_SIZE, IMAGE_SIZE), (236, 231, 219))
    draw = ImageDraw.Draw(image)
    draw.ellipse((74, 42, 310, 278), fill=(212, 171, 133), outline=(25, 24, 28), width=8)
    draw.ellipse((120, 116, 188, 176), outline=(20, 20, 22), width=9)
    draw.ellipse((196, 116, 264, 176), outline=(20, 20, 22), width=9)
    draw.line((188, 144, 196, 144), fill=(20, 20, 22), width=8)
    draw.arc((136, 152, 248, 238), start=20, end=160, fill=(90, 35, 35), width=7)
    return {"image": image}


def text_payload(path: Path | None, case_id: str) -> dict[str, Any]:
    if path is None:
        raise ValueError("--tokens-file is required for the text tower")
    payload = json.loads(path.read_text(encoding="utf-8"))
    case = next((item for item in payload["cases"] if item["id"] == case_id), None)
    if case is None:
        raise ValueError(f"token case not found: {case_id}")
    tokens = np.asarray(case["tokens"], dtype=np.int32).reshape(1, -1)
    return {"tokens": tokens}


def percentile(samples: list[float], value: float) -> float:
    return float(np.percentile(np.asarray(samples, dtype=np.float64), value))


def main() -> int:
    args = parse_args()
    if args.warmup < 0 or args.iterations < 1:
        raise ValueError("warmup must be non-negative and iterations positive")
    payload = image_payload() if args.tower == "image" else text_payload(
        args.tokens_file,
        args.token_case,
    )
    baseline_rss = current_rss_bytes()
    baseline_peak = peak_rss_bytes()
    load_started = time.perf_counter()
    model_type = (
        ct.models.CompiledMLModel
        if args.model.suffix == ".mlmodelc"
        else ct.models.MLModel
    )
    model = model_type(str(args.model), compute_units=getattr(ct.ComputeUnit, args.compute_units))
    load_ms = (time.perf_counter() - load_started) * 1000.0
    loaded_rss = current_rss_bytes()
    loaded_peak = peak_rss_bytes()

    first_started = time.perf_counter()
    model.predict(payload)
    first_ms = (time.perf_counter() - first_started) * 1000.0
    for _ in range(args.warmup):
        model.predict(payload)
    samples: list[float] = []
    for _ in range(args.iterations):
        started = time.perf_counter()
        model.predict(payload)
        samples.append((time.perf_counter() - started) * 1000.0)
    final_rss = current_rss_bytes()
    final_peak = peak_rss_bytes()
    result = {
        "tower": args.tower,
        "compute_units": args.compute_units,
        "artifact_bytes": directory_bytes(args.model),
        "model_load_ms": load_ms,
        "first_prediction_ms": first_ms,
        "warmup_iterations": args.warmup,
        "measured_iterations": args.iterations,
        "latency_ms": {
            "min": min(samples),
            "mean": statistics.fmean(samples),
            "p50": percentile(samples, 50),
            "p95": percentile(samples, 95),
            "max": max(samples),
        },
        "rss_bytes": {
            "baseline": baseline_rss,
            "after_model_load": loaded_rss,
            "after_predictions": final_rss,
            "load_delta": (
                loaded_rss - baseline_rss
                if loaded_rss is not None and baseline_rss is not None
                else None
            ),
            "prediction_delta_from_baseline": (
                final_rss - baseline_rss
                if final_rss is not None and baseline_rss is not None
                else None
            ),
            "peak_baseline": baseline_peak,
            "peak_after_model_load": loaded_peak,
            "peak_after_predictions": final_peak,
        },
    }
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
