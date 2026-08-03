#!/usr/bin/env python3
"""Quantize, compile, benchmark, and assemble the Passage PE model pack."""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import traceback
from typing import Any

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_DATASETS_OFFLINE"] = "1"
os.environ["TIMM_FUSED_ATTN"] = "0"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

import coremltools as ct
from coremltools.optimize import coreml as cto
import numpy as np
from PIL import Image
import torch

import convert_pe_coreml as conversion


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
DEFAULT_WORK_DIR = REPO_ROOT / "work" / "pe_coreml"
REVISION = "3249a38eb1c432ec19231c6fe1774acb6a4e4efe"
PACK_IDENTIFIER = "meta-pe-core-s-16-384"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, default=DEFAULT_WORK_DIR)
    parser.add_argument("--source-dir", type=Path, default=conversion.DEFAULT_SOURCE_DIR)
    parser.add_argument("--compute-units", default="CPU_AND_NE")
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--iterations", type=int, default=30)
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


def remove_existing(path: Path, overwrite: bool) -> None:
    if not path.exists():
        return
    if not overwrite:
        raise FileExistsError(f"{path} exists; pass --overwrite to replace it")
    if path.is_dir():
        shutil.rmtree(path)
    else:
        path.unlink()


def quantize(source: Path, destination: Path, tower: str, overwrite: bool) -> float:
    remove_existing(destination, overwrite)
    started = time.perf_counter()
    model = ct.models.MLModel(str(source), skip_model_load=True)
    quantizer = cto.OpLinearQuantizerConfig(
        mode="linear_symmetric",
        dtype="int8",
        granularity="per_channel",
        weight_threshold=2_048,
    )
    # Quantizing every large constant also catches 2-D RoPE tables, position
    # embeddings, and token embeddings. Those are unusually error-sensitive
    # and are not matrix weights. Compress only conv/linear weights; the small
    # positional constants and the text lookup table remain FP16.
    config = cto.OptimizationConfig(
        op_type_configs={"conv": quantizer, "linear": quantizer},
    )
    compressed = cto.linear_quantize_weights(model, config)
    compressed.user_defined_metadata.update(
        {
            "passage.weight_storage": "hybrid-int8-linear-conv-fp16-embeddings",
            "passage.quantization_weight_threshold": "2048",
            "passage.tower": tower,
        }
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    compressed.save(str(destination))
    return time.perf_counter() - started


def compile_package(source: Path, output_root: Path, overwrite: bool) -> tuple[Path, float]:
    destination = output_root / f"{source.stem}.mlmodelc"
    remove_existing(destination, overwrite)
    output_root.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    completed = subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(source), str(output_root)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    elapsed = time.perf_counter() - started
    if not destination.is_dir():
        raise RuntimeError(
            "coremlcompiler succeeded without expected output; "
            f"stdout={completed.stdout[-500:]!r} stderr={completed.stderr[-500:]!r}"
        )
    return destination, elapsed


def pytorch_references(
    source_dir: Path,
    report_dir: Path,
) -> tuple[dict[str, np.ndarray], dict[str, np.ndarray], np.ndarray, dict[str, np.ndarray]]:
    model, tokenizer = conversion.load_model(source_dir)
    fixture_path, fixture_sha, token_batch = conversion.write_tokenizer_fixtures(
        report_dir,
        tokenizer,
    )
    images = conversion.image_cases()
    image_encoder = conversion.ImageEncoder(model.visual).eval()
    text_encoder = conversion.TextEncoder(model.text).eval()
    with torch.inference_mode():
        image_refs = {
            name: conversion.tensor_to_array(image_encoder(conversion.preprocess_image(value)))
            for name, value in images.items()
        }
        text_values = text_encoder(torch.from_numpy(token_batch).to(dtype=torch.int32))
        text_refs = {
            text: conversion.tensor_to_array(text_values[index : index + 1])
            for index, text in enumerate(conversion.TEXT_CASES)
        }
    del model, image_encoder, text_encoder
    fixture = {
        "path": str(fixture_path),
        "sha256": fixture_sha,
        "case_count": len(conversion.TEXT_CASES),
    }
    return image_refs, text_refs, token_batch, {"images": images, "fixture": fixture}


def parity(
    image_model_path: Path,
    text_model_path: Path,
    image_refs: dict[str, np.ndarray],
    text_refs: dict[str, np.ndarray],
    token_batch: np.ndarray,
    images: dict[str, np.ndarray],
    compute_units: str,
) -> dict[str, Any]:
    units = getattr(ct.ComputeUnit, compute_units)
    image_model = ct.models.CompiledMLModel(str(image_model_path), compute_units=units)
    text_model = ct.models.CompiledMLModel(str(text_model_path), compute_units=units)
    image_results = {}
    for name, value in images.items():
        candidate = conversion.output_vector(
            image_model.predict({"image": Image.fromarray(value)})
        )
        image_results[name] = conversion.compare(image_refs[name], candidate)
    text_results = {}
    for index, text in enumerate(conversion.TEXT_CASES):
        candidate = conversion.output_vector(
            text_model.predict({"tokens": token_batch[index : index + 1].astype(np.int32)})
        )
        text_results[text] = conversion.compare(text_refs[text], candidate)
    image_min = min(item["cosine_similarity"] for item in image_results.values())
    text_min = min(item["cosine_similarity"] for item in text_results.values())
    return {
        "image": image_results,
        "text": text_results,
        "summary": {
            "image_min_cosine": image_min,
            "text_min_cosine": text_min,
            "passed": image_min >= 0.995 and text_min >= 0.995,
        },
    }


def runtime_probe(
    model: Path,
    tower: str,
    fixture_path: Path,
    compute_units: str,
    warmup: int,
    iterations: int,
) -> dict[str, Any]:
    command = [
        sys.executable,
        str(SCRIPT_DIR / "runtime_probe.py"),
        "--model",
        str(model),
        "--tower",
        tower,
        "--compute-units",
        compute_units,
        "--warmup",
        str(warmup),
        "--iterations",
        str(iterations),
    ]
    if tower == "text":
        command.extend(["--tokens-file", str(fixture_path), "--token-case", "case-02"])
    completed = subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={
            **os.environ,
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "HF_DATASETS_OFFLINE": "1",
        },
    )
    return json.loads(completed.stdout)


