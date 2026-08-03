# PE-Core-S-16-384 Core ML conversion

This pipeline converts Meta's PE-Core-S-16-384 dual encoder into separate,
fixed-shape Core ML image and text towers for macOS 14. Generated weights,
compiled models and reports stay under `work/pe_coreml/`. The finalized,
verified release pack is promoted to `Support/VisualModelPacks/` and sealed in
the signed app by `scripts/package-app.sh`; conversion never mutates the bundle
directly.

## Reproduce

The Python toolchain is locked for CPython 3.11 in `uv.lock`. Dependency setup
and the explicit asset-fetch step require network access. Conversion,
quantization, compilation, parity checks, the bridge, and inference are forced
offline.

```sh
scripts/visual-model/run.sh bootstrap
scripts/visual-model/run.sh fetch
scripts/visual-model/run.sh verify
scripts/visual-model/run.sh convert --overwrite --warmup 3 --iterations 10
scripts/visual-model/run.sh finalize --overwrite --compute-units CPU_AND_NE \
  --warmup 5 --iterations 30
```

`convert` writes FP16 `.mlpackage` towers and PyTorch-to-Core-ML parity data.
`finalize` creates the W8 variants, invokes Apple's `coremlcompiler`, measures
packages and compiled models in isolated processes, and assembles the work-only
Passage pack. Core ML prediction and compilation must run with access to
macOS's native temporary and Core ML service directories.

## Pinned inputs

Model: `timm/PE-Core-S-16-384` at immutable Hugging Face revision
`3249a38eb1c432ec19231c6fe1774acb6a4e4efe`.

| Asset | Bytes | SHA-256 |
| --- | ---: | --- |
| `open_clip_model.safetensors` | 348,787,644 | `440da04ea6f08f5ce07b2e7118735660c7a71f981bdf3edde8e8b15f28d660b0` |
| `open_clip_config.json` | 598 | `2e53cd74e5cf6201f4355bf8bff6f486afa2c9cf9c8f0382e190f3ee1a80174b` |
| `bpe_simple_vocab_16e6.txt.gz` | 1,356,917 | `924691ac288e54409236115652ad4aa250f48203de50a9e4722a6ecd48d6804a` |
| `LICENSE.PE` | 11,357 | `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4` |

The vocabulary and license come from Meta's `perception_models` revision
`3e352cca660658d4b5c90f42a7808b11469e4c66`. `model-manifest.json` is the
machine-readable authority for URLs, sizes, and hashes. `fetch_assets.py`
downloads to a partial file and atomically installs it only after both size and
SHA-256 match.

The model is Apache-2.0 licensed; the pack carries the pinned `LICENSE.PE` file
and license metadata. Consult the license rather than this document for legal
terms.

## Runtime contract

- Image input: one RGB image, resized by the caller to 384×384 with bilinear
  squash, then transformed in-model with `pixel / 127.5 - 1`.
- Text input: one `[1, 32]` Int32 token tensor using the OpenAI CLIP byte-BPE
  vocabulary, SOT 49406, EOT 49407, and zero padding.
- Image and text outputs: normalized `[1, 512]` embeddings.
- Deployment target: macOS 14 ML Program, FP16 compute.
- Fused PyTorch attention is disabled before tracing, so Core ML receives
  explicit matrix/softmax operations. The 384×384 trace fixes PE's 2-D rotary
  geometry.

`work/pe_coreml/reports/tokenizer-fixtures.json` contains all 32 Int32 tokens
for nine authoritative cases: the product queries, HTML entities,
contractions, dense punctuation, mixed Unicode/emoji, and long-text
truncation. Its observed SHA-256 is
`b72df7621eabd55df05b5df28fa7cc059763db009a4ccc10e8e03c67ff1efbf8`.
The NumPy-only bridge tokenizer matches all nine vectors exactly.

## W8 policy

A global Core ML int8 pass also quantizes PE's RoPE tables, position embedding,
and text token lookup table. That version reduced the pack to 89.5 MB but
failed the image parity gate at 0.98741 minimum cosine. The retained policy is
hybrid weight-only W8:

- per-channel, linear-symmetric int8 for `conv` and `linear` weights with at
  least 2,048 elements;
- FP16 activations;
- FP16 token embedding, position embedding, and 2-D RoPE constants.

This keeps the sensitive lookup constants intact and still fits the model pack
inside the 150 MB target.

## Measured result

Observed on Apple M4 Max, macOS 26.0 (25A354), Core ML Tools 9.0, PyTorch
2.7.0, with CPU plus Neural Engine. Parity compares compiled Core ML output to
the normalized PyTorch FP32 output over four deterministic image fixtures and
nine tokenizer fixtures.

| Variant | Image bytes (compiled) | Text bytes (compiled) | Min image cosine | Min text cosine |
| --- | ---: | ---: | ---: | ---: |
| FP16 | 47,690,574 | 127,027,627 | 0.999848 | 0.999966 |
| Hybrid W8 | 24,462,738 | 89,156,013 | 0.999081 | 0.999508 |

