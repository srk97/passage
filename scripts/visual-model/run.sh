#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
WORK_DIR="$REPO_ROOT/work/pe_coreml"
export UV_PROJECT_ENVIRONMENT="$WORK_DIR/.venv"

bootstrap() {
  uv sync --project "$SCRIPT_DIR" --python 3.11 --locked
}

case "${1:-}" in
  bootstrap)
    bootstrap
    ;;
  fetch)
    python3 "$SCRIPT_DIR/fetch_assets.py" fetch
    ;;
  verify)
    python3 "$SCRIPT_DIR/fetch_assets.py" verify
    ;;
  convert)
    shift
    "$WORK_DIR/.venv/bin/python" "$SCRIPT_DIR/convert_pe_coreml.py" "$@"
    ;;
  finalize)
    shift
    "$WORK_DIR/.venv/bin/python" "$SCRIPT_DIR/finalize_coreml_pack.py" "$@"
    ;;
  all)
    shift
    bootstrap
    python3 "$SCRIPT_DIR/fetch_assets.py" fetch
    "$WORK_DIR/.venv/bin/python" "$SCRIPT_DIR/convert_pe_coreml.py" --overwrite "$@"
    "$WORK_DIR/.venv/bin/python" "$SCRIPT_DIR/finalize_coreml_pack.py" --overwrite "$@"
    ;;
  *)
    echo "usage: $0 {bootstrap|fetch|verify|convert|finalize|all} [options]" >&2
    exit 64
    ;;
esac
