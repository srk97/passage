#!/usr/bin/env python3
"""Release-time verifier for Passage's pinned, bundled visual model pack."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath


EXPECTED_ARTIFACT_COUNT = 13
EXPECTED_ARTIFACT_BYTES = 118_182_009
REQUIRED_ROLES = {
    "image-encoder",
    "text-encoder",
    "tokenizer-merges",
    "tokenizer-vocabulary",
    "license",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(message: str) -> None:
    raise SystemExit(f"visual model pack verification failed: {message}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("pack", type=Path)
    parser.add_argument("--manifest-sha256", required=True)
    parser.add_argument("--identifier", required=True)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()

    root = args.pack.resolve(strict=True)
    if not root.is_dir() or args.pack.is_symlink():
        fail("pack root is not a real directory")
    manifest_path = root / "manifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink():
        fail("manifest is missing or symbolic")
    if sha256(manifest_path) != args.manifest_sha256:
        fail("manifest hash does not match the compiled pin")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("identifier") != args.identifier:
        fail("identifier mismatch")
    if manifest.get("revision") != args.revision:
        fail("revision mismatch")

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, list) or len(artifacts) != EXPECTED_ARTIFACT_COUNT:
        fail("unexpected artifact count")
    declared: set[str] = set()
    roles: set[str] = set()
    total_bytes = 0
    for artifact in artifacts:
        relative = artifact.get("relativePath")
        if not isinstance(relative, str):
            fail("artifact path is missing")
        pure = PurePosixPath(relative)
        if pure.is_absolute() or ".." in pure.parts or str(pure) != relative:
            fail(f"unsafe artifact path: {relative}")
        if relative in declared:
            fail(f"duplicate artifact path: {relative}")
        declared.add(relative)
        roles.add(str(artifact.get("role")))
        path = root / relative
        if path.is_symlink() or not path.is_file():
            fail(f"artifact is missing or symbolic: {relative}")
        expected_bytes = artifact.get("byteCount")
        if path.stat().st_size != expected_bytes:
            fail(f"artifact size mismatch: {relative}")
        if sha256(path) != artifact.get("sha256"):
            fail(f"artifact hash mismatch: {relative}")
        total_bytes += int(expected_bytes)

    if total_bytes != EXPECTED_ARTIFACT_BYTES:
        fail("unexpected declared byte total")
    if not REQUIRED_ROLES.issubset(roles):
        fail("required artifact roles are missing")

    actual: set[str] = set()
    for directory, names, files in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        for name in names:
            if (directory_path / name).is_symlink():
                fail(f"symbolic directory: {(directory_path / name).relative_to(root)}")
        for name in files:
            path = directory_path / name
            if path.is_symlink():
                fail(f"symbolic file: {path.relative_to(root)}")
            actual.add(path.relative_to(root).as_posix())
    if actual != declared | {"manifest.json"}:
        fail("pack contains undeclared or missing files")

    model = manifest.get("model", {})
    for key in ("imageEncoderPath", "textEncoderPath"):
        entry = root / str(model.get(key, ""))
        if entry.suffix != ".mlmodelc" or not entry.is_dir() or entry.is_symlink():
            fail(f"{key} is not a compiled Core ML directory")

    print(f"verified {args.identifier}@{args.revision}: {len(artifacts)} artifacts")


if __name__ == "__main__":
    main()
