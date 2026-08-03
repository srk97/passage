# Architecture

## Runtime data flow

```text
NSWorkspace + Accessibility + WindowServer
                    │ focused context
                    v
ScreenCaptureKit -> capture coordinator -> privacy checks -> difference hash
       ^                    │                                      │
       │                    │ context checked again                ├─ unchanged: back off
       │                    v                                      └─ changed/heartbeat
       └──────── adaptive cadence <── power + thermal signals              │
                                                                            v
                                                            Vision OCR + HEIC/JPEG encoding
                                                                            │
                                      ┌─────────────────────────────────────┴────────────┐
                                      v                                                  v
                         AES-256-GCM media files                         SQLCipher + FTS5 index
                                      ^                                                  ^
                                      │                                                  │
                           SwiftUI search/timeline                         bounded capability handler
                                                                                         │
                                                                              audited local socket
                                                                                         │
                                                                                   passage CLI
```

Capture, OCR, bounded focused-window Accessibility evidence, visual embedding/indexing, query-time Vision region proposals, search, session construction, Memory Capsule assembly, Ask evidence selection, and IPC are local. Passage has no egress by default. Its one built-in outbound path is optional session intelligence: after the user explicitly invokes Enhance or Ask on a particular session, the UI sends one bounded text-only request to the configured provider and stores the validated result in a purpose-separated encrypted cache.

## Module boundaries

- `PassageCore`: stable value types, queries, capture/retention policies, activity-session and session-intelligence contracts, bounded Accessibility evidence, Memory Capsule/visual-disclosure schemas, audit receipts, repository protocols, and the storage-independent `MemorySegment` contract with deterministic revisions, exact frame lineage, modality provenance, explicit private/agent-safe requests, and revision-bound cursors.
- `PassageCapture`: ScreenCaptureKit, Accessibility/WindowServer context, bounded focused-window semantic collection, Vision OCR, difference hashing, adaptive scheduling, and pre-persistence privacy enforcement.
- `PassageStore`: Keychain/HKDF key handling, SQLCipher connections and schema-v10 migrations, FTS5, content-addressed Accessibility snapshots, Int8 visual embeddings, materialized activity sessions, the first dormant encrypted `MemorySegmentIndex` runtime, encrypted access receipts, authenticated media, encrypted preferences, retention primitives, and file permissions.
- `PassageService`: protocol-v5, length-bounded JSON framing; Memory Capsule, visual-search, provenance-bundle, and session schemas; and the same-user Unix-domain-socket client/server. It has no direct storage dependency.
- `PassageIntelligence`: separate provider-neutral brief/question boundaries, device-only API-key storage, OpenAI Responses implementations, bounded/validated request and response handling, and purpose-separated AES-GCM caches.
- `PassageUI`: onboarding, menu/timeline/search/session surfaces, local visual Recall, optional per-session intelligence, privacy/storage controls, agent allow-list policy, access activity, and composition of the service with the encrypted stores.
- `PassageCLI`: a thin client for capability discovery, Memory Capsules, visual search, provenance bundles, search, recent, sessions, frame, and stats, plus agent-skill installation. It supports `--session` filtering, does not link `PassageStore`, and keeps help/version available offline.
- `PassageBenchmark`: deterministic encrypted-index seeding and search measurements.

The frame and access-event stores are actor-isolated. Capture and OCR run away from the main actor, and the UI materializes bounded search windows.

## Onboarding, permissions, and durable capture intent

`PassageRootView` gates the memory browser on `chronicle.onboarding.v2.completed`. Until that flag is true, it presents one ordered four-step journey:

