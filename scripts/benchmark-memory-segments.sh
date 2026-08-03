#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"

profile="million"
frame_count=1000000
sample_count=50
run_count=3
batch_size=5000
page_limit=50
capture_probe_count=50
output_root="$project_dir/work/memory-segment-benchmark"
correctness_only=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --smoke)
            profile="smoke"
            frame_count=20000
            sample_count=5
            run_count=1
            shift
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || { echo "--output-dir requires a path" >&2; exit 2; }
            output_root="$2"
            shift 2
            ;;
        --correctness-only)
            correctness_only=1
            shift
            ;;
        --help|-h)
            echo "Usage: scripts/benchmark-memory-segments.sh [--smoke] [--output-dir PATH] [--correctness-only]"
            echo
            echo "Default: frozen three-run one-million-frame acceptance protocol."
            echo "Smoke: frozen one-run 20,000-frame protocol validation; no scale claim."
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

run_stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
run_dir="$output_root/$run_stamp-$$"
mkdir -p "$run_dir"

cd "$project_dir"
swift build -c release --product passage-segment-benchmark

reports=()
for ((run = 1; run <= run_count; run++)); do
    report="$run_dir/memory-segments-${profile}-${frame_count}-${run_stamp}-run-${run}.json"
    .build/release/passage-segment-benchmark \
        --profile "$profile" \
        --run "$run" \
        --frames "$frame_count" \
        --samples "$sample_count" \
        --batch-size "$batch_size" \
        --page-limit "$page_limit" \
        --capture-probe-count "$capture_probe_count" \
        --output "$report" \
        > /dev/null
    reports+=("$report")
done

checker=(python3 "$script_dir/check-memory-segment-benchmark.py")
if [[ "$correctness_only" -eq 1 ]]; then
    checker+=(--correctness-only)
fi
summary="$run_dir/memory-segments-${profile}-${frame_count}-${run_stamp}-gate.json"
"${checker[@]}" "${reports[@]}" | tee "$summary"
echo "Benchmark reports: $run_dir"
