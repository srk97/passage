# Performance evidence

Baseline measured July 28, 2026, on the current arm64 development Mac (Apple M4 Max, 16 CPU cores, 48 GB memory, macOS 26.0) using an optimized (`-c release`) build and the encrypted SQLCipher store.

## 100,000-frame search corpus

The deterministic fixture contains 100,000 index rows across 20 applications, 30 domains, 200 project titles, five recurring OCR/topic families, and six OCR regions per frame. It creates path references but no screenshot files. Each query asks for at most 50 joined source rows with snippets and metadata.

| Metric | Budget | Measured |
| --- | ---: | ---: |
| Strict warm search p50 | — | **13.81 ms** |
| Strict warm search p95 | < 50 ms | **33.35 ms** |
| Conversational rescue warm p50 | — | **21.04 ms** |
| Conversational rescue warm p95 | < 100 ms | **42.64 ms** |
| Zero-hit warm p50 | — | **0.07 ms** |
| Zero-hit warm p95 | — | **0.10 ms** |
| Cold search p50 | — | **16.29 ms** |
| Cold search p95 | < 180 ms | **36.05 ms** |
| Recall browse first page p50 / p95 | p95 < 50 ms | **0.24 / 0.31 ms** |
| Recall browse facets p50 / p95 | — | **66.40 / 71.78 ms** |
| Recall browse page then facets p50 / p95 | — | **66.66 / 72.07 ms** |
| Recall app + website p50 / p95 | p95 < 50 ms | **0.31 / 0.40 ms** |
| Recall text + metadata p50 / p95 | p95 < 100 ms | **35.47 / 45.70 ms** |
| Recall text + metadata facets p50 / p95 | — | **22.12 / 36.34 ms** |
| Recall text + metadata page then facets p50 / p95 | — | **57.05 / 81.91 ms** |
| Context bundle search + build p50 / p95 | p95 < 150 ms | **15.44 / 132.05 ms** |
| Context bundle encoded bytes p50 / p95 | ≤16,384 bytes | **5,751 / 5,811 bytes** |
| Recall cursor walk | No duplicates, gaps, or order reversals | **124 hits / 4 pages · passed** |
| Batch seed (100,000 frame + FTS + session rows) | — | **2,744.45 ms** |
| Encrypted database + WAL | — | **147,014,656 bytes** |

The stated 100,000-row latency and byte budgets passed in this measured run. Facets are deliberately asynchronous: the first result page publishes before those full-scope counts finish. The numbers are evidence from one development machine, not a guarantee for every Mac or every real-world corpus.

This run includes schema-v6 materialized activity sessions, stable Recall indexes, and integer row-ID alignment between FTS and frames. Against the preceding schema-v4 fixture, database + WAL is 147,014,656 bytes versus 137,271,104 bytes (**+7.1%**, about **97 bytes/frame**). The aligned text+app+website page remains below 50 ms p95 while browse and metadata-only first pages remain sub-millisecond. Normal warm p95 remains below 50 ms, while a worst-case rescue performs one fast zero-hit literal query plus one successful retained-word query and remains below 50 ms p95. These are observations from one fixture and machine, not a claim about every workload.

## One-million-row diagnostic

A release-mode acceptance run seeded one million current-schema aligned frame/FTS/session rows and recorded 25 warm samples plus 10 newly opened-connection samples. At this scale Passage probes a small newest-first candidate page through a covering domain+application+time index, intersects it with an aligned FTS row-ID range, and conditionally generates snippets only for the selected chronological results. It falls back to the exhaustive query whenever the bounded path cannot prove a complete page. This remains exact full-history retrieval, not a recent-history horizon or approximate result set.

The exact Recall text+metadata page measured **22.94 ms p50 / 75.05 ms p95**, passing the `<100 ms` first-result-at-one-million gate. Broad browsing remained **0.28 ms p95**; app+website filtering measured **0.20 ms p95**. Encrypted materialized browse totals hold unfiltered app/website facets at **0.06 ms p95**, and browse page-then-facets at **0.34 ms p95**.

The remaining broad work is still outside Passage's interaction budget. Legacy relevance `search()` measured **989.61 ms p50 / 1,653.71 ms p95**. Text+metadata facets measured **1,384.20 ms p95** and the complete text page-then-facets path **1,460.18 ms p95**. Context-bundle search/build measured **873.31 ms p95**, far above its `<150 ms` target. The exact cursor invariant passed across 124 hits / four pages, and the 16,384-byte context ceiling held at **9,231 bytes p95**.

