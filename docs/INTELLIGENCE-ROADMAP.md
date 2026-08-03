# Intelligence roadmap

Passage uses language models where they add synthesis, not where deterministic local systems are faster or more trustworthy. Capture, OCR, deduplication, default search, calendar interpretation, privacy policy, and evidence selection remain local. Provider work is explicit, bounded, source-cited, and never placed in the fast capture/search path.

## Shipped boundary

Session enhancement and “Ask this session” run only after an explicit action on one selected session. They send at most 20 text-only moments and 20,000 UTF-8 bytes, declare no tools, use `store: false`, validate citations against supplied frame IDs, and encrypt valid cached output locally. Screenshots, media paths, geometry, vault material, and other sessions cannot enter either request type.

## Shipped in 0.5.0: Ask this session

The model-powered question path answers one explicit question about one selected activity session; it is not corpus-wide “chat with memory.” Example jobs include “Which command finally worked?”, “What decision did I make?”, and “Where exactly did I leave this?”

The implemented contract:

- Typing and local evidence preparation cause zero network calls. Only Ask is an egress boundary.
- The question is capped at 1,000 UTF-8 bytes; question plus sources fit inside the same 20,000-byte request budget and 20-moment limit.
- A local selector extracts at most six sanitized literal terms, searches only the selected session, fail-closed filters session membership again, and combines relevant hits with bounded recent context.
- The provider returns either one to four short individually cited claims or `insufficient_evidence`. Uncited, oversized, empty, or out-of-session claims reject the whole answer.
- Every question about a locally private session requires a fresh confirmation naming the moment count and byte count.
- Network, rate-limit, refusal, malformed-output, and cache-authentication failures remain inline, sanitized, and never trigger a broader-data fallback or automatic paid retry.
- Session changes, lock, key removal, or history deletion cancel the task and suppress late output.
- The encrypted cache identity includes feature/schema version, normalized question, selected-session ID, exact bounded sources, provider, and model.

The UI belongs below the existing session brief: one prompt, one Ask action, a persistent “text only; screenshots stay local” disclosure, and claim-by-claim source pills that open exact memories.

## Explicit non-goals until retrieval clears its gate

- Automatic daily or background summaries.
- LLM query expansion in default search.
- An uncited answer over the entire vault.
- Sending screenshots by default.
- Letting OCR or provider output invoke tools.

Corpus-wide questions can be revisited only after the frozen relevance suite, hard-negative gate, deduplicated session/chunk index, and privacy/performance budgets in [SEMANTIC-RETRIEVAL.md](SEMANTIC-RETRIEVAL.md) pass.