1. **Recall:** an interactive, synthetic search/result/source-return demonstration proves the outcome without rendering personal vault content, requesting a permission, calling a provider, or opening the encrypted vault. Model initialization is gated until onboarding completes.
2. **Local by design:** a visual quiet-minute example explains change checks, duplicate skipping, on-device OCR, encryption, and zero default uploads.
3. **Permissions:** Screen Recording and App Context have separate explicit controls. Screen Recording is required for capture. App Context is optional and adds richer window/browser attribution plus Accessibility-reported secure-field awareness.
4. **Context and agents:** a synthetic cross-app session demonstrates safe resume and bounded, source-cited handoff while making default-deny agent access and text-only optional intelligence visible.

The current step is stored under the `chronicle.onboarding.step.v3` preference, so an interrupted first run resumes at its last valid step. An invalid stored integer is normalized to the first step. Finishing resets the step for a future replay and records completion separately. Settings exposes **Review onboarding**: it first persists a paused capture intent, resets onboarding progress and completion, reopens the main window, and leaves memories, permissions, exclusions, and the optional provider key intact.

Every onboarding page exposes **Open paused** (labeled **Skip and open paused** on the first page). This completion choice never invokes capture start. On the last page, the primary action is **Allow Screen Recording** until that required permission is present, then becomes **Start remembering**. Permission buttons only ask macOS and refresh observed status; granting a permission does not itself change the user's remembering/paused choice. Before onboarding completes, menu-bar capture actions are replaced by **Finish Setup**, while Open Passage, Settings, and Quit remain available.

Capture intent is a separate durable state stored as `chronicle.capture.intent`; it is not inferred from transient labels such as unavailable, private context, or session lock. `startCapturing()` persists `remembering` before testing whether the coordinator exists or Screen Recording is available. A start clicked while the vault is still opening is therefore queued without triggering a second permission prompt, and initialization consumes that intent only after the coordinator is published and permission is confirmed. `pauseCapturing()` persists `paused` even when initialization is incomplete. This closes the startup race where a valid early Start Remembering choice could previously be lost.

Permission state is refreshed after startup and whenever the scene becomes active. The session privacy monitor also reconciles the authoritative protected-data API at application launch and activation instead of depending only on the timing of lock/unlock notifications. Revoking Screen Recording pauses an initialized coordinator without discarding a remembering intent; restoring it later restarts only if the saved intent is still `remembering`. A saved paused intent never restarts from a permission refresh. App Context refresh changes attribution/privacy capability but does not start capture. Session lock similarly tears down the runtime while preserving intent; unlock reopens the vault and resumes only when the remembered intent, current Screen Recording permission, active user session, awake screen, and actual protected-data state all allow it. A lock arriving while stores are opening is checked before the coordinator or decrypted state is published, preventing late initialization from repopulating a locked UI. The sealed presentation says that protected files are unavailable rather than claiming the visible desktop is locked; Passage cannot repair a macOS keybag that remains locked after a successful-looking sign-in, so that failure still needs OS-level recovery.

The packaging path prefers an available Developer ID Application identity, adds an Apple secure timestamp, enables the hardened runtime, and publishes only a read-only disk image created outside the iCloud-backed workspace. The app remains sealed inside that image until it is copied to Applications, preventing Finder/File Provider metadata from mutating nested signed code while it sits beside the artifact; an explicit ad-hoc override remains for development. The stable Developer ID requirement should preserve Passage's TCC application identity across updates. The first switch from an ad-hoc build changes that identity and may require one fresh Screen Recording or Accessibility grant. The package is not notarized.

## Startup and key hierarchy

At startup, the app loads or creates one random 32-byte root secret in the login Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and synchronization disabled. Manual Developer ID signing does not currently provide Passage an authorized application-identifier entitlement, so `hasDataProtectionKeychainIdentity` remains false and this package does not use or migrate the root into the data-protection Keychain. That backend remains a future packaging capability requiring an authorized application-identifier entitlement and provisioning setup. The root is not Codable or printable and is exposed to callers only through derived-key closures.

HKDF-SHA256 derives independent 256-bit subkeys with a fixed versioned salt and purpose strings:

