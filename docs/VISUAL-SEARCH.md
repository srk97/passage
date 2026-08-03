# Local visual search

Status for Passage 0.9: **appearance search is integrated as a progressive, local-only Recall path using the verified PE-Core-S-16-384 Core ML pack. Person-detail queries add zero-storage Apple Vision face/person proposals plus bounded PE-Core crop reranking over the existing global shortlist. Both unscoped and exact app/site/time-scoped warm store retrieval pass the synthetic million-scene latency gate; cold start, end-to-end hybrid latency, energy, and broad real-world visual quality remain active constraints.**

Passage searches OCR text, application/window/URL context, exact filters, time, and a separately labeled image-appearance index. A title such as “Harry Potter” can still match immediately through text; measured `man` and `man with glasses` intents can use a smaller detected person/face area when whole-window pixels dilute the detail.

## Query-time person-detail refinement

The global PE-Core result page still publishes first. Only exact person/appearance tokens trigger the second phase, and only the first 12 already-retrieved candidates are eligible. Native Vision proposes faces and people from authenticated in-memory pixels; Passage compares no more than two regions per frame and eight regions total with the same local PE-Core model. The work stops under Low Power Mode or serious thermal pressure and has an absolute 850 ms deadline, hard-capped below one second. A timeout keeps the already-published global order.

No crop, box, caption, or region embedding is written to disk. Every candidate must carry the exact visual fingerprint that produced its whole-image match; Passage resolves it before pixels, rechecks the winner after inference, and final-validates the entire returned shortlist so retention or deletion cannot be undone by a late progressive publication. Lock synchronously revokes the read stores and region-work gate. Query-lifetime boxes remain UI-only: agent visual search and Memory Capsule still receive no pixels, bounds, crop scores, or source fingerprints.

The initial threshold check used the bundled W8 Core ML model, the production two-region budget, and five owner-authorized frames from the motivating video: one no-person hard negative, two visible-person/no-glasses hard negatives, and two visible-person-with-glasses positives. For `a man with glasses`, positive crop scores were 0.270/0.284 versus ≤0.213 for hard negatives; the shipped narrow gate is 0.260 plus a 0.010 gain. For `a man`, the two target scores were 0.249/0.251 versus ≤0.208 for those hard negatives; that exact intent uses 0.245 plus a 0.003 gain. The five-frame set is a threshold smoke test, not broad quality evidence: all other appearance wording retains the stricter 0.275/+0.020 fallback, and the larger gate below remains open. Exported calibration screenshots were deleted after the aggregate values were recorded.

## Lexical floor comparison

A read-only check against a title/OCR-only FTS5 baseline used the same session and excluded results created by the later discussion. The lexical baseline found the Harry Potter clip from its YouTube title and returned no result for `man AND glasses`. Passage should beat that floor with real pixel-derived retrieval, while labeling OCR/title matches and appearance matches as different evidence modalities.

## What the pixels already prove

Two local probes were run without exporting personal screenshots:

| Probe | Corpus | Result | Interpretation |
| --- | ---: | --- | --- |
| Apple Vision fixed-vocabulary classification | 20 frames selected by lexical `Harry Potter` evidence | `eyeglasses` at confidence ≥0.05 in 7/20 thumbnails and 8/20 full images; face rectangles in 15/20 | Useful cheap evidence exists, and 520-pixel thumbnails retain most of it. Fixed labels are too brittle and dominated by generic `document`/`screenshot` labels. |
| TinyCLIP image↔text ranking | 534/534 eligible encrypted thumbnails; 138 frozen lexical `Harry Potter` proxy positives | `a man wearing eyeglasses` ranked a proxy-positive frame first; image encode 10.55 ms p50 / 13.05 ms p95 on CPU | A dual encoder can retrieve from pixels at interactive speed, but this tiny model and coarse proxy are not a shippable relevance claim. |

TinyCLIP's movie-specific glasses query placed 14 proxy positives in the top 20, while the hard negative `a woman wearing eyeglasses` placed 19 proxy positives in the top 20. A landscape control also ranked a proxy positive first. Those failures show why “one plausible top result” is insufficient: the labels are coarse and the 94 MB model is not discriminative enough for Passage's quality floor. The Python research runtime also peaked near 438 MB resident memory; a native Core ML profile will be materially different and must be measured rather than inferred.

The evaluation bridge is intentionally narrow. Passage opens SQLCipher read-only, skips sensitive or missing media, decrypts each image only in memory, sends framed bytes to the offline encoder through stdin, and receives only normalized embeddings/scores. Reports exclude OCR, URLs, media/runtime paths, pixels, and key material. The full owner-only report is a work artifact, not a product export.

## Encrypted index scale evidence

The schema-v9 production-store probe seeded one million unique 512-dimensional vectors—the maximum-footprint case with no scene deduplication—and queried 2,048 angular candidates before exact Int8 cosine reranking. Fixed 2,048-vector angular-hash blocks remain inside SQLCipher and populate a one-model, ~64.25 MB session cache; no plaintext HNSW or other sidecar is created. The shortlist itself is unchanged from the previous full angular scan, so this optimization adds no new retrieval approximation.

The current candidate-first plan measured **18.93 ms p50 / 21.46 ms p95** unscoped and **40.82 ms p50 / 42.05 ms p95** with exact app/site/time scope. The scoped path had measured 219.91 ms p50 / 235.50 ms p95 before its representative lookup was pinned to the already bounded visual candidates; the change preserves exact scope, sensitivity, fingerprint-freshness, association-count, and newest-representative semantics. First query on a newly opened connection measured 312.98 ms unscoped and 287.69 ms scoped because the encrypted hash snapshot had not been prewarmed. Cancellation returned in 0.63 ms. The worst-case visual-index footprint remained 1.475 GB, and writes sustained 12,847 vectors/second. Full method and raw-report names are in `work/visual_index_scale/README.md`.

