#!/usr/bin/env python3
"""Convert PE-Core-S-16-384 into separate image/text Core ML models.

The conversion command is deliberately offline. Run fetch_assets.py explicitly
before this script; every source asset is re-hashed before model code is loaded.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import time
import traceback
from typing import Any


# These must be set before importing Hugging Face, OpenCLIP, or timm.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_DATASETS_OFFLINE"] = "1"
os.environ["TIMM_FUSED_ATTN"] = "0"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

import coremltools as ct
import numpy as np
from PIL import Image, ImageDraw
import torch
from torch import nn
from torch.nn import functional as F

from fetch_assets import DEFAULT_MANIFEST, DEFAULT_SOURCE_DIR, digest, load_manifest, validate


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
DEFAULT_WORK_DIR = REPO_ROOT / "work" / "pe_coreml"

MODEL_ID = "timm/PE-Core-S-16-384"
IMAGE_MODEL_NAME = "PECoreS16ImageFP16.mlpackage"
TEXT_MODEL_NAME = "PECoreS16TextFP16.mlpackage"
IMAGE_SIZE = 384
CONTEXT_LENGTH = 32
EMBED_DIM = 512


class ImageEncoder(nn.Module):
    def __init__(self, visual: nn.Module) -> None:
        super().__init__()
        self.visual = visual

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        return F.normalize(self.visual(image), dim=-1)


class TextEncoder(nn.Module):
    def __init__(self, text: nn.Module) -> None:
        super().__init__()
        self.text = text

    def forward(self, tokens: torch.Tensor) -> torch.Tensor:
        return F.normalize(self.text(tokens), dim=-1)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--source-dir", type=Path, default=DEFAULT_SOURCE_DIR)
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--iterations", type=int, default=10)
    parser.add_argument(
        "--compute-units",
        choices=("ALL", "CPU_AND_NE", "CPU_AND_GPU", "CPU_ONLY"),
        default="ALL",
    )
    parser.add_argument("--skip-benchmark", action="store_true")
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


def sha256(path: Path) -> str:
    return digest(path)[1]


def verify_sources(manifest_path: Path, source_dir: Path) -> dict[str, Any]:
    manifest = load_manifest(manifest_path)
    failures: list[str] = []
    assets: list[dict[str, Any]] = []
    for asset in manifest["assets"]:
        path = source_dir / asset["path"]
        ok, detail = validate(path, asset)
        assets.append(
            {
                "path": str(path),
                "bytes": asset["bytes"],
                "sha256": asset["sha256"],
                "verified": ok,
            }
        )
        if not ok:
            failures.append(f"{asset['path']}: {detail}")
    if failures:
        raise RuntimeError("source verification failed: " + "; ".join(failures))
    return {
        "manifest_path": str(manifest_path),
        "manifest_sha256": sha256(manifest_path),
        "model": manifest["model"],
        "implementation": manifest["implementation"],
        "assets": assets,
    }


def command_output(*command: str) -> str | None:
    try:
        return subprocess.check_output(command, text=True, stderr=subprocess.DEVNULL).strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def environment_info() -> dict[str, Any]:
    import open_clip
    import timm

    return {
        "python": sys.version.split()[0],
        "platform": platform.platform(),
        "machine": platform.machine(),
        "macos": command_output("sw_vers", "-productVersion"),
        "macos_build": command_output("sw_vers", "-buildVersion"),
        "hardware": command_output("sysctl", "-n", "machdep.cpu.brand_string"),
        "torch": torch.__version__,
        "coremltools": ct.__version__,
        "open_clip": open_clip.__version__,
        "timm": timm.__version__,
        "numpy": np.__version__,
        "offline_environment": {
            key: os.environ[key]
            for key in (
                "HF_HUB_OFFLINE",
                "TRANSFORMERS_OFFLINE",
                "HF_DATASETS_OFFLINE",
                "TIMM_FUSED_ATTN",
            )
        },
    }


def load_model(source_dir: Path) -> tuple[nn.Module, Any]:
    from timm.layers import set_fused_attn
    import open_clip

    set_fused_attn(False)
    model = open_clip.create_model(
        f"local-dir:{source_dir.resolve()}",
        precision="fp32",
        device="cpu",
        require_pretrained=True,
        weights_only=True,
    )
    model.eval()
    if not hasattr(model, "visual") or not hasattr(model, "text"):
        raise TypeError(f"expected split CustomTextCLIP towers, got {type(model).__name__}")

    tokenizer = open_clip.tokenizer.SimpleTokenizer(
        bpe_path=str(source_dir / "bpe_simple_vocab_16e6.txt.gz"),
        context_length=CONTEXT_LENGTH,
    )
    return model, tokenizer


def image_cases() -> dict[str, np.ndarray]:
    size = IMAGE_SIZE
    gray = np.full((size, size, 3), 127, dtype=np.uint8)
    ramp = np.linspace(0, 255, size, dtype=np.uint8)
    gradient = np.empty((size, size, 3), dtype=np.uint8)
    gradient[:, :, 0] = ramp[None, :]
    gradient[:, :, 1] = ramp[:, None]
    gradient[:, :, 2] = 255 - ramp[None, :]
    rng = np.random.default_rng(20260728)
    noise = rng.integers(0, 256, size=(size, size, 3), dtype=np.uint8)
    geometry_image = Image.new("RGB", (size, size), (236, 231, 219))
    draw = ImageDraw.Draw(geometry_image)
    draw.ellipse((74, 42, 310, 278), fill=(212, 171, 133), outline=(25, 24, 28), width=8)
    draw.ellipse((120, 116, 188, 176), outline=(20, 20, 22), width=9)
    draw.ellipse((196, 116, 264, 176), outline=(20, 20, 22), width=9)
    draw.line((188, 144, 196, 144), fill=(20, 20, 22), width=8)
    draw.arc((136, 152, 248, 238), start=20, end=160, fill=(90, 35, 35), width=7)
    geometry = np.asarray(geometry_image, dtype=np.uint8)
    return {
        "gray": gray,
        "gradient": gradient,
        "seeded_noise": noise,
        "face_with_glasses_drawing": geometry,
    }


TEXT_CASES = [
    "a man",
    "a man with glasses",
    "Harry Potter",
    "A person looking at a laptop.",
    "Fish &amp; chips &lt;3 &gt; 2",
    "We're testing contractions: can't, won't, I'd, they've.",
    "Punctuation!? ... [brackets] {braces} /slash\\backslash — “quotes”",
    "Café — 東京 👓 🧙🏽‍♂️",
    "passage " * 80 + "TRUNCATION_SENTINEL",
]


def preprocess_image(array: np.ndarray) -> torch.Tensor:
    value = array.astype(np.float32) / 127.5 - 1.0
    return torch.from_numpy(value.transpose(2, 0, 1)).unsqueeze(0)


def tensor_to_array(value: torch.Tensor) -> np.ndarray:
    return value.detach().cpu().numpy().astype(np.float32).reshape(-1)


def write_tokenizer_fixtures(
    report_dir: Path,
    tokenizer: Any,
) -> tuple[Path, str, np.ndarray]:
    token_batch = tokenizer(TEXT_CASES).to(dtype=torch.int32).numpy()
    cases = []
    for index, text in enumerate(TEXT_CASES):
        tokens = [int(value) for value in token_batch[index].tolist()]
        cases.append(
            {
                "id": f"case-{index + 1:02d}",
                "text": text,
                "tokens": tokens,
                "token_count": len(tokens),
                "last_non_padding_index": max(
                    (position for position, value in enumerate(tokens) if value != 0),
                    default=-1,
                ),
            }
        )
    payload = {
        "schema_version": 1,
        "tokenizer": "OpenAI CLIP byte BPE",
        "vocabulary_sha256": "924691ac288e54409236115652ad4aa250f48203de50a9e4722a6ecd48d6804a",
        "context_length": CONTEXT_LENGTH,
        "start_of_text_token": 49406,
        "end_of_text_token": 49407,
        "padding_token": 0,
        "cases": cases,
    }
    report_dir.mkdir(parents=True, exist_ok=True)
    destination = report_dir / "tokenizer-fixtures.json"
    temporary = destination.with_suffix(".json.partial")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(payload, stream, indent=2, sort_keys=True, ensure_ascii=False)
        stream.write("\n")
    temporary.replace(destination)
    return destination, sha256(destination), token_batch


def cosine(left: np.ndarray, right: np.ndarray) -> float:
    denominator = float(np.linalg.norm(left) * np.linalg.norm(right))
    return float(np.dot(left, right) / denominator) if denominator else 0.0


def compare(reference: np.ndarray, candidate: np.ndarray) -> dict[str, float]:
    delta = np.abs(reference.astype(np.float64) - candidate.astype(np.float64))
    return {
        "cosine_similarity": cosine(reference, candidate),
        "max_abs_error": float(delta.max()),
        "mean_abs_error": float(delta.mean()),
        "reference_l2_norm": float(np.linalg.norm(reference)),
        "candidate_l2_norm": float(np.linalg.norm(candidate)),
    }


def trace_towers(
    model: nn.Module,
    tokenizer: Any,
    images: dict[str, np.ndarray],
) -> tuple[torch.jit.ScriptModule, torch.jit.ScriptModule, dict[str, np.ndarray], dict[str, np.ndarray], np.ndarray]:
    image_encoder = ImageEncoder(model.visual).eval()
    text_encoder = TextEncoder(model.text).eval()
    image_example = preprocess_image(images["gradient"])
    token_batch = tokenizer(TEXT_CASES).to(dtype=torch.int32)

    with torch.inference_mode():
        image_references = {
            name: tensor_to_array(image_encoder(preprocess_image(value)))
            for name, value in images.items()
        }
        text_output = text_encoder(token_batch)
        text_references = {
            text: tensor_to_array(text_output[index : index + 1])
            for index, text in enumerate(TEXT_CASES)
        }
        image_trace = torch.jit.trace(
            image_encoder,
            image_example,
            strict=False,
            check_trace=False,
        ).eval()
        text_trace = torch.jit.trace(
            text_encoder,
            token_batch[0:1],
            strict=False,
            check_trace=False,
        ).eval()

    return image_trace, text_trace, image_references, text_references, token_batch.numpy()


def replace_package(model: ct.models.MLModel, destination: Path, overwrite: bool) -> None:
    if destination.exists():
        if not overwrite:
            raise FileExistsError(f"{destination} exists; pass --overwrite to replace it")
        if destination.is_dir():
            shutil.rmtree(destination)
        else:
            destination.unlink()
    destination.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(destination))


def add_metadata(model: ct.models.MLModel, tower: str, provenance: dict[str, Any]) -> None:
    revision = provenance["model"]["revision"]
    model.author = "Meta (source model); Passage conversion pipeline"
    model.license = "Apache-2.0; see LICENSE.PE"
    model.short_description = f"Normalized 512-dimensional PE-Core-S-16-384 {tower} encoder"
    model.version = revision[:12]
    model.user_defined_metadata.update(
        {
            "passage.model_id": MODEL_ID,
            "passage.model_revision": revision,
            "passage.source_manifest_sha256": provenance["manifest_sha256"],
            "passage.tower": tower,
            "passage.output_normalized": "true",
            "passage.converter": f"coremltools {ct.__version__}",
            "passage.minimum_deployment_target": "macOS 14",
        }
    )


def convert_models(
    image_trace: torch.jit.ScriptModule,
    text_trace: torch.jit.ScriptModule,
    output_dir: Path,
    provenance: dict[str, Any],
    overwrite: bool,
) -> tuple[Path, Path, dict[str, float]]:
    timings: dict[str, float] = {}
    started = time.perf_counter()
    image_model = ct.convert(
        image_trace,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.ImageType(
                name="image",
                shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE),
                color_layout=ct.colorlayout.RGB,
                scale=1.0 / 127.5,
                bias=[-1.0, -1.0, -1.0],
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
    )
    timings["image_conversion_seconds"] = time.perf_counter() - started
    add_metadata(image_model, "image", provenance)
    image_path = output_dir / IMAGE_MODEL_NAME
    replace_package(image_model, image_path, overwrite)

    started = time.perf_counter()
    text_model = ct.convert(
        text_trace,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.TensorType(
                name="tokens",
                shape=(1, CONTEXT_LENGTH),
                dtype=np.int32,
            )
        ],
        outputs=[ct.TensorType(name="embedding")],
    )
    timings["text_conversion_seconds"] = time.perf_counter() - started
    add_metadata(text_model, "text", provenance)
    text_path = output_dir / TEXT_MODEL_NAME
    replace_package(text_model, text_path, overwrite)
    return image_path, text_path, timings


def output_vector(prediction: dict[str, Any]) -> np.ndarray:
    if "embedding" not in prediction:
        raise KeyError(f"Core ML result has no embedding output: {sorted(prediction)}")
    return np.asarray(prediction["embedding"], dtype=np.float32).reshape(-1)


def percentile(values: list[float], quantile: float) -> float:
    return float(np.percentile(np.asarray(values, dtype=np.float64), quantile))


def benchmark_model(
    model: ct.models.MLModel,
    payload: dict[str, Any],
    warmup: int,
    iterations: int,
) -> dict[str, Any]:
    first_started = time.perf_counter()
    model.predict(payload)
    first_ms = (time.perf_counter() - first_started) * 1000.0
    for _ in range(warmup):
        model.predict(payload)
    samples: list[float] = []
    for _ in range(iterations):
        started = time.perf_counter()
        model.predict(payload)
        samples.append((time.perf_counter() - started) * 1000.0)
    return {
        "first_prediction_ms": first_ms,
        "warmup_iterations": warmup,
        "measured_iterations": iterations,
        "latency_ms": {
            "min": min(samples),
            "mean": statistics.fmean(samples),
            "p50": percentile(samples, 50),
            "p95": percentile(samples, 95),
            "max": max(samples),
            "samples": samples,
        },
    }


def load_coreml(path: Path, compute_units: str) -> tuple[ct.models.MLModel, float]:
    started = time.perf_counter()
    model = ct.models.MLModel(
        str(path),
        compute_units=getattr(ct.ComputeUnit, compute_units),
    )
    return model, (time.perf_counter() - started) * 1000.0


def evaluate(
    image_path: Path,
    text_path: Path,
    images: dict[str, np.ndarray],
    image_references: dict[str, np.ndarray],
    text_references: dict[str, np.ndarray],
    token_batch: np.ndarray,
    compute_units: str,
    warmup: int,
    iterations: int,
    skip_benchmark: bool,
) -> dict[str, Any]:
    image_model, image_load_ms = load_coreml(image_path, compute_units)
    text_model, text_load_ms = load_coreml(text_path, compute_units)

    image_parity: dict[str, Any] = {}
    for name, array in images.items():
        prediction = image_model.predict({"image": Image.fromarray(array)})
        image_parity[name] = compare(image_references[name], output_vector(prediction))

    text_parity: dict[str, Any] = {}
    for index, text in enumerate(TEXT_CASES):
        prediction = text_model.predict({"tokens": token_batch[index : index + 1].astype(np.int32)})
        text_parity[text] = compare(text_references[text], output_vector(prediction))

    image_min_cosine = min(value["cosine_similarity"] for value in image_parity.values())
    text_min_cosine = min(value["cosine_similarity"] for value in text_parity.values())
    parity = {
        "thresholds": {"image_min_cosine": 0.995, "text_min_cosine": 0.995},
        "image": image_parity,
        "text": text_parity,
        "summary": {
            "image_min_cosine": image_min_cosine,
            "text_min_cosine": text_min_cosine,
            "passed": image_min_cosine >= 0.995 and text_min_cosine >= 0.995,
        },
    }

    benchmark: dict[str, Any] = {
        "compute_units": compute_units,
        "model_load_ms": {"image": image_load_ms, "text": text_load_ms},
        "skipped": skip_benchmark,
    }
    if not skip_benchmark:
        benchmark["image"] = benchmark_model(
            image_model,
            {"image": Image.fromarray(images["face_with_glasses_drawing"])},
            warmup,
            iterations,
        )
        benchmark["text"] = benchmark_model(
            text_model,
            {"tokens": token_batch[1:2].astype(np.int32)},
            warmup,
            iterations,
        )
    return {"parity": parity, "benchmark": benchmark}


def package_manifest(path: Path) -> dict[str, Any]:
    files: list[dict[str, Any]] = []
    total = 0
    tree_hash = hashlib.sha256()
    for file_path in sorted(item for item in path.rglob("*") if item.is_file()):
        relative = file_path.relative_to(path).as_posix()
        size, file_hash = digest(file_path)
        total += size
        files.append({"path": relative, "bytes": size, "sha256": file_hash})
        tree_hash.update(f"{relative}\0{size}\0{file_hash}\n".encode())
    return {
        "path": str(path),
        "bytes": total,
        "tree_sha256": tree_hash.hexdigest(),
        "files": files,
    }


def parameter_counts(model: nn.Module) -> dict[str, int]:
    return {
        "total": sum(parameter.numel() for parameter in model.parameters()),
        "image": sum(parameter.numel() for parameter in model.visual.parameters()),
        "text": sum(parameter.numel() for parameter in model.text.parameters()),
    }


def write_report(report_dir: Path, report: dict[str, Any]) -> Path:
    report_dir.mkdir(parents=True, exist_ok=True)
    destination = report_dir / "conversion-report.json"
    temporary = destination.with_suffix(".json.partial")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(report, stream, indent=2, sort_keys=True, ensure_ascii=False)
        stream.write("\n")
    temporary.replace(destination)
    return destination


def main() -> int:
    args = parse_args()
    report_dir = args.work_dir / "reports"
    output_dir = args.work_dir / "models"
    report: dict[str, Any] = {
        "schema_version": 1,
        "status": "running",
        "started_at_unix": time.time(),
        "arguments": {
            "source_dir": str(args.source_dir),
            "work_dir": str(args.work_dir),
            "compute_units": args.compute_units,
            "warmup": args.warmup,
            "iterations": args.iterations,
            "skip_benchmark": args.skip_benchmark,
        },
    }
    try:
        if args.warmup < 0 or args.iterations < 1:
            raise ValueError("warmup must be non-negative and iterations must be positive")
        report["provenance"] = verify_sources(args.manifest, args.source_dir)
        report["environment"] = environment_info()

        started = time.perf_counter()
        model, tokenizer = load_model(args.source_dir)
        report["model"] = {
            "parameter_counts": parameter_counts(model),
            "image_size": IMAGE_SIZE,
            "context_length": CONTEXT_LENGTH,
            "embedding_dimension": EMBED_DIM,
            "tokenizer": "OpenAI CLIP byte BPE from pinned Meta vocabulary",
            "start_of_text_token": 49406,
            "end_of_text_token": 49407,
            "padding_token": 0,
        }
        report["timings"] = {"pytorch_model_load_seconds": time.perf_counter() - started}

        fixture_path, fixture_sha256, _ = write_tokenizer_fixtures(report_dir, tokenizer)
        report["tokenizer_fixtures"] = {
            "path": str(fixture_path),
            "sha256": fixture_sha256,
            "case_count": len(TEXT_CASES),
        }

        images = image_cases()
        started = time.perf_counter()
        image_trace, text_trace, image_refs, text_refs, tokens = trace_towers(model, tokenizer, images)
        report["timings"]["pytorch_trace_and_reference_seconds"] = time.perf_counter() - started
        del model

        image_path, text_path, conversion_timings = convert_models(
            image_trace,
            text_trace,
            output_dir,
            report["provenance"],
            args.overwrite,
        )
        report["timings"].update(conversion_timings)
        del image_trace, text_trace

        report.update(
            evaluate(
                image_path,
                text_path,
                images,
                image_refs,
                text_refs,
                tokens,
                args.compute_units,
                args.warmup,
                args.iterations,
                args.skip_benchmark,
            )
        )
        report["artifacts"] = {
            "image": package_manifest(image_path),
            "text": package_manifest(text_path),
        }
        report["status"] = "passed" if report["parity"]["summary"]["passed"] else "parity_failed"
        report["finished_at_unix"] = time.time()
        report_path = write_report(report_dir, report)
        print(json.dumps(report["parity"]["summary"], indent=2))
        print(f"report: {report_path}")
        return 0 if report["status"] == "passed" else 3
    except Exception as error:
        report["status"] = "failed"
        report["finished_at_unix"] = time.time()
        report["error"] = {
            "type": type(error).__name__,
            "message": str(error),
            "traceback": traceback.format_exc(),
        }
        report_path = write_report(report_dir, report)
        print(f"conversion failed: {type(error).__name__}: {error}", file=sys.stderr)
        print(f"failure report: {report_path}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