def file_digest(path: Path) -> tuple[int, str]:
    sha = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            size += len(chunk)
            sha.update(chunk)
    return size, sha.hexdigest()


def copy_tree_artifacts(
    source: Path,
    pack_root: Path,
    relative_root: Path,
    role: str,
) -> list[dict[str, Any]]:
    artifacts = []
    for source_file in sorted(item for item in source.rglob("*") if item.is_file()):
        relative = relative_root / source_file.relative_to(source)
        destination = pack_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        shutil.copyfile(source_file, destination)
        os.chmod(destination, 0o600)
        size, digest = file_digest(destination)
        artifacts.append(
            {
                "role": role,
                "relativePath": relative.as_posix(),
                "byteCount": size,
                "sha256": digest,
            }
        )
    return artifacts


def copy_file_artifact(
    source: Path,
    pack_root: Path,
    relative: Path,
    role: str,
) -> dict[str, Any]:
    destination = pack_root / relative
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    shutil.copyfile(source, destination)
    os.chmod(destination, 0o600)
    size, digest = file_digest(destination)
    return {
        "role": role,
        "relativePath": relative.as_posix(),
        "byteCount": size,
        "sha256": digest,
    }


def write_uncompressed_merges_artifact(
    source: Path,
    pack_root: Path,
) -> dict[str, Any]:
    relative = Path("tokenizer") / "bpe_simple_vocab_16e6.txt"
    destination = pack_root / relative
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with gzip.open(source, "rb") as compressed, destination.open("wb") as output:
        shutil.copyfileobj(compressed, output, length=1024 * 1024)
    os.chmod(destination, 0o600)
    size, digest = file_digest(destination)
    return {
        "role": "tokenizer-merges",
        "relativePath": relative.as_posix(),
        "byteCount": size,
        "sha256": digest,
    }


