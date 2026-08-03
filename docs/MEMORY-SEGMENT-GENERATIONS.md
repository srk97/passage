# Memory Segment Generation Lifecycle

Status: production-gating design for schema v4.

Passage's compact MemorySegment v3 passed its frozen three-run,
one-million-frame storage and retrieval gate. It is not yet a production
runtime because its rebuild replaces the only readable shadow while holding a
database writer transaction for roughly 17–19 seconds. A background actor does
not solve that SQLite writer lock.

Schema v4 introduces immutable, generation-qualified shadows. The currently
active generation remains readable while a replacement is seeded, repaired,
validated, and atomically activated through short committed slices.

## Non-negotiable invariants

1. Retrieval resolves the active generation pointer and every candidate inside
   one SQLite read snapshot. It never reads a building or retired generation.
2. Every segment, member, dirty row, repair job, cursor, revision, and counter
   is generation-qualified. Composite constraints reject mixed-generation
   lineage.
3. A canonical mutation enqueues the affected session for both the active and
   building generations in the same transaction as that mutation.
4. An active dirty session is reconstructed from canonical rows; its stale
   shadow rows are not candidates. A building dirty session is never eligible
   for activation until its version is repaired and validated.
5. The seed high-water frame key and seed cursor are durable. Frames committed
   after the high-water mark are covered by trigger-driven dirty work.
6. Every writer slice uses both a row budget and a deadline/progress interrupt.
   The target is at most 20 ms of writer ownership. A frame cap alone is not a
   latency guarantee.
7. Large-session repair is resumable. Partial work remains generation-private,
   and a dirty-version change discards/restarts that session before activation.
8. The final pointer swap is a short `BEGIN IMMEDIATE` transaction. It rechecks
   the seed cursor, dirty queue, repair jobs, validation epoch, coverage counts,
   structural constraints, and completed revision before publishing.
9. Lock revocation synchronously cancels and revokes the dedicated maintenance
   SQLCipher connection before any suspension point. Unlock creates a fresh
   vault-scoped controller and resumes durable work.
10. Retired generations are deleted in bounded, resumable slices. Cleanup can
    never delay capture or remove the active generation.

## State machine

```text
absent -> seeding -> catching_up -> validating -> ready(active)
                    ^                 |
                    | dirty mutation  |
                    +-----------------+

old active -> retired -> bounded cleanup -> removed
```

If there is no active generation, retrieval reports an incomplete index; it
does not report an empty history. If a replacement build fails or is revoked,
the old active generation remains authoritative.

## Build slices

The store exposes a ticketed internal lifecycle rather than a monolithic
rebuild:

```swift
beginMemorySegmentGenerationBuild() -> MemorySegmentBuildTicket
advanceMemorySegmentGenerationBuild(ticket, limits) -> MemorySegmentBuildSliceResult
cancelMemorySegmentGenerationBuild(ticket)
```

The ticket contains a generation ID and unpredictable durable build nonce.
Every advance compare-and-swaps both values, so a stale task from an earlier
unlock or replaced build cannot mutate the current building generation. Slice
limits include both a canonical-row budget and wall-clock deadline. Results
distinguish progress, an atomic swap, supersession, and no work.

`begin` resumes an already-selected valid ticket after reopen; it does not
replace healthy durable work. Session lock revokes the maintenance connection
without cancelling the ticket or clearing the pointer. Explicit cancellation
is different: it marks progress `cancelled`, clears the pointer by generation
and nonce CAS, and leaves rows for bounded abandoned-generation cleanup.

### Start

- Allocate a monotonic generation key.
- Snapshot `MAX(frames.frame_key)` as the seed high-water mark.
- Publish the building pointer.

Allocation never copies the active dirty queue in one set operation. A fresh
building generation has no stale rows: bounded seed enqueues every surviving
canonical session through the high-water mark, and mutations committed after
pointer publication dual-enqueue through triggers. A deleted zero-frame active
session requires no work in an initially empty generation. If future metadata
introduces work that seed cannot derive, that inheritance must be its own
durable bounded phase.

The durable progress row stores the generation ID, build nonce, phase, seed
high-water key, seed cursor, validation cursor/epoch, and phase counters. It is
the only source of build position; code must not infer progress by scanning
partially emitted segments.

### Seed

- Keyset through `frames_frame_key` up to the high-water mark.
- Enqueue distinct activity sessions into the building queue.
- Persist the last visited frame key in the same short transaction.
- Seed insertion uses conflict-do-nothing. A trigger-created dirty version is
  never overwritten or incremented merely because seed later encounters the
  same session.
- Seed-origin queue rows use reason bit 64. Canonical mutation bits remain
  1/2/4/8/16/32, so repair diagnostics can distinguish initial coverage from
  later invalidation without recording any personal identifiers.

### Repair

- Claim one generation/session/version.
- Materialize canonical session rows into resumable scratch state in bounded
  pages.
- Emit at most one 64-frame segment per writer slice.
- Validate exact session coverage, then delete the dirty row with a version CAS.
- If the CAS fails, discard partial generation rows for that session and retry.

Large-session scratch state stores stable frame keys and canonical source
ordinals, not OCR or media payloads. Source rows are keyset-materialized in
bounded pages. Emission joins those keys back to canonical encrypted rows,
writes at most one segment per slice, and remains invisible because retrieval
excludes the building generation. A mutation increments the queue version; the
final version CAS then discards and restarts any stale partial session.

Each slice reports canonical rows visited and SQLite rows changed, including
cascades and trigger effects. This makes the frozen row budget auditable rather
than merely advisory.

### Validate and activate

- Validate frame coverage and structural constraints in resumable reads.
- Derive the complete revision outside the final writer transaction.
- Recheck every activation invariant under the final short writer lock.
- Atomically swap active/building pointers and retire the previous generation.

Validation is read-paged and restartable. The final revision may be derived in
memory from the bounded set of stored segment/search-content revisions, but is
never trusted across a new dirty enqueue. The final writer transaction rechecks
the generation ID and nonce, empty queue and repair jobs, complete seed cursor,
validation epoch, exact counts, foreign keys, and structural constraints before
committing the pointer swap.

### Cleanup

Cleanup first removes member rows in bounded pages, then now-empty segment rows,
then generation metadata. This order prevents a segment cascade from silently
exceeding the row budget. Every delete is restricted to a durable retired
generation ID that is rechecked not to equal either live pointer.

## Product cutover order

1. Finish v4 schema and active/building isolation.
2. Finish bounded seed, repair, validation, activation, and cleanup slices.
3. Wire a dedicated vault lifecycle controller and lock revocation.
4. Re-freeze correctness, capture-responsiveness, storage, and three-run
   million-frame benchmarks as protocol v4.
5. Run non-authoritative AgentSafe bundle shadow parity with aggregate-only
   metrics. Legacy bundle output remains authoritative.
6. Cut over the first saved-text consumer only after parity and byte-budget
   behavior are demonstrated.

MemoryCapsule is not the first cutover target. The first target is saved-text
candidate acquisition for the audited bundle boundary, with authoritative
re-resolution and the existing bundle builder retaining the final byte budget.

## Snapshot-isolation proof

The production gate includes a deterministic three-connection barrier. A
reader resolves active generation G1 and pauses inside its read transaction; a
second connection activates G2; the first reader must then complete entirely
from G1, and the next read must see only G2. This correctness-only barrier is
excluded from latency samples.
