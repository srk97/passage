#!/usr/bin/env python3
"""Privacy-bounded framed-stdio bridge for Passage's compiled PE model pack."""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import resource
import struct
import sys
import time
from typing import Any, BinaryIO

os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_DATASETS_OFFLINE"] = "1"
os.environ["TOKENIZERS_PARALLELISM"] = "false"

import coremltools as ct
import numpy as np
from PIL import Image

from clip_tokenizer import SimpleTokenizer


MAXIMUM_JSON_BYTES = 8 * 1024 * 1024
MAXIMUM_IMAGE_BYTES = 128 * 1024 * 1024
MAXIMUM_PROMPTS = 256


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--device", choices=("auto", "cpu", "mps"), default="auto")
    return parser.parse_args()


def read_exact(stream: BinaryIO, count: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < count:
        chunk = stream.read(count - len(chunks))
        if not chunk:
            raise EOFError
        chunks.extend(chunk)
    return bytes(chunks)


def read_request(stream: BinaryIO) -> tuple[dict[str, Any], bytes]:
    size = struct.unpack(">I", read_exact(stream, 4))[0]
    if not 1 <= size <= MAXIMUM_JSON_BYTES:
        raise ValueError("invalid request frame")
    request = json.loads(read_exact(stream, size))
    payload_bytes = request.get("payloadBytes")
    if not isinstance(payload_bytes, int) or not 0 <= payload_bytes <= MAXIMUM_IMAGE_BYTES:
        raise ValueError("invalid payload length")
    return request, read_exact(stream, payload_bytes) if payload_bytes else b""


def write_response(stream: BinaryIO, response: dict[str, Any]) -> None:
    payload = json.dumps(response, sort_keys=True, separators=(",", ":")).encode("utf-8")
    if not 1 <= len(payload) <= MAXIMUM_JSON_BYTES:
        raise ValueError("invalid response frame")
    stream.write(struct.pack(">I", len(payload)))
    stream.write(payload)
    stream.flush()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_pack(reference: Path) -> Path:
    candidate = reference.expanduser().resolve()
    if (candidate / "manifest.json").is_file():
        return candidate
    manifests = list(candidate.rglob("manifest.json")) if candidate.is_dir() else []
    if len(manifests) != 1:
        raise ValueError("model reference must contain exactly one Passage pack")
    return manifests[0].parent


def safe_artifact(pack: Path, relative_path: str) -> Path:
    if not relative_path or relative_path.startswith("/"):
        raise ValueError("unsafe pack path")
    candidate = (pack / relative_path).resolve()
    if pack != candidate and pack not in candidate.parents:
        raise ValueError("unsafe pack path")
    if not candidate.is_file() or candidate.is_symlink():
        raise ValueError("missing pack artifact")
    return candidate


def validate_pack(pack: Path) -> tuple[dict[str, Any], dict[str, list[Path]], int]:
    manifest = json.loads((pack / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("formatVersion") != 1:
        raise ValueError("unsupported pack")
    roles: dict[str, list[Path]] = {}
    total = 0
    for artifact in manifest.get("artifacts", []):
        path = safe_artifact(pack, artifact["relativePath"])
        size = path.stat().st_size
        if size != artifact["byteCount"] or sha256(path) != artifact["sha256"]:
            raise ValueError("pack artifact mismatch")
        roles.setdefault(artifact["role"], []).append(path)
        total += size
    for entry in (manifest["model"]["imageEncoderPath"], manifest["model"]["textEncoderPath"]):
        path = (pack / entry).resolve()
        if pack not in path.parents or not path.is_dir() or path.suffix != ".mlmodelc":
            raise ValueError("invalid compiled model entry point")
    return manifest, roles, total


def compute_configuration(device: str) -> tuple[ct.ComputeUnit, str]:
    if device == "cpu":
        return ct.ComputeUnit.CPU_ONLY, "coreml-cpu"
    if device == "mps":
        return ct.ComputeUnit.CPU_AND_GPU, "coreml-cpu-gpu"
    # PE's W8 text tower had stable memory and best latency on the Neural
    # Engine path; ALL allowed a GPU plan with multi-gigabyte decompression.
    return ct.ComputeUnit.CPU_AND_NE, "coreml-cpu-neural-engine"


def peak_rss_bytes() -> int:
    value = int(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    return value if os.uname().sysname == "Darwin" else value * 1024


def output_embedding(prediction: dict[str, Any]) -> np.ndarray:
    value = np.asarray(prediction["embedding"], dtype=np.float32).reshape(-1)
    norm = float(np.linalg.norm(value))
    if value.size != 512 or not np.isfinite(value).all() or norm <= 0:
        raise ValueError("invalid embedding")
    return value / norm


class Encoder:
    def __init__(self, model_reference: Path, device: str) -> None:
        started = time.perf_counter()
        pack = resolve_pack(model_reference)
        manifest, roles, artifact_bytes = validate_pack(pack)
        units, device_name = compute_configuration(device)
        image_path = pack / manifest["model"]["imageEncoderPath"]
        text_path = pack / manifest["model"]["textEncoderPath"]
        self.image_model = ct.models.CompiledMLModel(str(image_path), compute_units=units)
        self.text_model = ct.models.CompiledMLModel(str(text_path), compute_units=units)
        vocabulary = roles.get("tokenizer-vocabulary", [])
        if len(vocabulary) != 1:
            raise ValueError("pack tokenizer is unavailable")
        self.tokenizer = SimpleTokenizer(vocabulary[0], context_length=32)
        self.prompt_embeddings: np.ndarray | None = None
        self.device_name = device_name
        self.load_milliseconds = (time.perf_counter() - started) * 1000.0
        self.artifact_bytes = artifact_bytes
        self.parameter_bytes = sum(
            path.stat().st_size
            for role in ("image-encoder", "text-encoder")
            for path in roles.get(role, [])
        )

    def configure(self, prompts: list[str]) -> float:
        if not 1 <= len(prompts) <= MAXIMUM_PROMPTS:
            raise ValueError("invalid prompts")
        if any(not isinstance(prompt, str) or not prompt.strip() for prompt in prompts):
            raise ValueError("invalid prompts")
        started = time.perf_counter()
        tokens = self.tokenizer(prompts)
        rows = []
        for index in range(tokens.shape[0]):
            rows.append(
                output_embedding(
                    self.text_model.predict({"tokens": tokens[index : index + 1]})
                )
            )
        self.prompt_embeddings = np.stack(rows)
        return (time.perf_counter() - started) * 1000.0

    def score(self, payload: bytes) -> tuple[list[float], float]:
        if self.prompt_embeddings is None:
            raise ValueError("prompts are not configured")
        started = time.perf_counter()
        with Image.open(io.BytesIO(payload)) as source:
            image = source.convert("RGB").resize((384, 384), Image.Resampling.BILINEAR)
        embedding = output_embedding(self.image_model.predict({"image": image}))
        similarities = np.clip(self.prompt_embeddings @ embedding, -1.0, 1.0)
        elapsed = (time.perf_counter() - started) * 1000.0
        return [float(value) for value in similarities], elapsed


def main() -> int:
    args = parse_args()
    input_stream = sys.stdin.buffer
    output_stream = sys.stdout.buffer
    try:
        if not args.cache_dir.is_dir():
            raise ValueError("cache directory unavailable")
        encoder = Encoder(args.model, args.device)
        write_response(
            output_stream,
            {
                "ok": True,
                "kind": "ready",
                "device": encoder.device_name,
                "modelLoadMilliseconds": encoder.load_milliseconds,
                "modelParameterBytes": encoder.parameter_bytes,
                "modelArtifactBytes": encoder.artifact_bytes,
                "peakResidentBytes": peak_rss_bytes(),
            },
        )
        while True:
            request, payload = read_request(input_stream)
            operation = request.get("operation")
            if operation == "shutdown":
                break
            if operation == "configure" and not payload:
                prompts = request.get("prompts")
                if not isinstance(prompts, list):
                    raise ValueError("invalid prompts")
                elapsed = encoder.configure(prompts)
                write_response(
                    output_stream,
                    {
                        "ok": True,
                        "kind": "configured",
                        "promptCount": len(prompts),
                        "embeddingDimensions": 512,
                        "encodingMilliseconds": elapsed,
                    },
                )
            elif operation == "score-image" and payload:
                similarities, elapsed = encoder.score(payload)
                write_response(
                    output_stream,
                    {
                        "ok": True,
                        "kind": "scores",
                        "similarities": similarities,
                        "encodingMilliseconds": elapsed,
                        "peakResidentBytes": peak_rss_bytes(),
                    },
                )
            else:
                raise ValueError("unsupported request")
        return 0
    except (EOFError, BrokenPipeError):
        return 0
    except Exception:
        # Protocol errors deliberately reveal no model, cache, or image paths.
        try:
            write_response(output_stream, {"ok": False, "kind": "error"})
        except Exception:
            pass
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