| Purpose | Derivation context | Consumer |
| --- | --- | --- |
| SQLCipher index | purpose only | Main database, WAL, FTS data, and access receipts |
| Full-size media | frame ID | One screenshot envelope |
| Thumbnail media | frame ID | One thumbnail envelope |
| Privacy preferences | versioned preference context | One preferences envelope |
| Session-intelligence cache | SHA-256 cache identity derived from session ID + bounded-content fingerprint | One generated-session-summary envelope |
| Session-question cache | SHA-256 hash of the versioned question request fingerprint | One explicit-question answer envelope |
| Session-intelligence safety identifier | `openai-responses/v1` | Secret is SHA-256 hashed into the stable, device-local pseudonym sent as the API `safety_identifier`; key bytes are not disclosed |

Purpose separation prevents the same key material from being reused between storage layers. Frame and cache contexts make object keys distinct. The optional OpenAI API key is not derived from the vault root: it is a separate generic-password Keychain item with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and synchronization disabled. Losing or deleting the device-only vault root makes the encrypted vault and cached intelligence unreadable; there is no recovery-key workflow today.

## Storage layout

Storage identifiers use the name `chronicle`, which was this project's
original name. They are stable on-disk names, not the product name, and are
kept so that existing vaults, Keychain items, and derived encryption keys
continue to work. Renaming them would make every existing vault unreadable.

```text
~/Library/Application Support/Chronicle/
  chronicle.sqlite3
  chronicle.sqlite3-wal                 # present while WAL is active
  chronicle.sqlite3-shm                 # present while WAL is active
  privacy-preferences.json              # encrypted despite the file extension
  Media/v2/<hash-prefix>/<content-id>.bin
  Thumbnails/v2/<hash-prefix>/<content-id>.bin
  SessionIntelligenceCache/<sha256(session-id + fingerprint)>.bin
  SessionQuestionCache/<sha256(request-fingerprint)>.bin
  IPC/service.sock                      # present while the app service is running
```

The vault, media, thumbnail, intelligence-cache, and IPC directories are restricted to mode `0700`; database, sidecar, preference, media, cache, and socket files are restricted to `0600` where applicable. These permissions are defense in depth, not protection from root or from processes already acting as the same user.

### Encrypted index

The sole database-opening path keys SQLCipher immediately after `sqlite3_open_v2`, before schema reads or other pragmas. It then requires a non-empty `cipher_version`, an active `cipher_status`, and a successful read of `sqlite_schema`. Wrong keys, plaintext files on a read-only path, inactive codecs, and damaged indexes fail closed.

The index uses SQLCipher full-page encryption and authentication, WAL mode, `secure_delete=ON`, FTS5, prepared statements, and a bounded cache. The current writable schema is **v10**. It stores frame timestamps, display/window IDs and geometry, app/window/URL context, OCR text and regions, media references, visual fingerprints, materialized activity sessions, agent access receipts, local visual-index state, and bounded Accessibility semantics. Schema v5 added compound `(captured_at, id)` ordering to the time/app/domain indexes; schema v6 aligned FTS row IDs with frame row IDs; schema v9 added model metadata, deduplicated symmetric-Int8 vectors, frame associations, and encrypted angular-shortlist blocks; schema v10 adds content-addressed Accessibility snapshots and rebuilds aligned FTS with an `accessibility_text` column. Each frame references the SHA-256 hash of a canonical snapshot payload, capped at 16 KiB, and retention removes snapshots no surviving frame references.

`MemorySegmentIndex` is the first Store implementation of the Core segment contract. An explicit, exclusive, crash-safe rebuild writes deterministic app/domain/session segments of at most 64 exact ordered frame IDs plus compact path-free representatives and modality provenance into shadow tables inside the encrypted database, validates the completed generation, and only then marks it ready. Absent, building, dirty, invalid, or stale generations return `incompleteIndex`; partial generations are never served. Candidate text in a segment is only a pruning hint: every hit must also satisfy canonical FTS on the same underlying frame. Agent-safe reads apply current frame policy and whole-session sensitivity before `LIMIT` or cursor pagination, and cursors bind to normalized scope and segment revision. This slice is deliberately dormant: canonical mutations invalidate it, rebuild is manual rather than scheduled or incremental, and Recall, Ask, Memory Capsule, and bundle consumers have not been cut over. Saved text is its only searchable modality today, and no million-row segment benchmark exists yet.