## Shipping model decision

The first Core ML conversion candidate is **Meta PE-Core-S-16-384**, with PE-Core-T-16-384 only as an energy/latency fallback.

- Both are Apache-2.0 and produce normalized 512-dimensional image/text embeddings with a 32-token text context.
- Meta's published S16 results are materially stronger than T16: COCO text→image 42.6 versus 33.0 and ImageNet-1k 72.7 versus 62.1.
- The S16 source checkpoint is about 349 MB. Expected package sizes of roughly 174 MB FP16 or 87 MB W8 are arithmetic estimates, not measured Core ML artifacts.
- The conversion risk is 2D rotary position embeddings plus attention pooling on Passage's macOS 14 floor. The spike must disable fused attention, freeze the 384×384 shape/rotary constants, lower attention to ordinary operations, and prove PyTorch↔Core ML cosine parity before integration.

Apple MobileCLIP remains a benchmark reference, not a product dependency: Apple's published model-weight license limits use to research/evaluation and excludes product/commercial development. TinyCLIP remains a small conversion control, not the default model.

## Product architecture

1. **Index scenes, not every heartbeat.** Enqueue only after a frame is durably persisted, outside the capture loop. Reuse the visual fingerprint and short temporal/app continuity to avoid embedding nearly identical frames.
2. **Keep the model explicit and local.** Passage bundles one immutable, hash-pinned 118 MB model pack, verifies it again at runtime, shows its exact coverage and Apache-2.0 license in Settings, and never performs a hidden runtime conversion, download, or model update check.
3. **Encrypt all derived meaning.** Store model ID/revision, preprocessing revision, dimensions, quantization, frame/scene ID, and vector bytes inside SQLCipher. Do not create a plaintext HNSW or caption sidecar. A 512-dimensional vector costs 1,024 bytes in FP16 or 512 bytes in int8 before row/index overhead; deduplicated scene storage is mandatory at scale.
4. **Retrieve pixels and words separately.** Encode the query once, generate local visual candidates, apply exact date/app/site filters, and combine with lexical candidates through a calibrated rank fusion. Exact Words bypasses visual retrieval. A zero-hit text query may offer or automatically use local appearance search only when coverage is sufficient.
5. **Explain the modality.** A result says `Visual match · understood locally` and uses a visual similarity reason, never a fabricated OCR snippet. OCR/title matches retain their current markers. Coverage states—download required, indexing, partial, complete—stay visible.
6. **Use heavier intelligence after discovery.** A small VLM such as Moondream can caption, answer a visual question, or ground an object for a few top candidates or an explicit selected memory. It should not caption every capture: generation is slower, can omit details such as glasses, repeats scenes, and creates hallucinated text that must remain separate from observed OCR.
7. **Use segmentation for geometry.** SAM 2 / EdgeTAM can outline a found object, build a privacy-minimized crop, track a region, or power Memory Lens. Segmentation does not discover “a man with glasses” by itself; it needs a point/box/text-grounded candidate first.
8. **Delete derived data with its source.** Retention, explicit deletion, image expiry, model replacement, and sensitive-state changes remove or invalidate the corresponding vector/caption/mask rows. No derived visual fact survives pixels by accident.

Passage will not infer a person's identity, race, health, emotion, or other sensitive trait. Generic appearance retrieval must not be presented as proof of gender or identity. A query such as “man” may retrieve person-like visual candidates, but the UI must describe the evidence as appearance similarity rather than an asserted demographic label.

## Broad visual-search acceptance gates

The frozen evaluation set must grow from the narrow threshold smoke test to at least 300 visually reviewed queries and hard negatives across media, people, objects, UI, charts, code, communication tools, and multilingual screens. Call the visual path broadly validated only when:

- Recall@10 improves by at least 25 points over OCR/title retrieval for visual-only queries.
- Hard-negative false positives stay below 5%, and no exact/metadata query category regresses.
- Every visual-only result discloses its modality and opens the exact source frame.
- Warm end-to-end query-to-first-page p95 is below 100 ms at one million indexed scenes—including exact scopes and hybrid publication; image indexing stays off-main and does not regress capture-to-index p95 by more than 5%. The store-only portions pass at 21.46 ms p95 unscoped and 42.05 ms p95 with exact app/site/time scope, but the broader end-to-end gate remains open.
- Added encrypted storage stays below 10% of retained media, resident visual-search memory below 150 MB, and an eight-hour energy run passes on the oldest supported Apple-silicon Mac.
- Model absence, partial coverage, corruption, lock, deletion, and migration all fail closed to today's lexical path.

## Primary sources

- [Meta Perception Encoder](https://github.com/facebookresearch/perception_models/blob/main/apps/pe/README.md) and [Apache-2.0 PE license](https://github.com/facebookresearch/perception_models/blob/main/LICENSE.PE)
- [Apple MobileCLIP model-weight license](https://github.com/apple/ml-mobileclip/blob/main/LICENSE_MODELS)
- [TinyCLIP reference implementation](https://github.com/wkcn/TinyCLIP)
- [Moondream 2 model card](https://huggingface.co/vikhyatk/moondream2)
- [Meta SAM 2](https://github.com/facebookresearch/sam2) and [EdgeTAM](https://github.com/facebookresearch/EdgeTAM)
- [Apple Vision image classification](https://developer.apple.com/documentation/vision/vnclassifyimagerequest)