Seeding took **51.37 seconds** and the encrypted database measured **1,617,850,752 bytes**. That cost includes the covering index and transactional facet totals; it is an explicit write/storage tradeoff, not a free win. A vault created before those totals existed performs one encrypted facet-total rebuild on its first writable open. The SQLCipher `MemorySegmentIndex` correctness slice provides: deterministic segments contain at most 64 exact ordered frames; rebuild is encrypted, exclusive, crash-safe, and validated before readiness; incomplete generations fail closed; text candidates require same-frame canonical FTS validation; agent-safe reads apply whole-session privacy before pagination; and cursors bind to scope/revision. It is dormant, has no automatic or incremental scheduler, has not replaced Recall, Ask, Memory Capsule, or agent context retrieval, and has not been run through this million-row benchmark.

Two tempting FTS shapes were rejected by measurement: a 512-value `rowid IN (...)` intersection produced **20,537.56 ms p95**, and 61 repeated row-ID equality probes produced **3,550.48 ms p95** in five-query diagnostics. Neither is used.

## One-million-vector visual-index diagnostic

A separate release-mode probe drives the production SQLCipher visual repository with one million unique 512-dimensional vectors, 2,048 angular candidates, and 20 returned exact-cosine results. Schema v9 replaces the per-row angular scan with fixed encrypted 2,048-vector hash blocks and a bounded one-model session cache. It does not create a plaintext sidecar or alter the angular shortlist, Int8 cosine reranking, per-result error bounds, deterministic ties, or final metadata predicates.

The current candidate-first representative plan measured **18.93 ms p50 / 21.46 ms p95** unscoped and **40.82 ms p50 / 42.05 ms p95** with exact time+application+domain scope. The join order starts from the already bounded visual candidates, which avoids rescanning the scoped frame slice for each representative chunk. First query on a newly opened connection measured **312.98 ms** unscoped and **287.69 ms** scoped because the encrypted hash snapshot had not been prewarmed. Cancellation-to-return was **0.63 ms**. The no-deduplication footprint delta was **1,475,052,248 bytes**, and encrypted writes sustained **12,847 vectors/second**. These are store-only synthetic stress results, not end-to-end hybrid-search or real-scene relevance evidence.

## OCR-region metadata encoding

Each fixture frame stores six normalized OCR boxes with confidence and text references. The current versioned binary format stores each region's UTF-8 offset and length into the canonical OCR text, rather than duplicating its text inside the region blob. Confidence and geometry use 16-bit normalized fixed-point fields.

| Region payload metric | Legacy JSON | Binary codec | Reduction |
| --- | ---: | ---: | ---: |
| Bytes per frame | 615.62 | **81.00** | **86.84%** |
| Bytes across 100,000 frames | 61,561,650 | **8,100,000** | **53,461,650 bytes** |

These figures compare the exact encoded region blobs generated by the benchmark, before SQLite page overhead. The canonical OCR text remains stored once for FTS and frame detail. The binary reader validates its version, text length, UTF-8 boundaries, offset bounds, normalized geometry, record count, and trailing data; rows written by earlier Passage versions remain readable through the legacy JSON decoder.

## Method

The benchmark:

1. Creates a temporary SQLCipher-backed store with a deterministic in-memory test key.
2. Inserts 100,000 frame documents in batches of 5,000. Each frame has six deterministic OCR regions. The seed timer covers binary region encoding, batch inserts, FTS indexing, frame-to-session assignment, and materialized session writes; initial connection creation and schema setup occur before the timer.
3. Primes five recurring two-word queries and five conversational wrappers once each.
4. Records 100 strict warm query samples on the writable store.
5. Records 10 “cold” samples, each as the first strict query through a newly opened read-only store.
6. Records 100 conversational-rescue samples. Each deliberately misses its literal scaffolded query, uses the conservative local interpreter, then runs one retained-word FTS query.
7. Records 100 guaranteed zero-hit warm samples.
8. Records broad, app+website, and text+metadata Recall first-page samples; separately measures full-scope facet aggregation and sequential page-then-facet latency; then walks a scoped cursor through every expected match while proving strict order and unique IDs.
9. Builds bounded agent context bundles from search results and records latency plus canonical encoded bytes under the exact 16,384-byte ceiling.
10. Sorts the samples, selects index `floor((count - 1) × percentile)`, and reports p50/p95 plus the main database and WAL byte count returned by store statistics.
11. Encodes the same region fixtures as both compact binary and legacy JSON, outside the seed timer, and reports total and per-frame payload bytes plus percentage reduction.

“Cold” is intentionally narrow here: the timed region starts **after** the read-only connection has opened, applied its key, and verified the SQLCipher schema. The operating-system file cache is not flushed, and the original writable store remains open. The 36.05 ms result is therefore first-query-on-a-new-connection latency, not application startup, Keychain access, SQLCipher open/key verification, or physical cold-disk latency. With only 10 cold samples, the benchmark's p95 formula selects the ninth ordered observation; this is directional evidence, not a robust tail estimate.