The final native-compatible pack is 118,182,009 declared artifact bytes. It
includes both Meta's pinned tokenizer gzip and the uncompressed merge table
required by `CLIPBPETokenizer`, plus the license. Its 3,214-byte raw manifest
SHA-256 is
`e8ab953b8ec53eeae643c96f35b164424f3a92977aa00b244ca74f41acee96ea`.
Every file beneath each `.mlmodelc` directory is individually size- and
SHA-256-pinned in `manifest.json`; the 13 artifacts match
`VisualModelPackManifest` format 1.

Fresh-process results after the system's one-time device specialization cache
was warm:

| Compiled tower | Load | First prediction | p50 | p95 | RSS delta after predictions |
| --- | ---: | ---: | ---: | ---: | ---: |
| FP16 image | 54.0 ms | 16.4 ms | 10.27 ms | 10.59 ms | 18.7 MB |
| FP16 text | 50.5 ms | 4.5 ms | 0.90 ms | 1.00 ms | 12.2 MB |
| W8 image | 53.6 ms | 15.1 ms | 10.08 ms | 10.16 ms | 17.6 MB |
| W8 text | 47.8 ms | 4.2 ms | 0.80 ms | 1.14 ms | 12.6 MB |

Loading source `.mlpackage` files took 2.0–3.1 seconds; compiled models remove
that cost. The first bridge launch from a never-before-used installed pack path
took 4.82 seconds because Core ML still specialized the compiled graph for the
device. A new process after that loaded and verified the same pack in 166 ms.
Production should run this one-time specialization during the explicit model
installation flow, with progress, rather than on the first search.

RSS deltas above are more meaningful than the absolute Python process RSS:
importing the research Core ML/Python stack itself used about 318 MB. A native
Swift runtime should be measured independently before a shipping memory claim.

## Passage bridge and corpus probe

`coreml_bridge.py` implements Passage's four-byte big-endian framed-stdio
protocol. It accepts `configure`, `score-image`, and `shutdown`, validates all
pack hashes before loading, keeps image bytes in memory, and returns only
similarities and aggregate timing/RSS fields. `--model` accepts either the
exact pack directory or a root containing exactly one pack. Automatic mode is
mapped to CPU plus Neural Engine because Core ML `ALL` selected a GPU plan that
caused multi-gigabyte W8 text decompression in this research runtime.

The privacy-safe benchmark scored all 750 selected non-sensitive thumbnails:

- model load: 169.1 ms after one-time specialization;
- seven prompt embeddings: 9.14 ms total;
- image encoding: 11.21 ms p50, 11.63 ms p95, 37.14 ms maximum;
- bridge round trip: 11.39 ms p50 and 11.83 ms p95;
- 8.48 seconds total child image-encoding time for 750 frames;
- 390.5 MB peak Python bridge RSS;
- zero sensitive, missing, corrupt, or decoder-incompatible frames skipped in
  this selection.

The lexical `Harry Potter` proxy selected 138 of those frames. The prompt “a
movie scene featuring a man wearing eyeglasses” put a proxy-positive frame at
rank 1 and 16 positives in the top 20 (80% precision@20, 11.6% recall@20).
“A man wearing eyeglasses” also ranked a proxy-positive first and placed 10 in
the top 20. These are encouraging ranking signals, not ground-truth accuracy:
lexical matches do not prove that a man or eyeglasses are visible, and a dual
encoder does not localize which person owns an attribute.

Authoritative machine-readable reports:

- `work/pe_coreml/reports/conversion-report.json`
- `work/pe_coreml/reports/finalization-report.json`
- `work/pe_coreml/reports/tokenizer-fixtures.json`
- `work/pe_coreml/reports/visual-benchmark.json`
- `work/pe_coreml/reports/native-probe-report.json`

## Native Passage validation

The one-off package under `work/pe_coreml/native-probe/` imports Passage's
actual `VisualModelPackStore`, `CLIPBPETokenizer`, and
`CoreMLVisualEmbeddingModel`. It installs the pinned pack into an owner-only,
workspace-local temporary root, exercises native text/image inference, and
removes the temporary decrypted-free install/cache after the run.

The product build and native pack installation both succeed. On the same M4
Max, installing and hashing 13 artifacts took 213.1 ms. Native compiled-cache
preparation took 8.28 ms on first use and 0.52 ms on the second load. Core ML's
first device-specializing load took 6.22 seconds; a second model load from that
same persistent cache took 75.65 ms. This confirms that the installation flow
must prewarm the model before search is first used.

For three representative, non-sensitive Passage thumbnails kept only in
memory, native image inference had a 15.10 ms p50. Across seven prompts and 21
score comparisons against the Python/Core ML bridge, mean absolute score error
was 0.00180 and maximum error was 0.00591. The remaining difference is the
Pillow-versus-Core Image resize/color path, not different model weights.

Native tokenizer parity is **9/9** after Passage's cleaner added OpenCLIP-
compatible smart single/double quote folding. This includes HTML entities,
contractions, punctuation and curly quotes, mixed Unicode/emoji, and long
truncation. Native tokenizer p50 was 0.19 ms; complete normalized text embedding
p50 was 1.30 ms and p95 was 3.42 ms across the nine fixtures.