Opaque versioned cursors are bound to the normalized text/date/app/domain scope that produced them, and malformed or cross-scope cursors fail closed. OCR regions use a versioned compact binary codec: region text becomes validated UTF-8 offsets into canonical OCR text, while confidence/geometry use normalized 16-bit values. Legacy JSON rows remain readable. A narrow OCR-refinement transaction updates canonical text, compact regions, and the row-ID-aligned FTS row together only when frame ID and visual fingerprint still match; deletion and retention races become a nil/no-op rather than recreating evidence. The application verifies and atomically migrates a legacy plaintext SQLite index before normal writable use.

### Authenticated media, preferences, and intelligence cache

Full-size screenshots prefer HEIC and fall back to JPEG; thumbnails remain JPEG. They are encoded in memory, then sealed independently with AES-256-GCM. The versioned envelope header—including media kind and frame ID—is authenticated as additional data but is not encrypted. New filenames are date-free hashes of frame IDs. Reads authenticate before decoding pixels, reject traversal outside the vault, and enforce a 128 MiB encrypted-file limit.

Privacy preferences are sorted JSON sealed with AES-256-GCM and a versioned authenticated header. They contain capture cadence, retention limits, exclusions, cursor choice, and allowed agent identifiers. Legacy plaintext media and preferences are migrated on app startup.

Each provider-generated session enrichment is sorted JSON sealed with AES-256-GCM under a key derived for that cache identity. The identity includes the stable session ID and a SHA-256 fingerprint over the exact bounded source content. A changed session transcript therefore produces a cache miss rather than reusing stale intelligence.

Explicit-question answers use a different directory, HKDF purpose, authenticated marker, and key context. Their request fingerprint covers feature/schema version, normalized question, selected-session ID, exact bounded evidence, provider, and model; the on-disk filename rehashes that fingerprint. Question and answer text exist only inside the AES-GCM envelope. Both cache formats cap entries at 512 KiB, reject symlinks/non-regular files, require owner-only permissions, and authenticate their header and identity before decoding.

See [Security and threat model](SECURITY.md) for metadata exposed by these formats and the temporary plaintext recovery artifact used during an old-index migration.

## Capture and adaptive cadence

The default active interval is two seconds; Settings offers one, two, or five seconds. Each due candidate uses `SCScreenshotManager` for one privacy-filtered still image; Passage does not create an `SCStream` or an ongoing macOS screen-sharing session. Captures are scaled so their longest dimension is at most 1,920 pixels before hashing, OCR, and HEIC/JPEG encoding.

For each loop iteration Passage:

1. Reads the focused app/window/URL context and evaluates exclusions before requesting pixels.
2. Captures the exact focused window by default. A missing/excluded window fails closed instead of widening to a display. Optional full-display mode uses the focused window’s associated display when available, otherwise the main or first available display, while excluding Passage and excluded application bundles at the ScreenCaptureKit filter.
3. Reads context again and discards the candidate if the focused context changed or became private while the frame was arriving.
4. Computes a 64-bit difference hash before OCR or disk I/O.
5. Persists a sufficiently changed frame, or a heartbeat frame after the configured unchanged interval (30 seconds by default).
6. Runs Vision OCR; when optional App Context access is present, collects a bounded semantic snapshot from the same still-authoritative focused window; then encrypts media, inserts the index row, and removes the new media if the database insert fails.