The fixture measures encrypted lexical/metadata retrieval, the exact strict-to-rescue orchestration used for recognized non-temporal recall wording, and the storage/seed cost of deterministic activity sessions. It does not measure temporal-filter rescue, media encryption/decryption, HEIC/JPEG decoding, screenshot rendering, live capture, Vision OCR, UI presentation, Keychain prompts, agent IPC, or provider-network latency.

The separate [local semantic retrieval evaluation](SEMANTIC-RETRIEVAL.md) measures the native-model availability, relevance failures, vector scan latency, and storage tradeoffs behind the decision not to ship hybrid ranking in 0.5.0.

## Test evidence

The Swift test suite passes **636 tests across 67 suites**. It covers the
first-run journey and permission invariants, capture lifecycle and failure
handling, encrypted storage and retention, Recall navigation and paging,
OCR recognition and repair, visual indexing and Memory Lens retrieval, the
agent service boundary, and session intelligence request shaping.

All provider tests use injected fake transports. No live provider request is
made, so the suite supplies no evidence about provider availability,
end-to-end latency, billing, model behavior, or network failure rates.

## First-run performance scope

The v2 onboarding demonstrates the result before capture is available: its recall examples, quiet-minute pipeline, and session handoff are deterministic local UI fixtures. Page interaction does not invoke ScreenCaptureKit, Vision OCR, corpus search, a provider request, Keychain vault access, or local-service startup, and Screen Recording/App Context prompts occur only from their explicit controls. Vault initialization begins only after onboarding completes. This design is not evidence that Keychain/SQLCipher startup is free or that the complete first-run path is faster than other local capture tools.

Onboarding progress is a small v2-scoped preference rather than a database migration. Remembering/paused intent is likewise read synchronously from application preferences, then reconciled once coordinator initialization finishes. This makes an early Start Remembering choice deterministic across the startup race, but no end-to-end timing for launch-to-interactive, permission return, Start Remembering-to-first-indexed-frame, step transition, or onboarding replay has been collected yet.

## Reproduce

```sh
mkdir -p work/swift-cache work/clang-cache
CLANG_MODULE_CACHE_PATH="$PWD/work/clang-cache" \
SWIFT_MODULECACHE_PATH="$PWD/work/swift-cache" \
swift run -c release passage-benchmark 100000
```

The tool prints the seeded frame count, seed time, strict warm p50/p95, conversational-rescue warm p50/p95, zero-hit warm p50/p95, cold p50/p95, database byte count, compact and legacy OCR-region payload totals, bytes per frame, and percentage savings. Temporary benchmark storage is removed when the run exits.

## Capture design relevant to performance

- One on-demand `SCScreenshotManager` request per due candidate; Passage never opens a live screen-sharing stream.
- Each request is sized to at most 1,920 pixels on its longest edge before Apple delivers the still image.
- Privacy and focused-context checks before pixels, followed by a second context check after delivery.
- A 64-bit difference hash before OCR, HEIC/JPEG encoding, or disk I/O.
- Snapshot backoff at 1×, 2×, 4×, and 8× the selected active interval after unchanged frames.
- A 30-second unchanged-screen heartbeat by default.
- Slower active sampling in Low Power Mode and under fair, serious, or critical thermal pressure.
- Pausing, user inactivity, Accessibility-reported secure focused fields when App Context access is granted, session lock/sleep, and excluded focused contexts prevent new screenshot requests.

There is no continuous callback converting unused video frames. Adaptive backoff reduces screenshot requests as well as downstream hashing, OCR, encryption, and persistence. An already in-flight still request may finish after a context transition; Passage rechecks the focused context and discards those pixels before hashing, OCR, or storage.

## Future measurements — not yet collected

- First-run launch-to-interactive, onboarding step-transition, Open Paused, permission-return, replay, and Start Remembering-to-first-indexed-frame latency.
- End-to-end app launch and first-result latency, including Keychain and SQLCipher open/verification.
- Search distributions across multiple Apple-silicon generations, corpus sizes, OCR lengths, and filter combinations.
- Sustained CPU, memory, energy, and thermal impact for static and rapidly changing displays.
- Capture callback time, Vision OCR throughput, HEIC/JPEG and AES-GCM cost, and dropped-candidate rate.
- Retention sweep and delete-all latency with real encrypted media.
- Local service/CLI round-trip latency and response-size stress results.

These measurements require a permissioned, signed application run and are release evidence to gather; they are not inferred from the architecture.
