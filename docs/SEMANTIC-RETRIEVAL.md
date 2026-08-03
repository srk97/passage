# Local semantic retrieval decision

Decision for Passage 0.5.0: **defer text-semantic and hybrid corpus ranking**. Ship encrypted FTS5, exact metadata filters, a transparent deterministic conversational rescue, session browsing, session-scoped retrieval, and locally selected evidence for explicit one-session questions. Pixel-derived appearance retrieval is a different modality with its own current evaluation and acceptance gates in [Local visual search](VISUAL-SEARCH.md).

The local experiment showed that compute is fast enough, but the reliably available native model is not accurate or portable enough. A confidently wrong memory is worse than an honest lexical miss.

## What Passage ships now

- Per-frame FTS5 over OCR text, title, application, and URL.
- Porter stemming, Unicode tokenization, quoted-prefix ordinary queries, and explicit advanced FTS syntax.
- Exact application, domain, time, and activity-session filters.
- A conservative local recall interpreter for anchored phrases such as “where I left” and high-confidence calendar suffixes. Rescue retains AND semantics for every content term, is visibly disclosed, and can be bypassed with Exact words.
- Deterministic five-minute-gap activity sessions for bounded browsing and retrieval.
- Optional, explicitly invoked session intelligence after retrieval; it does not rank the local corpus.

## Evaluation

The fixture contained ten distinct work topics and queries covering exact phrases, morphology, conceptual synonyms, conversational “resume” wording, application/domain terms, names, polysemy, and hard negatives.

On the clean nine-query fixture:

| Retriever | Top-1 |
| --- | ---: |
| Current lexical path | 4/9 |
| Native English 300-dimensional word-vector average | 8/9 |

The semantic score looked promising until hard negatives were added. It then fell to **5/10 top-1**:

- `handoff` ranked a football document above the project handoff.
- `bug` ranked insects above login debugging.
- `resume checkout redesign` ranked grocery checkout above product design (`0.701` vs `0.679`).
- `choose a desk to purchase` tied an unrelated checkout-design document with the desk document, returning the wrong one first.
- An application-name query failed when the name was outside the embedding vocabulary.

There was no safe similarity threshold: some wrong candidates scored above the intended memories. A reranker cannot solve the current lexical path's missing candidates, so semantic candidate generation would make these false positives user-visible.

## Native model availability

Measured on the current Apple M4 Max/macOS 26 development Mac:

| Native model | Result |
| --- | --- |
| English word embedding | Available; 300 dimensions, revision 1 |
| Tested non-English word embeddings | Unavailable |
| Tested sentence embeddings | Unavailable |
| English/Spanish and Japanese contextual models | Descriptors present; assets unavailable |

The contextual path would require an OS-managed asset download and an unvalidated token-pooling strategy. It is not a guaranteed offline sentence-similarity substrate.

## Performance and storage

Performance was not the blocker:

- Word-vector document encoding: about 283 microseconds/document.
- Best-case resident exact scan p95: 0.99 ms for 100,000 vectors and 7.79 ms for one million.
- Raw 300-dimensional frame vectors: about 120 MB per 100,000 frames and 1.2 GB per million frames.

Those scan measurements exclude encrypted loading, cold paging, cache construction, and model inference. Frame-level vectors are also the wrong storage granularity; a future design should embed deduplicated encrypted session chunks.

## Acceptance gate for a future hybrid retriever

A semantic layer may ship only when it meets all of these gates:

1. **Offline availability:** a guaranteed local sentence model for every advertised language, with deterministic lexical fallback and no implicit download or network inference.
2. **Correct substrate:** deterministic, deduplicated session/chunk documents; model kind, language, revision, and dimensions stored with encrypted vectors; deletion, expiry, and migration cover the vector index.
3. **Frozen relevance suite:** at least 200 labeled queries including exact terms, morphology, synonyms, conversational phrasing, multilingual text, names, polysemy, and hard negatives.
4. **Quality:** conceptual/resume Recall@5 improves by at least 20 points; exact/metadata queries do not regress; hard-negative false positives remain below 5%; no category loses more than two MRR/nDCG points.
5. **Calibrated behavior:** semantic-only matches disclose why they matched, while ambiguous queries fall back to lexical results or session browsing instead of presenting a confident guess.
6. **Performance and privacy:** interactive p95 remains inside the existing budget on older Apple silicon; added encrypted-index storage stays below 25%; resident semantic cache stays below 100 MB at one million frames; no plaintext sidecar or undeleted embeddings.

Until then, Passage's trustworthy bridge is deterministic session browsing plus precise retrieval inside a selected activity span.