Accessibility collection never prompts. It is absent when App Context is off, the context is sensitive, or the focused-window identity cannot be proved before and after the walk. The breadth-first walk is limited to 192 visited nodes, depth 7, and a 16 KiB canonical payload; hidden nodes are skipped and role/label/value strings have independent byte limits. A focused secure password field makes the whole context private before ScreenCaptureKit is asked for pixels. During the semantic walk, a secure node's role/subrole is used only to identify the boundary; its label/value is not read and the node is not traversed.

After unchanged candidates, screenshot requests back off through 1×, 2×, 4×, and 8× the active interval while lightweight context checks continue. A focused-context change resets the backoff and captures immediately. Low Power Mode multiplies the active interval by 1.5; thermal states multiply it by 1, 1.25, 2, or 4 for nominal, fair, serious, or critical pressure. Errors retry at the effective active interval and cannot create a zero-delay loop. Focused-window/screenshot availability races remain a quiet retry for two consecutive failures; the third escalates to Needs Attention. A surfaced error remains visible through a mere retry attempt and clears only after an actual persist or safe skip, preventing menu-bar status flapping. Because there is no continuous frame callback, backoff reduces pixel delivery as well as fingerprinting, OCR, encryption, and writes.

## Recall Navigator

The UI and capture writer use separate repository contracts. `FrameRepository` remains narrow; `RecallNavigationRepository` adds full-history pages and local facets. Empty text is true chronological browsing, while non-empty text applies a syntax-safe FTS expression and still orders matches by `(captured_at DESC, id DESC)`. Time bounds are start-inclusive/end-exclusive. App and domain facets use drill-sideways aggregation: each list ignores its own active selection while retaining text, time, and the opposite facet. The UI requests 60 rows at a time, groups them by the current local calendar day, names any remaining history explicitly, and loads earlier pages only through the cursor returned for the exact scope.

The first page publishes without waiting for full-scope facet aggregation. Every authoritative result publication then reconciles the inspector in one place: preserve the selected frame ID with refreshed row data if it remains visible, otherwise select the first result, and clear only after a successful empty result. Stale, failed, canceled, locked, and pre-retention generations do not use that rule to erase a valid selection. Facets run in a separately cancellable task whose operation token is checked against the owning Recall generation and effective loaded scope before publication, so a canceled or older count cannot overwrite a newer query. App and website menus distinguish counting/updating, failed-with-Retry, and completed-empty states while keeping selected filters removable. A utility-priority maintenance task drains every bounded trusted-URL domain-repair page after first publication, yields between pages, cancels at the vault-lock boundary, and refreshes only the current facet read when it actually repairs rows. A website facet is materialized only from a persisted trusted HTTP(S) URL/domain. Historical rows with neither value remain unknown: screenshot OCR cannot establish that their pixels came from a focused browser rather than a full display, so Passage does not guess. FTS covers OCR, title/app/URL fields, and schema-v10 Accessibility text; snippet markers are decoded into visibly emphasized matched segments rather than discarded as presentation-only punctuation.

Local visual Recall is a second, guarded path over the hash-pinned PE-Core-S-16-384 dual encoder. Lexical results publish first. Appearance retrieval embeds the query locally, scans the SQLCipher-resident angular shortlist and Int8 vectors, applies the same date/app/domain scope, and then refines a flat Best matches list without blocking ordinary Recall or capture. Visual-only results, similarity provenance, and partial index coverage remain explicit; Exact words cancels/bypasses the model.

Memory Lens reuses that encrypted index through the model's image tower rather than its text tower. Direct manipulation yields bottom-left normalized bounds only; authenticated source media is decoded and cropped off the main actor into a query-lifetime `CGImage`, with no temporary file, cache, crop record, or stored selection geometry. Retrieval excludes the source frame before shortlist representative selection while allowing another eligible frame associated with the same visual vector. The model owns an independent operation token and re-resolves the source fingerprint before and after the await. Publication additionally requires the same unlocked lifecycle, visual generation, Recall generation, metadata scope, source descriptor, and available repository/media/runtime. Lock, delete-all, retention, a new text query, or Timeline entry synchronously drops the crop and invalidates the task. Time/app/domain changes rerun the same source selection under the exact new scope. Results and copied evidence say only that the saved image looked similar to the selected area; they do not assert an object or person's identity.