def build_pack(
    image_compiled: Path,
    text_compiled: Path,
    source_dir: Path,
    pack_root: Path,
    overwrite: bool,
) -> dict[str, Any]:
    remove_existing(pack_root, overwrite)
    pack_root.mkdir(parents=True, mode=0o700)
    image_relative = Path("models") / "PECoreS16ImageW8.mlmodelc"
    text_relative = Path("models") / "PECoreS16TextW8.mlmodelc"
    artifacts = []
    artifacts.extend(
        copy_tree_artifacts(image_compiled, pack_root, image_relative, "image-encoder")
    )
    artifacts.extend(
        copy_tree_artifacts(text_compiled, pack_root, text_relative, "text-encoder")
    )
    artifacts.append(
        copy_file_artifact(
            source_dir / "bpe_simple_vocab_16e6.txt.gz",
            pack_root,
            Path("tokenizer") / "bpe_simple_vocab_16e6.txt.gz",
            "tokenizer-vocabulary",
        )
    )
    artifacts.append(
        write_uncompressed_merges_artifact(
            source_dir / "bpe_simple_vocab_16e6.txt.gz",
            pack_root,
        )
    )
    artifacts.append(
        copy_file_artifact(source_dir / "LICENSE.PE", pack_root, Path("LICENSE.PE"), "license")
    )
    artifacts.sort(key=lambda item: (item["relativePath"], item["role"]))
    manifest = {
        "formatVersion": 1,
        "identifier": PACK_IDENTIFIER,
        "revision": REVISION,
        "model": {
            "displayName": "Meta PE-Core-S-16-384",
            "provider": "Meta",
            "architecture": "PE-Core-S-16-384 dual encoder; hybrid W8 weight-only Core ML",
            "imageEncoderPath": image_relative.as_posix(),
            "textEncoderPath": text_relative.as_posix(),
            "preprocessingRevision": "rgb-384-squash-bilinear-mean-0.5-std-0.5-openai-bpe-32-v1",
            "embeddingDimension": 512,
            "imageInputWidth": 384,
            "imageInputHeight": 384,
            "maximumTextTokens": 32,
            "parameterCount": 87_188_225,
        },
        "license": {
            "name": "Apache License 2.0",
            "spdxIdentifier": "Apache-2.0",
            "sourceURL": (
                "https://github.com/facebookresearch/perception_models/blob/"
                "3e352cca660658d4b5c90f42a7808b11469e4c66/LICENSE.PE"
            ),
            "notice": "Copyright Meta Platforms, Inc. Licensed under Apache License 2.0; see LICENSE.PE.",
        },
        "artifacts": artifacts,
    }
    manifest_path = pack_root / "manifest.json"
    with manifest_path.open("w", encoding="utf-8") as stream:
        json.dump(manifest, stream, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        stream.write("\n")
    os.chmod(manifest_path, 0o600)
    manifest_bytes, manifest_sha = file_digest(manifest_path)
    return {
        "path": str(pack_root),
        "manifest_path": str(manifest_path),
        "manifest_bytes": manifest_bytes,
        "manifest_sha256": manifest_sha,
        "artifact_count": len(artifacts),
        "artifact_bytes": sum(item["byteCount"] for item in artifacts),
    }


def write_report(path: Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.partial")
    with temporary.open("w", encoding="utf-8") as stream:
        json.dump(report, stream, indent=2, sort_keys=True, ensure_ascii=False)
        stream.write("\n")
    temporary.replace(path)


def main() -> int:
    args = parse_args()
    models = args.work_dir / "models"
    compiled = args.work_dir / "compiled"
    reports = args.work_dir / "reports"
    report_path = reports / "finalization-report.json"
    report: dict[str, Any] = {
        "schema_version": 1,
        "status": "running",
        "started_at_unix": time.time(),
        "quantization": {
            "method": "Core ML hybrid linear symmetric int8 weight-only",
            "granularity": "per-channel",
            "weight_threshold_elements": 2_048,
            "quantized_operator_types": ["conv", "linear"],
            "preserved_fp16_constants": [
                "token embedding",
                "position embedding",
                "2-D RoPE tables"
            ],
            "activations": "FP16",
        },
    }
    try:
        conversion.verify_sources(conversion.DEFAULT_MANIFEST, args.source_dir)
        fp16 = {
            "image": models / conversion.IMAGE_MODEL_NAME,
            "text": models / conversion.TEXT_MODEL_NAME,
        }
        for path in fp16.values():
            if not path.is_dir():
                raise FileNotFoundError(f"missing FP16 model package: {path}")
        w8 = {
            "image": models / "PECoreS16ImageW8.mlpackage",
            "text": models / "PECoreS16TextW8.mlpackage",
        }
        report["timings"] = {
            "quantize_image_seconds": quantize(fp16["image"], w8["image"], "image", args.overwrite),
            "quantize_text_seconds": quantize(fp16["text"], w8["text"], "text", args.overwrite),
        }
        compiled_paths: dict[str, dict[str, Path]] = {"fp16": {}, "w8": {}}
        for variant, paths in (("fp16", fp16), ("w8", w8)):
            for tower, package in paths.items():
                result, seconds = compile_package(package, compiled, args.overwrite)
                compiled_paths[variant][tower] = result
                report["timings"][f"compile_{variant}_{tower}_seconds"] = seconds

        image_refs, text_refs, tokens, fixtures = pytorch_references(args.source_dir, reports)
        report["tokenizer_fixtures"] = fixtures["fixture"]
        report["parity_against_pytorch_fp32"] = {}
        for variant in ("fp16", "w8"):
            report["parity_against_pytorch_fp32"][variant] = parity(
                compiled_paths[variant]["image"],
                compiled_paths[variant]["text"],
                image_refs,
                text_refs,
                tokens,
                fixtures["images"],
                args.compute_units,
            )

        fixture_path = Path(fixtures["fixture"]["path"])
        report["runtime"] = {}
        for variant, paths in (("fp16", fp16), ("w8", w8)):
            report["runtime"][variant] = {"package": {}, "compiled": {}}
            for tower in ("image", "text"):
                report["runtime"][variant]["package"][tower] = runtime_probe(
                    paths[tower],
                    tower,
                    fixture_path,
                    args.compute_units,
                    args.warmup,
                    args.iterations,
                )
                report["runtime"][variant]["compiled"][tower] = runtime_probe(
                    compiled_paths[variant][tower],
                    tower,
                    fixture_path,
                    args.compute_units,
                    args.warmup,
                    args.iterations,
                )

        report["artifacts"] = {}
        for variant, paths in (("fp16", fp16), ("w8", w8)):
            report["artifacts"][variant] = {
                "package": {
                    tower: conversion.package_manifest(path) for tower, path in paths.items()
                },
                "compiled": {
                    tower: conversion.package_manifest(path)
                    for tower, path in compiled_paths[variant].items()
                },
            }
        report["pack"] = build_pack(
            compiled_paths["w8"]["image"],
            compiled_paths["w8"]["text"],
            args.source_dir,
            args.work_dir / "pack" / PACK_IDENTIFIER / REVISION,
            args.overwrite,
        )
        report["status"] = (
            "passed"
            if all(
                item["summary"]["passed"]
                for item in report["parity_against_pytorch_fp32"].values()
            )
            else "parity_failed"
        )
        report["finished_at_unix"] = time.time()
        write_report(report_path, report)
        print(
            json.dumps(
                {
                    "status": report["status"],
                    "parity": {
                        key: value["summary"]
                        for key, value in report["parity_against_pytorch_fp32"].items()
                    },
                    "pack": report["pack"],
                    "report": str(report_path),
                },
                indent=2,
            )
        )
        return 0 if report["status"] == "passed" else 3
    except Exception as error:
        report["status"] = "failed"
        report["finished_at_unix"] = time.time()
        report["error"] = {
            "type": type(error).__name__,
            "message": str(error),
            "traceback": traceback.format_exc(),
        }
        write_report(report_path, report)
        print(f"finalization failed: {type(error).__name__}: {error}", file=sys.stderr)
        print(f"failure report: {report_path}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
