# Visual region intelligence

Status: **manual rectangular Memory Lens ships; segmentation remains evaluation-only and must not enter the capture loop.**

Passage should treat segmentation as precise visual geometry, not as memory intelligence by itself. The product opportunity is a **Memory Lens**: select the exact chart, canvas object, preview, or irregular region inside a remembered screen; find it again; compare how it changed; or share only that bounded region with an explicitly chosen intelligence provider.

The first layer is query-time reranking: for eligible person-detail searches, native Vision proposes face/person rectangles and PE-Core reranks up to eight in-memory crops from the existing whole-image shortlist. The second layer is the manual path: a person drags over any retained screenshot detail and **Find this again** embeds that crop with PE-Core's image tower, searches the existing encrypted visual index, excludes the source, and preserves exact time/app/website filters. The crop and rectangle are query-lifetime memory only. Source fingerprint, lock, deletion, retention, scope, and query-generation guards prevent stale publication. Results describe appearance similarity and never object or person identity. Segmentation masks, change tracking, and third-party visual export remain future work.

## Product rule

The default path remains cheap and deterministic:

1. Accessibility geometry for native controls and hierarchy.
2. Vision OCR regions for text.
3. Perceptual change detection for capture cadence.
4. Segmentation only after a user action or a meaningful regional change that the cheaper sources cannot express.

Segmentation must stay invisible unless its geometry improves an action. Decorative masks are not a feature.

## Candidate runtime

[Meta EdgeTAM](https://github.com/facebookresearch/EdgeTAM) is the first native candidate because it has an Apache-2.0 Core ML export path and is far smaller than Apple’s published [SAM 2.1 Core ML models](https://huggingface.co/collections/apple/core-ml-segment-anything-2). Apple SAM 2.1 Tiny is the quality baseline. [EfficientTAM](https://github.com/yformer/EfficientTAM) is useful as a PyTorch/MPS research comparison, not the preferred shipping runtime.

Core ML is the relevant Apple runtime because it can schedule across CPU, GPU, and Neural Engine. Placement is not guaranteed, so Instruments and Core ML performance reports—not model marketing—decide viability on every supported Mac.

Do not persist model feature tensors. The manual crop, bounds, and query embedding are never persisted. If later change tracking requires durable geometry, persist only the selected frame ID, a compact bounding box, and a compact RLE or contour mask, encrypted with explicit lineage. A regional visual embedding should become durable only after the retrieval evaluation proves value.

## Memory Lens progression

- **Shipped:** drag a rectangular area in a remembered frame and find similar retained moments through a local image-to-image query.
- **Shipped:** exact source exclusion, app/site/time filtering, in-memory-only crop handling, source revalidation, and non-identity evidence copy.
- **Next:** click an object in a remembered frame to isolate it with a correction affordance.
- Prefer an Accessibility or OCR rectangle when it expresses the intended object.
- Fall back to EdgeTAM for irregular visual content.
- Re-prompt sparse later frames from the prior centroid/bounds, aided by Accessibility lineage and inexpensive image alignment.
- Extend the shipped “Find this again” with “What changed here?” over masked crops plus nearby text and temporal neighbors.
- Build third-party context from the smallest relevant crop; unrelated pixels remain local.
- Conservatively dilate or box sensitive regions before export. If containment is uncertain, fail closed.

## Go/no-go harness

Before integration, compare EdgeTAM, Apple SAM 2.1 Tiny, and the Accessibility/OCR rectangle baseline on 200–300 real screen memories across browsers, code tools, communication apps, media, charts, and canvases.

Ship only if all gates pass:

- At least 90% intended-object selection on first click and 95% after one correction.
- Median IoU at least 0.75 for irregular targets.
- No regression for ordinary Accessibility/OCR targets.
- At least 90% identity continuity across five sparse frames.
- 100% sensitive-region containment after conservative fallback.
- Warm p95 under 150 ms on the development M4 Max and under 300 ms on the oldest supported Mac.
- Cold availability under one second; no main-thread frame over 16 ms.
- Under 5% regression in capture latency and no dropped captures.
- Persisted region metadata averages only a few kilobytes per selected memory.
- Context bundles shrink visual/token payload by at least 70% without lowering answer quality.
- At least two workflows improve materially; otherwise park the model.

The M4 Max/48 GB development machine is ideal for exploration and unsuitable as the sole acceptance machine.
