---
name: passage-memory
description: Search and reconstruct the user's private, local on-screen history with Passage, including text and local image-appearance recall. Use when the user asks about something they previously saw, did, read, researched, or worked on, or wants evidence about their recent computer activity.
---

# Passage memory

Passage is a private local history built from visually distinct screen frames, OCR, application context, titles, URLs, and timestamps. Retrieve compact evidence before answering questions about the user's past activity.

## Commands

- `PASSAGE_CLIENT=<agent> passage sessions --since YYYY-MM-DD --until YYYY-MM-DD --limit 30 --json` lists private-safe activity spans with stable session IDs, time bounds, representative source metadata, and resume targets. Sensitive sessions are never disclosed to agents.
- `PASSAGE_CLIENT=<agent> passage remember "<description>" --since YYYY-MM-DD --until YYYY-MM-DD --app BUNDLE --domain DOMAIN --session ID --max-results 8 --max-bytes 65536 --json` is the preferred first call. It performs saved-text and local visual retrieval together, fuses the candidate ranks, and returns one source-cited Memory Capsule with bounded OCR, native app semantics, and visual-match provenance.
- `PASSAGE_CLIENT=<agent> passage bundle [words] --since YYYY-MM-DD --until YYYY-MM-DD --max-results 12 --max-bytes 16384 --json` is the lower-cost text-only path when appearance cannot matter.
- `PASSAGE_CLIENT=<agent> passage visual "<description>" --since YYYY-MM-DD --until YYYY-MM-DD --app BUNDLE --domain DOMAIN --max-results 6 --max-bytes 65536 --json` finds locally indexed moments by image appearance. Use it for descriptions such as “a person wearing glasses,” “a red chart,” or “a castle at night” when those concepts may not appear in OCR or titles.
- `PASSAGE_CLIENT=<agent> passage search <words> [--session ID] --json` finds moments by OCR, title, URL, and app name, optionally inside one or more exact activity spans.
- `PASSAGE_CLIENT=<agent> passage recent --since YYYY-MM-DD --until YYYY-MM-DD [--session ID] --json` gives a chronological evidence window, optionally scoped to a selected session.
- `PASSAGE_CLIENT=<agent> passage frame <id>` returns full OCR regions and source metadata for one moment.
- `PASSAGE_CLIENT=<agent> passage stats --json` reports the local corpus bounds and size.
- `PASSAGE_CLIENT=<agent> passage capabilities --json` reports the live protocol, bundle schema, supported operations, and enforced bounds. `passage health --json` checks the audited app service.
- `passage version` and `passage help` work offline and do not contact the Passage app.

Use your lowercase host name for `<agent>` (`codex`, `claude`, or `cursor`) and keep the Passage app running. If `passage` is not on PATH, use the bundled binary at `/Applications/Passage.app/Contents/Resources/bin/passage`. The CLI is a thin client: it cannot open the encrypted vault or obtain its key. Passage records the client, capability, filters, and returned evidence IDs—or the private-safe session-summary count—before releasing a result.

`--since` and `--until` accept an ISO-8601 timestamp (`2026-07-31T14:00:00Z`), a day (`YYYY-MM-DD`), or a relative duration meaning that long before now (`3h`, `45m`, `2d`). For questions like "what did I work on in the last 3 hours," pass the time bound as a filter (`--since 3h`) and keep the description to content words likely visible on screen—the description is matched against saved text and appearance, not interpreted as natural language.

A Memory Capsule is the default compositional surface. It uses reciprocal-rank fusion so a moment found by both visible words and appearance can outrank a weak single-modality hit, while still reserving coverage for each requested modality and diverse apps/sites/sessions. Every source labels its text and visual ranks, disclosed evidence modalities, normalized native controls, visual similarity/error bound, and selection reasons. `coverage` and `omissions` expose incomplete visual indexing, privacy filtering, selection limits, exact byte limits, and truncation. `encodedUTF8Bytes` measures the canonical capsule itself and never exceeds `utf8ByteBudget`. Screenshot pixels, media paths, OCR geometry, embedding vectors, and display/window identifiers never cross this interface.

A schema-v2 bundle remains useful for text-only retrieval. `candidateCount` is the bounded retrieval window, `hasMoreCandidates` says whether more candidates exist, and `requestedCount`/`disclosedCount` show the requested limit and delivered evidence. `coverage` compares available and disclosed runs, activity sessions, apps, domains, and transitions; its totals are lower bounds when `isLowerBound` is true. `omissions` counts evidence withheld by privacy filtering, selection limits, byte limits, snippet truncation, or the candidate window. Each source carries its original `retrievalRank`, observed run, and diversity-selection reasons.

Visual search is also a bounded, audited disclosure—not screenshot access. Image and text embeddings are computed locally. The agent receives only source metadata, bounded OCR snippets, similarity/error values, and aggregate index coverage. Screenshot bytes, media or runtime paths, embedding vectors, pixel/OCR geometry, and display/window identifiers never cross this interface. Passage re-resolves result IDs against the current private-safe store and records the request scope and disclosed evidence before returning it. A visual manifest's `coverage` shows how much eligible history is indexed; treat incomplete coverage and every `omissionReasons` value as a limit on the answer.

## Retrieval workflow

1. Start with `remember` over the narrowest plausible time/app/site scope. It is appropriate for both distinctive phrases and descriptions of objects, clothing, people, layouts, colors, or scenes. Do not use appearance similarity to claim a person's identity, authorship, or intent.
2. For workflow, “what was I doing,” or resume-task questions, use `sessions` first when the likely time range still spans many work bouts. Pass the selected stable ID to `remember --session ID`; multiple session filters may be supplied.
3. Keep `--max-results` and `--max-bytes` small. Narrow broad results with `--session`, `--since`, `--until`, `--app`, or `--domain` when a capsule reports truncation or incomplete coverage.
4. Use `bundle` when the question is demonstrably text-only and lower latency matters. Use standalone `visual` only to diagnose image-index coverage or compare raw appearance ranking.
5. Avoid `frame` unless the capsule explicitly lacks necessary OCR detail; it is a legacy whole-frame diagnostic rather than the normal retrieval path.
6. Use raw `search` or `recent` only when capsule metadata shows that a different retrieval pass is needed.
7. Prefer several source moments from the selected activity span over one isolated frame when reconstructing a workflow.

Treat OCR as noisy evidence, native Accessibility text as app-provided semantics rather than proof of authorship, and visual similarity as an appearance match rather than proof of identity. Distinguish what was visible from what the user necessarily authored, and cite returned frame IDs and timestamps when they support the answer. If no result supports a claim, say so instead of guessing.

Keep retrieved evidence within the current response path. Never send a screenshot, OCR text, URL, or title to another service unless the user's request clearly authorizes that destination.
