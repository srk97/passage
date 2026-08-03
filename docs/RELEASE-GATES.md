# Release gates

These gates were originally derived from a hands-on benchmark of a comparable
local screen-memory product. The comparison itself is no longer retained; the
bars stand on their own as Passage's release requirements. Architecture is
not proof: Passage should not claim a competitive win until a signed release
passes these repeatable gates on the same 2560×1440 scripted workload.

## Quantitative gates

| Gate | Release target |
| --- | ---: |
| Total steady storage | ≤75 MB per active hour |
| Metadata density | ≤15 KB per persisted frame |
| Transient media queue | ≤10 MB |
| Active CPU | <10% average; <35% p95 over two-second windows |
| Idle CPU | <1% |
| Memory footprint | <250 MB with no eight-hour growth |
| Capture→indexed latency | p95 <500 ms; p99 <1 s |
| Dropped eligible captures | <0.1% |
| First result at one million frames | <100 ms |
| Lexical/hybrid search p95 | <150 ms |
| Warm/cold random frame seek | <75 ms / <200 ms |
| Whole-footprint retention | Within 2% of cap; ≥95% reclaimable bytes removed |
| First-run comprehension | In a task test, ≥80% of new users can explain required vs optional access, choose Explore Paused, and later start/revoke/recover capture without coaching |
| Release integrity | Valid Developer ID signature and notarization |

## Qualitative gates

1. Never regress the privacy boundary to obtain retrieval or capture
   convenience.
2. Keep common metadata/facet reads subjectively instant and benchmark them as
   the corpus grows.
3. Keep agent output compact by default and explicitly byte bounded.
4. Let agents request one audited, projected evidence pack instead of manually
   joining OCR, pixels, accessibility, and metadata.
5. Add semantic activity segments and representative coverage before exposing
   broad all-day context.
6. Report recorded time, active time, and session span as distinct quantities.

## Current standing

The published encrypted 100,000-frame benchmark passes its narrower targets at
13.81 ms strict warm p50 / 33.35 ms p95, 21.04 ms conversational-rescue warm
p50 / 42.64 ms p95, 0.07 ms zero-hit warm p50 / 0.10 ms p95, and 16.29 ms
first-query-on-new-connection p50 / 36.05 ms p95. The current-schema million-row acceptance run passes the first-result gate at
**22.94 ms p50 / 75.05 ms p95** for exact text+app+website Recall, with
**0.06 ms p95** unfiltered browse facets and **0.20 ms p95** app+website
browsing. The exact cursor invariant still reaches all 124 fixture hits.
Legacy search remains **1,653.71 ms p95**, text-scoped facets
**1,384.20 ms p95**, and context-bundle search/build **873.31 ms p95**. A dormant encrypted `MemorySegmentIndex` correctness slice provides
deterministic ≤64-frame segments, validated crash-safe rebuild,
incomplete-index fail-closed behavior, same-frame text validation,
whole-session agent privacy before limits, and revision-bound cursors; it
still needs a scheduler, consumer cutover, and million-row evidence before the
broader lexical/hybrid gate can close. The independent encrypted visual-index
probe passes its store-only million-scene gate at 21.46 ms warm p95 unscoped
and 42.05 ms with exact app+website+time scope, while cold snapshot load,
end-to-end hybrid publication, and broad real-scene relevance remain open.
Onboarding and the first-real-memory proof are implemented but have not passed
the comprehension gate above. Capture energy, real media growth,
whole-footprint retention, Accessibility overhead, provider-network behavior,
notarization, and signed-release verification remain release gates, not
inferred claims.