Timeline is a reversible workspace transaction. Direct sidebar entry prefers the currently visible selection, exact-day scope, newest capture, then today. The default projection walks outward from that anchor until a two-minute activity gap, so sparse old outliers do not stretch a few loaded moments across the whole retained day or compress the current activity into a colored tail. **Browse whole day** deliberately switches to retained-day bounds while keeping loaded/painted/unloaded counts separate. Pointer time is view-local and updates every drag event; the frozen model bounds and result set stay fixed while the repository coalesces at-or-before seeks to an 80 ms floor. `RecallTimeLensPreview.resolution` distinguishes a correlated result from a retained prior hit, an explicit miss, and failure, so only current evidence can drive the accent memory puck or resolved copy. A released whole-day seek merges an unloaded returned frame into the current result set before selection, so a later focused projection remains centered on the committed moment rather than falling back to the newest loaded span. The inspector's **Revisit around this time** bridge passes the selected result's timestamp explicitly, opens that exact local day, and keeps the same frame selected while the unfiltered day loads. Entry snapshots Recall's exact query text and normalized scope, then clears text/application/domain filters and loads one calendar day. Day changes preserve that invariant; ordinary exit schedules a fresh Recall generation for the saved Recall snapshot and preserves the selection, which also prevents a late Timeline read from publishing into the restored view. Open details is an explicit commit: it keeps the clean chosen-day scope so the selected moment remains visible in Recall. During direct manipulation the preview reads the encrypted thumbnail when available; after release resolution settles, it switches to the retained full-size image.

Pausing, five minutes of user inactivity by default, entering an excluded focused context, focusing a secure text field reported through Accessibility when App Context access is granted, or locking/sleeping the session stops capture. A session lock also drops store, media, preference, and service references and clears visible evidence; unlock reopens them through Keychain and resumes only when the durable intent is `remembering` and Screen Recording is still granted.

## Privacy enforcement

The default application exclusion list covers 1Password, 1Password 7, Keychain Access, Passwords, and Bitwarden. A small title/bundle heuristic also marks likely password, private-browsing, incognito, and payment contexts as sensitive. When optional App Context access is present, an Accessibility-reported focused secure password field fails closed before pixels, and secure semantic nodes do not contribute text. User-added application exclusions are enforced both by focused-context policy and by ScreenCaptureKit application filtering.

Focused-domain exclusions match a host and its subdomains. When at least one domain exclusion exists, a recognized focused browser whose URL cannot be read is skipped rather than guessed. Default focused-window capture removes unrelated background windows from the pixel surface. If the user explicitly enables full-display capture, a background excluded domain can still appear while a different permitted context is focused; this residual limitation is detailed in [Security and threat model](SECURITY.md).

## Activity sessions and resume

The encrypted store materializes deterministic activity sessions while frames are inserted. Application changes do not split a session; a gap of exactly five minutes or more between persisted frames does. A session ID is the first frame ID in the bout, making live append, migration, and deterministic rebuild agree. Ordinary append writes update only the current session; an out-of-order import rebuilds membership, while retention repairs only affected sessions and selects a surviving visual representative.

Each summary carries its time span, frame count, latest context/snippet, representative frame, sensitivity aggregate, and safest resume target. Passage retains the latest captured `http` or `https` URL as an exact-source target; when none exists, it can only reactivate the latest application by bundle identifier and labels that fallback honestly. The private app UI shows all sessions. Agent-facing session discovery fails closed by omitting any mixed session that contains a sensitive frame.

## Optional session intelligence

