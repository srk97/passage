#!/usr/bin/env python3
"""Fetch or verify the exact source assets used for PE Core ML conversion."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import urllib.request


SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[1]
DEFAULT_MANIFEST = SCRIPT_DIR / "model-manifest.json"
DEFAULT_SOURCE_DIR = REPO_ROOT / "work" / "pe_coreml" / "source"


def digest(path: Path) -> tuple[int, str]:
    sha = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            size += len(chunk)
            sha.update(chunk)
    return size, sha.hexdigest()


def load_manifest(path: Path) -> dict:
    with path.open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    if manifest.get("schema_version") != 1:
        raise ValueError(f"unsupported manifest schema: {manifest.get('schema_version')}")
    return manifest


def validate(path: Path, asset: dict) -> tuple[bool, str]:
    if not path.is_file():
        return False, "missing"
    actual_size, actual_sha = digest(path)
    if actual_size != asset["bytes"]:
        return False, f"size {actual_size}, expected {asset['bytes']}"
    if actual_sha != asset["sha256"]:
        return False, f"sha256 {actual_sha}, expected {asset['sha256']}"
    return True, actual_sha


def download(asset: dict, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    partial = destination.with_name(f".{destination.name}.partial")
    if partial.exists():
        partial.unlink()
    request = urllib.request.Request(
        asset["url"],
        headers={"User-Agent": "Passage-PE-CoreML-converter/1"},
    )
    print(f"fetching {asset['path']} ({asset['bytes']} bytes)", flush=True)
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            with partial.open("wb") as output:
                shutil.copyfileobj(response, output, length=1024 * 1024)
        ok, detail = validate(partial, asset)
        if not ok:
            raise RuntimeError(f"download verification failed for {asset['path']}: {detail}")
        os.chmod(partial, 0o600)
        partial.replace(destination)
    finally:
        if partial.exists():
            partial.unlink()


def verify_all(manifest: dict, source_dir: Path) -> bool:
    valid = True
    for asset in manifest["assets"]:
        path = source_dir / asset["path"]
        ok, detail = validate(path, asset)
        status = "ok" if ok else "ERROR"
        print(f"{status:5} {asset['path']}: {detail}")
        valid = valid and ok
    return valid


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("fetch", "verify"))
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--source-dir", type=Path, default=DEFAULT_SOURCE_DIR)
    args = parser.parse_args()

    manifest = load_manifest(args.manifest)
    if args.command == "fetch":
        args.source_dir.mkdir(parents=True, exist_ok=True)
        for asset in manifest["assets"]:
            destination = args.source_dir / asset["path"]
            ok, detail = validate(destination, asset)
            if ok:
                print(f"cached {asset['path']}: {detail}")
                continue
            if destination.exists():
                print(
                    f"refusing to overwrite invalid asset {destination}: {detail}",
                    file=sys.stderr,
                )
                return 2
            download(asset, destination)

    return 0 if verify_all(manifest, args.source_dir) else 1


if __name__ == "__main__":
    raise SystemExit(main())