Session intelligence is separate provider protocols for briefs and explicit questions, not part of capture or default retrieval. Both OpenAI Responses implementations default to `gpt-5.6-luna`, low reasoning effort, low verbosity, `store: false`, no tools, and a strict JSON schema. They are called only by explicit Enhance/Refresh or Ask actions on one selected session.

The provider input is chronological and capped at 20 moments and 20,000 UTF-8 bytes of source text, prioritizing the latest evidence. It can contain frame IDs, timestamps, application/window/domain/URL context, and bounded OCR snippets. Its type has no fields for screenshots, thumbnails, media paths, OCR geometry, or display dimensions, and the request declares no tools. The system instruction treats all evidence as untrusted text. Returned title, summary, where-left-off, and next actions use strict JSON; required claims must cite only frame IDs present in the request, invalid citations fail the result, and invalid individual actions are discarded.

Ask first performs one local, selected-session FTS query using at most six sanitized literal terms. The selector fail-closed checks membership again, keeps up to 12 ranked matches plus eight recent context moments, deduplicates by frame ID, strips URL credentials/query/fragment data, and shares one 20,000-byte ceiling between the normalized question and all source text. A private session pauses at an immutable prepared disclosure and requires a fresh confirmation naming exact moment/byte counts. The answer is either one to four individually cited claims or `insufficient_evidence` with no uncited prose. A separate operation ID and task suppress late output after cancel, session switch, key removal, history deletion, or lock.

## Retention and deletion

Retention defaults to 30 days and 20 GiB of image storage. After a successful capture, at most once per hour, the coordinator:

1. Deletes index and FTS rows older than the age cutoff and then removes their media files.
2. Re-measures storage and expires the oldest visual files in batches of at most 1,000 until media is under the configured target or no indexed visual remains to expire. By default, OCR/FTS/provenance rows stay searchable; users can instead choose full-frame deletion under storage pressure. Unlink failures can leave orphaned ciphertext above the target.

The Settings “Delete all history” action pauses capture, cancels provider and handoff tasks, deletes all frame, FTS, and materialized-session rows, attempts to remove the referenced media, clears both local intelligence caches, and refreshes the UI. Access receipts are a separate table and remain until the user clears them from Access History. Database deletion and filesystem deletion are not one transaction: media removal is best-effort, so an unlink failure can leave orphaned encrypted files.

These are application-level deletion semantics. They do not erase Time Machine copies, filesystem snapshots, other backups, or previously copied files, and they do not promise physical overwrite on APFS/SSD storage.

## Local agent boundary

The app owns a Unix-domain socket under a non-symlinked, owner-only IPC directory. The socket is owner-only; the server validates peer credentials with `getpeereid`, accepts only the current effective user by default, limits request/response size, caps concurrent connections, and applies I/O timeouts.

Protocol v5 / service 0.9.0 offers offline CLI help/version, live capability/health discovery, and one-result-per-request framing. The app-side handler adds a second, default-deny policy using the request's declared client identifier. An allowed caller receives only one bounded capability result:

- `search`: up to 100 FTS/metadata hits;
- `recent`: up to 100 recent hits;
- `sessions`: up to 100 non-sensitive session summaries; returned counts are audited without expanding a session into its underlying frame IDs;
- `frame`: one frame document or no match;
- `statistics`: aggregate frame and byte counts;
- `visualSearch`: locally ranked image-appearance matches with bounded source metadata/OCR, similarity/error values, and index coverage; no pixels, media paths, vectors, or geometry;
- `memoryCapsule`: the preferred compositional path, exposed by CLI `remember`; it fuses saved-text and visual ranks, defaults to 8 results/64 KiB, permits at most 24 results/512 KiB, and returns bounded OCR, at most eight normalized Accessibility nodes per source, visual provenance, coverage, and omission accounting;
- `bundle`: a deterministic, text-only provenance manifest, normally 12 results/16 KiB and at most 99 results/256 KiB. It includes exact disclosed source IDs/timestamps and requested/matched/disclosed counts, uses one-result look-ahead, omits sensitive contexts, and never contains media paths, screenshots, or OCR geometry.

Memory Capsule re-resolves candidate IDs and current activity-session membership through the authoritative private-safe frame store before rank fusion and disclosure. Visual Search and Memory Capsule send their bounded candidate ID set through one agent-safe batch resolver instead of performing one SQL lookup per candidate; the resolver deduplicates IDs, preserves first-occurrence order, omits missing/private evidence, and caps the raw request at 256. The store excludes a whole materialized session if any moment is sensitive and fails closed when session materialization is missing. Visual SQL admits only associations whose source fingerprint still equals the retained frame fingerprint; cached visual session metadata is ignored. **The Capsule schema cannot return screenshots or pixel bytes.** Media paths, OCR geometry, embedding vectors, and display/window identifiers are also absent, and Capsule URLs discard credentials, paths, query strings, and fragments. The legacy `frame` response can expose an encrypted media-relative path as metadata, but it does not release decrypted pixels.

The app and local service share one manifest-only `LocalMemoryCapsuleRuntime`; authorization and receipt-before-IPC release remain outside that runtime. Recall and Sessions project a retrieved manifest into a separate `ContextHandoffPayload` whose types cannot represent screenshots, media paths, window titles, pixel dimensions/geometry, Accessibility bounds, or embedding vectors. The sheet renders the exact immutable Markdown or canonical JSON artifact. Before copy, Passage re-resolves every cited ID through the whole-session-private store and compares all exported source text/provenance with the current frame. It then commits a manual-handoff receipt and writes the already-previewed artifact to the clipboard without another suspension point. Lock and delete clear the draft synchronously; retention invalidates it; stale or missing sources, receipt failure, and clipboard failure never fall back to the older direct-copy helpers.

The CLI exposes `sessions`; a returned ID can be supplied through `--session` to `remember`, `search`, `recent`, or `bundle` so callers can retrieve one work bout without heuristic reassembly.

For a successful request, Passage durably records the declared client, command, query/filter summary, returned frame IDs/count, peer UID, timestamp, and outcome in the encrypted index **before** returning the result. The same receipt-before-release ordering applies to explicit in-app clipboard handoffs. A failed audit write prevents evidence from crossing IPC or reaching the clipboard. Policy denials for otherwise valid same-user requests are also recorded; operational failures are recorded best-effort. Transport failures that occur before the capability handler—such as malformed/oversized messages, protocol mismatches, and wrong-user peers—do not create access receipts. Access History can display and clear the receipts that are created.

The identifier allow list is not strong executable authentication. Any process running as the same macOS user can declare an enabled identifier. Developer ID signing gives Passage a stable application identity, but the service still does not read and validate a caller audit token or code-signing requirement; an ad-hoc development build is weaker still. Treat the service as protection against accidental access and cross-user access, not against a malicious same-user process.

## Future work — not implemented

- Notarization, reproducible release verification, and authorized application-identifier/provisioning support for the data-protection Keychain.
- Binding a client to an audit token and validated code-signing requirement, or replacing the socket with an equivalently authenticated IPC design.
- Browser-integrated private-tab verification, change-aware Accessibility diffs, and field-level redaction beyond the current bounded snapshot and secure focused-field suppression.
- Per-request external-agent previews/approval, media-byte capabilities, and provider-specific release policy beyond the current bounded OpenAI session path. Explicit in-app clipboard handoffs already have an exact preview/confirmation surface.
- Tamper-evident audit receipts and stronger verified-deletion/cryptographic-erasure workflows.
- Scheduling and incrementally maintaining the dormant SQLCipher `MemorySegmentIndex`, benchmarking it at one million rows, and cutting Recall, Ask, Memory Capsule, and agent bundles over to the shared runtime instead of repeating broad frame-level retrieval on each surface.
- Learned text-semantic ranking and workflow-level retrieval beyond the current lexical + visual rank fusion.
