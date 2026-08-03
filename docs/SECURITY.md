# Security and threat model

## Status

Passage is a local macOS prototype. Its controls are implemented and covered by focused tests, but the product has not received an independent security audit, penetration test, or production signing review. Packaging prefers an available Developer ID Application identity and enables the hardened runtime; an explicit ad-hoc fallback remains for development. The local package is not notarized and is not App Sandbox restricted.

This document describes the current source tree and packaging script. It is not a claim that storing a screen history is risk-free.

## Assets and goals

Passage handles unusually sensitive data:

- screenshots and thumbnails;
- OCR text and regions;
- bounded focused-window Accessibility roles, labels, values, depth, and normalized bounds when optional App Context access is available;
- local visual-model metadata, content hashes, angular shortlist data, Int8 embeddings, similarity/error values, and frame associations;
- query-lifetime face/person proposals, in-memory crops, crop embeddings, and region-match bounds while an eligible local Recall query is active; these are not durable data;
- capture time, application, bundle, window title, URL, and domain;
- search terms, agent filters, Memory Capsule/visual-search scopes, and returned frame identifiers recorded in access receipts;
- materialized activity-session membership, summaries, resume URLs/application targets, and sensitivity aggregates;
- bounded session-intelligence transcripts, provider-generated claims/citations, the encrypted local enrichment cache, and the stable pseudonymous provider safety identifier;
- privacy exclusions, retention choices, and the agent allow list;
- v2 onboarding progress/completion and the durable remembering/paused intent;
- the Keychain vault root and keys derived from it;
- the optional OpenAI API key stored as a separate Keychain item.

The current design aims to:

1. keep captured content local unless the user enables a local client and that client requests it, or explicitly enhances one selected session through the optional provider path;
2. keep copied vault files confidential and tamper-detectable without the device-only Keychain secret;
3. reject excluded focused contexts before OCR or persistence;
4. prevent other macOS users from using the local service under normal Unix permission and peer-credential rules;
5. deny all declared agent identifiers by default and leave an inspectable receipt for valid same-user requests that reach the capability policy;
6. bound untrusted local-service requests and responses;
7. avoid starting capture from setup, a permission grant, or a transient runtime transition unless durable remembering intent is present;
8. remove expired or explicitly deleted history from the live application store.

## Trust assumptions and non-goals

Passage trusts macOS, Keychain, ScreenCaptureKit, Vision, Accessibility services, SQLCipher/CryptoKit, the logged-in user's session, and the running Passage process. The protections are strongest for data at rest while the user session is locked and the Keychain item is unavailable.

The current build does **not** claim to defend against:

- root, an administrator bypassing local permissions, kernel/OS compromise, or malicious code injected into Passage;
- a live debugger, memory reader, or hostile process with equivalent control of the unlocked user session;
- a malicious process running as the same user that impersonates an enabled local-service identifier;
- an enabled agent that copies returned OCR, bounded Accessibility semantics, titles, URLs, visual-match provenance, or other metadata elsewhere;
- OpenAI, a future configured provider, or a compromised provider/network/OS boundary retaining, logging, misusing, or disclosing the bounded transcript, API credential, or generated response sent during an explicit enhancement;
- another screen-recording or Accessibility-authorized application observing the screen independently;
- disclosure through backups, filesystem snapshots, crash reports, swap, or copies created outside Passage;
- denial of service through file deletion/corruption, Keychain deletion, socket exhaustion within limits, or forced process termination.

## Implemented controls

### First-run consent and capture lifecycle

The four-step v2 onboarding demonstrates recall with synthetic content before it asks for access. Screen Recording and optional App Context use separate explicit Allow buttons; navigating forward does not grant either permission. Screen Recording is labeled required for remembering, while App Context is labeled optional. **Open paused** is available from every step and completes setup without calling the capture-start path. On the final page, the primary action remains **Allow Screen Recording** until macOS reports that permission; only the separate **Start remembering** action persists remembering intent. Before setup completes, menu-bar capture actions are replaced by **Finish Setup**.

Onboarding progress and completion use v2-scoped preferences so an interrupted flow can resume without conflating “visited a page” with “consented to capture.” Settings can replay onboarding, but it first persists paused intent. Replay deliberately preserves history, system permissions, exclusions, agent choices, and the provider credential; it is product education, not a privacy reset.

Remembering/paused intent is persisted independently from transient capture state. A start choice made while encrypted storage is initializing is queued without automatically invoking a permission prompt; initialization consumes it only if Screen Recording is currently granted. Foreground permission refresh pauses the coordinator when Screen Recording is revoked while preserving the user's remembering intent, and restarts after restoration only if that intent remains. A paused intent does not restart. App Context grants or refreshes never start capture. Session lock tears down key-owning/runtime objects but preserves intent for conditional restoration after unlock.

Startup also checks whether a session lock arrived while stores were opening before it publishes a new coordinator or decrypted state. This closes a race in which late initialization could otherwise repopulate or restart after the lock transition. These controls reduce accidental capture; they do not replace the macOS Screen Recording authorization boundary, and the local preferences themselves are not cryptographic authorization.

### Key hierarchy and lock lifecycle

On first startup Passage generates 32 random bytes with `SecRandomCopyBytes` and stores them as one generic-password item in the login Keychain. It uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and disables synchronization. Manual Developer ID signing does not currently supply an authorized application-identifier entitlement, so `hasDataProtectionKeychainIdentity` remains false and this package neither uses nor migrates the root into the data-protection Keychain. That backend remains a future packaging capability requiring an authorized application-identifier entitlement and provisioning setup. The root has no printable, equality, Codable, or raw-data API.

HKDF-SHA256 derives separate 256-bit keys for the SQLCipher index, full-size frame media, thumbnail media, privacy preferences, session-brief cache, and explicit-question cache. Media derivations include the frame ID; brief-cache derivations include a SHA-256 identity over the session ID plus bounded-content fingerprint; question-cache derivations include a rehashed request fingerprint covering schema, question, session, evidence, provider, and model. A seventh purpose derives a secret that Passage hashes before exposing it as a stable, device-local OpenAI `safety_identifier`; the provider does not receive the derived secret itself. CryptoKit supplies a fresh AES-GCM nonce for each seal.

The optional OpenAI API credential is not derived from the vault root. `OpenAIAPIKeyStore` stores it as a service-scoped generic-password item with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and synchronization disabled. It does not read process environment variables, UserDefaults, configuration files, or history, and Passage does not write the key to its logs. The item remains available to the app while this device is unlocked and must be deleted separately from history.

When Passage receives workspace session-resign, screen-sleep, or protected-data-unavailable notifications (the events used for typical lock/sleep transitions), it pauses capture, stops the local service, drops store/media/preference/key-owning objects, and clears visible evidence. It also reconciles the authoritative protected-data API when the application finishes launching and becomes active, covering missed or early lifecycle notifications. It reopens encrypted storage only after the user session is active, the screen is awake, and protected data is actually available again. A protected read that disproves an optimistic macOS availability preflight repairs this state and waits for the next availability event instead of presenting an empty library. The presentation says **History sealed** and that protected files are unavailable rather than claiming that the visible desktop must be locked. If macOS completes visible authentication without unlocking its protected-data keybag, Passage cannot and does not bypass that boundary; the app remains sealed until OS-level session recovery restores protected data. This reduces exposure; it is not a guarantee against missed notifications, process-memory inspection before teardown, or OS-level memory artifacts.

### SQLCipher index

Passage pins SQLCipher.swift 4.17.0. All application database opens pass through one SQLCipher connection path. It applies the HKDF-derived raw key immediately after `sqlite3_open_v2`, then requires:

- a non-empty SQLCipher `cipher_version`;
- an active `cipher_status`;
- a successful schema-page read with the supplied key.

Wrong keys, inactive codecs, plaintext databases on read-only paths, and invalid schema reads fail closed. The encrypted main database and WAL contain frame metadata, OCR, FTS terms, media paths, materialized activity sessions, agent access receipts, local visual-index records, the dormant MemorySegment shadow index, and schema-v10 content-addressed Accessibility snapshots. Schema v10 rebuilds aligned FTS with normalized Accessibility label/value text while keeping the canonical semantic payload inside SQLCipher. The MemorySegment generation is served only after a crash-safe rebuild validates it; absent, building, dirty, invalid, and stale generations return an incomplete-index error rather than partial results. Agent-safe segment reads apply current frame policy and whole-session sensitivity before pagination and result limits. SQLCipher page authentication detects modification, while `secure_delete=ON` asks SQLite to overwrite deleted content in active database pages. Database, WAL, and shared-memory files are reset to owner-only permissions when opened or written.

`cipher_memory_security` is intentionally left off for search performance. Decrypted pages, query text, OCR, and derived material can therefore exist in Passage's live process memory and ordinary allocator caches. At-rest encryption is not process-memory protection.

### Media, preferences, and derived intelligence

Each full screenshot is HEIC-encoded when available and otherwise JPEG-encoded; thumbnails are JPEG. All are encoded in memory and independently sealed with AES-256-GCM before being written. The versioned header is authenticated as additional data, so changing its frame ID or media kind makes authentication fail. Reads authenticate before image decoding, reject paths outside the vault, and reject encrypted files over 128 MiB.

New media uses a date-free path based on `SHA256(frame ID)` and owner-only file permissions. Privacy preferences are JSON sealed with a separate AES-256-GCM key and authenticated version marker. Atomic writes request until-first-user-authentication file protection and are followed by owner-only permissions. Reads of Passage-owned media, preferences, intelligence caches, and model-pack metadata migrate and verify that protection class without rewriting their bytes. The at-rest payloads remain independently encrypted, while Passage's session monitor still seals the UI and revokes live vault capabilities whenever the Mac locks.

Provider-generated briefs and question answers are JSON sealed into separate owner-only AES-256-GCM caches and key domains. Brief identity includes the stable activity-session ID and exact bounded-source fingerprint. Answer identity covers feature/schema version, normalized question, selected-session ID, exact bounded evidence, provider, and model; the filename hashes that identity again. Entries are capped at 512 KiB. Question and answer text, claims, citations, provider/model, and generation metadata exist only inside the authenticated answer envelope; neither cache contains screenshots or the API key. Old, now-unreferenced fingerprints are not age-retained away automatically. A successful Delete All History clears both caches, while removing the OpenAI key alone does not.

Authentication detects tampering but cannot prevent deletion, rollback to an older valid encrypted file, or replacement of an entire valid vault snapshot.

### Capture privacy

Passage checks the focused context before requesting pixels and again after ScreenCaptureKit delivers them. Focused-window-only capture is the default. A missing/excluded window fails closed instead of widening to a display; a context transition, new private state, or focused secure password field reported by Accessibility when optional App Context access is granted causes the candidate to be discarded before fingerprinting, OCR, or storage. Passage uses one-shot `SCScreenshotManager` stills rather than a live screen-sharing stream. In optional full-display mode, application exclusions are also passed to ScreenCaptureKit so windows belonging to those bundles are omitted from the still image.

App Context is optional and Accessibility collection never prompts during capture. With that access present, Passage collects at most one normalized semantic snapshot from the same non-sensitive focused window, and checks the focus identity before and after the walk. Collection visits at most 192 nodes through depth 7; per-field text is bounded and the canonical stored payload cannot exceed 16 KiB. Hidden nodes are skipped. Only a node's role/subrole is read to recognize a secure boundary; its label/value is not read and its children are not traversed. A focused secure password field makes the entire context private before ScreenCaptureKit is asked for pixels. Without App Context access, Passage stores no Accessibility snapshot and cannot claim that Accessibility supplied secure-field awareness.

The default excluded applications cover common password managers and macOS password/keychain tools. A heuristic rejects bundle/title strings associated with password managers, password screens, private browsing, incognito mode, and credit cards. Heuristics reduce accidental capture; they are not content classification or a complete list of secrets.

### Optional session-intelligence egress

Passage has no egress by default. It sends a provider request only after the user presses Enhance/Refresh Brief or submits Ask on one selected session. A marked-private brief requires a dedicated confirmation. Every question about a marked-private session requires a fresh confirmation that names the exact selected moment count and byte count; approval applies only to the immutable prepared question/evidence snapshot. The sensitivity signal is heuristic and capture-derived, so an unrecognized secret may not receive the extra warning.

The implemented OpenAI Responses requests use `gpt-5.6-luna` by default with low reasoning effort, low verbosity, `store: false`, a strict JSON schema, no declared tools, and response-token caps. Briefs contain at most 20 chronological source moments and 20,000 UTF-8 bytes of text. Ask shares one 20,000-byte ceiling between its normalized question (at most 1,000 bytes) and up to 20 locally selected moments. Ask strips URL credentials, query strings, and fragments; both paths include bounded app/window/domain/URL/OCR text plus local frame IDs/timestamps, request instructions, and a stable pseudonymous safety identifier. Serialization overhead is outside the text cap. There are no screenshot/thumbnail bytes, media paths, OCR geometry, display geometry, or vault keys.

The prompts treat every evidence field as untrusted quoted text. Brief claims are rejected unless they cite supplied frame IDs. Ask returns either one to four short individually cited claims or `insufficient_evidence` with no model prose; empty, oversized, duplicate, uncited, or out-of-session claims reject the whole answer. Cache corruption, refusal, rate limit, and malformed output stop inline without an automatic retry or broader-data fallback. These controls constrain shape and provenance, not truth: a model can still misinterpret cited evidence or generate unsafe advice. The provider boundaries are abstract so future providers can reuse the same bounded contracts, but OpenAI Responses is the only implemented provider.

Passage uses the system URL loading stack and ordinary HTTPS trust; it has no certificate pinning and cannot protect data after a valid provider endpoint receives it. Provider compromise, account compromise, API-key theft, malicious model behavior, and compromised platform networking remain risks. Tests use a fake injected transport and no live provider request has been run, so they do not validate production retention, availability, billing, latency, or model behavior.

As of this document's date, OpenAI says API inputs and outputs are not used to train its models by default unless the customer opts in. Under default controls, abuse-monitoring logs may retain customer content for up to 30 days (or longer when legally required); eligible approved customers can have different retention controls. Passage sends `store: false`, which avoids Responses application-state storage for this request, but it is **not** a zero-retention promise because abuse-monitoring retention can still apply. See [OpenAI API data controls](https://platform.openai.com/docs/models/default-usage-policies-by-endpoint) and [OpenAI business-data privacy](https://openai.com/business-data/). Provider terms and controls can change independently of Passage.

### Local agent service and audit

The service listens on a Unix-domain socket inside an owner-controlled, non-symlinked `0700` directory. The socket is `0600`. The server reads peer credentials with `getpeereid` and, by default, requires the current effective UID. It also enforces framed-message validation, payload limits, result-count limits, connection caps, I/O timeouts, protocol versions, and one request per connection.

Protocol v5 / service 0.9.0 exposes live `capabilities`/`health`, `memoryCapsule`, `visualSearch`, `bundle`, `search`, `recent`, `sessions`, `frame`, and aggregate `statistics`. The CLI supports `--session` filtering on remember/Memory Capsule, search, recent, and bundle. It does not link the storage module, open the database, read media, or receive the vault key. The current `frame` response contains OCR/context and encrypted media path metadata, not decrypted screenshot bytes. Bundles are stricter: text snippets plus source metadata only, with exact canonical byte accounting, deterministic truncation, sensitive-frame omission, and no screenshot, media path, or OCR geometry.

Memory Capsule is the preferred agent retrieval surface. It combines private-safe saved-text and local visual candidates, re-resolves every frame and its current session through the authoritative encrypted store, fuses ranks, and returns a canonical bounded manifest. A session containing any sensitive moment is excluded in full, even when a caller already knows its ID. Visual associations must match the retained frame's current visual fingerprint, and cached visual metadata cannot assert session membership. The default is 8 sources / 64 KiB; the hard maximum is 24 sources / 512 KiB. A source can include OCR, up to eight normalized Accessibility nodes (including normalized node bounds), source metadata, and visual similarity/error provenance, with coverage and omissions for partial indexing or truncation. **Memory Capsule does not release screenshots or pixel bytes.** It also excludes media paths, OCR geometry, embedding vectors, and display/window identifiers, and strips URL credentials, paths, query strings, and fragments. Standalone visual search is metadata-only and applies the same no-pixel/no-vector boundary.

Person-detail refinement exists only in the interactive app. It reads authenticated images for an already-retrieved global shortlist, uses native Vision face/person proposals, creates JPEG crops in memory, and compares at most eight crops with the bundled local model. Crops, proposals, crop embeddings, and bounds are never persisted, cached, logged, copied into evidence text, or returned through the agent service. An 850 ms deadline, task cancellation, a synchronous lock-generation gate, key-bearing store revocation, low-power/thermal bypass, and pre/post/final fingerprint checks prevent late refinement from becoming a new durable or cross-session disclosure. The UI says only that a smaller person/face area looked related and explicitly does not claim identity.

Session discovery forcibly disables sensitive results in the store query and filters them again before encoding, so a session containing any sensitive frame is omitted even if its latest moment is ordinary. A permitted session-list response is audited by summary count without expanding the session into all member frame IDs. This protects discovery metadata; it does not strengthen the self-asserted client identity boundary described below.

All client identifiers start disabled. The peer UID comes from the socket, but `identifier`, `displayName`, and client version remain caller-supplied descriptions; protocol v5 does not cryptographically bind them to an executable. For an allowed request, a success receipt is durably inserted into the encrypted database before the result is returned; if that insert fails, evidence is withheld. Caller-controlled receipt summaries are control-flattened and delimiter-escaped. A policy-generation token is checked after retrieval and again after the receipt write, so disabling a client invalidates an already-running request before evidence release. Policy denials for valid same-user requests are durably recorded before the denial response. Operational failures attempt a best-effort receipt because the underlying store may itself be failing. Malformed/oversized messages, protocol mismatches, wrong-user peers, connection failures, and other errors rejected before the capability handler do not create access receipts.

Recall and Sessions also expose a local **Hand Off Context…** sheet. Opening it performs no disclosure and writes no receipt. Passage uses the same whole-session-private Memory Capsule retrieval runtime, then projects the result into a stricter DTO that has no fields for screenshots, media paths, window titles, full URL paths, pixel/Accessibility geometry, or embedding vectors. The sheet displays the exact Markdown or canonical JSON that an explicit Copy action will place on the macOS clipboard. Immediately before copy, Passage re-resolves every source and compares the exported text/provenance with the current private-safe frames. It then commits an encrypted manual-handoff receipt before writing the immutable artifact. Lock and delete clear the in-memory draft; retention invalidates it; a missing/changed source, audit failure, or lifecycle change withholds the clipboard write. Visible OCR or Accessibility text can itself contain sensitive strings that classification misses, so the exact text remains visible for human review rather than being described as credential-free.

## Threat summary

| Threat | Current mitigation | Residual risk |
| --- | --- | --- |
| Copied vault files without the Keychain root | SQLCipher and AES-256-GCM; owner-only permissions | File metadata remains visible; a copied unlocked Keychain or live key defeats this boundary |
| Corrupted index/media/preferences/intelligence cache | SQLCipher page authentication, AES-GCM tags, fail-closed reads | Deletion and rollback remain possible; no signed snapshot or anti-rollback counter |
| A different local user calls the service | `0700` directory, `0600` socket, `getpeereid` UID check | Root/admin and compromised OS are outside scope |
| An accidental or unapproved agent calls the service | Empty-by-default identifier allow list, bounded capabilities, receipts | Same-user identifiers are self-asserted and impersonable |
| An agent discovers a mixed sensitive session | Session query forced to exclude sensitive sessions, followed by a second result filter; audited count | Other agent capabilities and self-asserted identity retain their documented limits; sensitivity classification is incomplete |
| Capture starts unexpectedly during setup or permission recovery | Paused default, explicit Start remembering choice, durable intent/runtime separation, menu gating, and permission/lock reconciliation | Same-user code can mutate preferences or drive the UI; macOS permission alone cannot express Passage intent; crashes and OS failures remain possible |
| Session text leaves through optional intelligence | Explicit per-session action; fresh per-question confirmation for marked-private Ask; immutable exact-count disclosure; 20 moments / 20,000 text bytes; no images/paths/geometry/tools; strict local citation validation; `store: false` | App/window/URL/OCR/question text can itself be highly sensitive; provider, account, key, network/OS, policy, model, or endpoint compromise is outside the local vault boundary; default abuse logs may retain content up to 30 days |
| A person copies a Context Handoff | Exact Markdown/JSON preview; whole mixed-sensitive sessions omitted; geometry-free DTO; source revalidation; durable receipt before clipboard; lock/deletion/retention fail closed | Included OCR and app-provided text can contain sensitive strings; any same-user app may read the system clipboard after explicit copy |
| Sensitive focused app/site is active | Focused-window default, Accessibility-reported focused password-field fail-closed behavior when optional App Context access is granted, default/user exclusions, fail-closed unknown focused browser URL, repeated context checks | Without App Context there is no Accessibility secure-field signal; heuristics remain incomplete; optional full-display mode can include background excluded-domain content |
| An agent asks Memory Capsule or visual search for image contents | Typed schemas omit pixels, media paths, vectors, OCR geometry, and display/window identifiers; private-safe frame re-resolution; byte/result bounds; durable receipt before response | Capsule sources can still disclose OCR, normalized Accessibility semantics and node bounds, titles, site provenance, and visual-match metadata; caller identity remains self-declared |
| Old history exceeds policy | Hourly-on-capture age/size sweeps; row/FTS/media deletion | Cleanup is not continuous and does not erase backups/snapshots or guarantee SSD overwrite |
| Session locks while Passage is open | Capture/service stop and key-owning object teardown | Notifications and memory cleanup are best-effort, not a hardware isolation boundary |

## Known limitations

### Release signing and same-user client identifiers

The packaging script prefers an available Developer ID Application identity, signs the app, framework, and CLI with the hardened runtime, and obtains an Apple secure timestamp. It publishes only a read-only disk image assembled outside the iCloud-backed workspace; the app remains sealed inside that image until it is copied to Applications, so Finder/File Provider metadata cannot mutate nested signed code while it sits beside the artifact. `PASSAGE_CODESIGN_IDENTITY=-` remains an explicit ad-hoc development fallback. The package has no notarization ticket, and notarized distribution is not claimed.

A stable Developer ID designated requirement should let macOS preserve Passage's TCC application identity, including Screen Recording and Accessibility grants, across updates. Switching an existing installation from ad-hoc signing to Developer ID changes that identity and may require one fresh permission grant. A newly granted permission applies to a newly launched process, so Passage must be fully quit and reopened rather than merely having its window closed and reopened.

Developer ID signing does **not** authenticate local-service callers. The socket proves only that the peer has the same effective macOS user ID, and the service does not inspect an audit token or validate the caller's code signature. The `identifier`, `displayName`, and `version` inside a request are caller-supplied descriptions. Any process running as that user can claim `codex`, `claude`, `cursor`, `app.chronicle.cli`, or another enabled identifier. Access receipts will then contain the impersonated description. The current allow list is useful for safe defaults and preventing accidental access, but it is not strong client authentication.

There is also no per-request confirmation. Once an identifier is enabled, a same-user caller claiming it can use every currently exposed capability until disabled or until the app/service stops.

### Onboarding and capture-intent preferences are not authorization

The onboarding step/completion flags and remembering/paused intent are ordinary application preferences, not encrypted or authenticated policy records. Another process running with the same user's ability to modify the application preferences can change them, skip education, or alter intent. Menu gating and Open Paused prevent accidental product-path activation; they are not defenses against hostile same-user software. macOS Screen Recording permission still controls whether Passage can receive pixels, and revoking it remains the strongest user-visible stop outside terminating the app.

Review onboarding is intentionally non-destructive. It pauses capture but does not revoke macOS permissions, disable agents, delete an API key, erase history, or clear provider-side data. Users seeking those outcomes must use the corresponding Settings/system actions.

### Encrypted-file metadata leakage

Encryption hides file contents, not all metadata. A party able to list the vault can observe:

- the existence and approximate size of the database, WAL, preferences, media, and thumbnails;
- file counts, shard paths, permissions, and filesystem creation/modification/access times;
- write and deletion patterns that can reveal capture activity or retention sweeps;
- the `CHRMEDIA`/`CHRPRIV1` format markers and envelope versions;
- the `CHRINTEL`/`CHRASKQ` markers and versions, encrypted intelligence-cache file sizes, and stable hash-derived cache filenames;
- media kind and the frame ID stored in each authenticated but unencrypted media header;
- equality implied by stable hash-derived filenames for the same frame ID.

New filenames do not reveal dates, app names, domains, or window titles, and the database does not expose a normal SQLite header, but traffic-analysis-style inference remains possible.

### Device-only key loss and no recovery

`WhenUnlockedThisDeviceOnly` intentionally prevents Keychain synchronization or migration to another Mac. Copying only the vault directory (`~/Library/Application Support/Chronicle`, a stable on-disk name retained from the project's original name) is not a usable backup. Erasing the Keychain item, losing the device, losing access to the macOS account/Keychain, or changing packaging/keychain identity in a way that blocks item access can make all existing history permanently unreadable.

Passage has no passphrase export, recovery key, escrow, or supported encrypted-vault migration workflow. This is a confidentiality/availability tradeoff, not recoverable end-to-end backup.

### Optional full-display capture and background excluded domains

Passage captures only the focused window by default, which keeps unrelated background windows outside the normal pixel surface. If the user turns that setting off, Passage chooses the display associated with the focused window when available, otherwise the main or first available display, and captures that entire display. Domain policy is still derived only from the focused browser's Accessibility URL. In that optional mode, an excluded domain visible in a background browser window, split-screen region, overlay, picture-in-picture window, notification, or another included display area may not be detected.

Application exclusions are stronger because matching application windows are passed to the ScreenCaptureKit exclusion filter. They still do not redact sensitive content rendered by a permitted application, copied into another application, shown in system UI, or exposed by an unrecognized bundle/title.

If domain exclusions exist and a recognized **focused** browser hides its URL, Passage fails closed for that focused browser. This does not solve the background-window case.

### Retention and deletion are not cryptographic erasure

Retention runs only after a successful persisted capture and no more than once per hour. Expired items can remain beyond their nominal cutoff while capture is paused, the screen stays excluded, the app is closed, or captures keep failing.

Deleting a frame removes its FTS and frame rows, commits the database transaction, and then attempts to unlink referenced media. Media deletion ignores individual filesystem failures, so orphaned encrypted files can remain and the storage-pressure loop cannot account for them once their index rows are gone. `secure_delete=ON` improves live-database cleanup, but SQLCipher WAL pages can persist until checkpoint/reuse, and APFS copy-on-write, SSD wear leveling, Time Machine, filesystem snapshots, backups, swap, crash artifacts, or prior copies can retain ciphertext. Because the same vault root remains available, someone who obtains both an older encrypted snapshot and the root may read the older data.

Delete-all cancels active intelligence work and clears materialized sessions plus both local intelligence caches, but does not clear agent receipts; those have a separate user action. Neither receipt clearing nor history deletion is tamper-evident or independently verifiable today. If cache removal fails, the action reports an error; backups and snapshots can still retain older encrypted cache entries.

### Legacy plaintext migration window

When upgrading a prototype plaintext SQLite index, Passage validates it, checkpoints its plaintext WAL, and creates an owner-only plaintext recovery copy before exporting to a separately verified SQLCipher database and atomically replacing the original. It then deletes the recovery copy and quarantined sidecars.

A crash or power loss during that process can leave a `chronicle-plaintext-backup-<uuid>.sqlite3` artifact and sidecars in the vault. After Passage independently verifies that the canonical database is encrypted, a later writable open removes recognized stale recovery artifacts. Until that cleanup succeeds, legacy plaintext can remain on disk and in backups/snapshots.

Legacy plaintext JPEGs and privacy JSON are read during their one-time migrations. Media is sealed in place and preferences are atomically replaced, but old filesystem snapshots or backups can retain the plaintext versions.

### Optional-provider retention and credential limits

`store: false` controls Responses application-state storage, not every provider log or legal retention path. OpenAI's documented default abuse-monitoring window can still apply, and Passage cannot verify what was deleted inside a provider. Ask strips URL credentials, queries, and fragments, but paths, titles, OCR, domains, and the question can still contain personal data or instructions; text-only is a smaller disclosure surface than screenshots, not an anonymity guarantee.

The stable safety identifier is pseudonymous, not anonymous: it is consistent for this vault/provider derivation and can therefore correlate requests from the same installation. Deleting the API key does not delete provider-side data, rotate this identifier, or clear already generated local briefs/answers. Delete All History clears both local intelligence caches, but older encrypted cache files may remain in backups/snapshots and provider-side retention is governed separately.

The OpenAI API key is device-only and non-synchronizing, but any process able to control or inspect the unlocked Passage process, use the app's Keychain access context, or compromise the user/OS may obtain or use it. Passage does not impose a spend limit, rotate the key, validate project retention settings, or provide provider-side deletion controls.

### Audit limitations

Access receipts share the encrypted database with captured history. They are not append-only, chained, signed, or protected from a user—or code with vault access—that edits or clears them. Failure receipts are best-effort. The receipt identifies the verified peer UID but records a self-declared client name/identifier, so it cannot prove which executable made a request. Session-list receipts record the returned summary count, not every member frame ID. The CLI's `recent` command currently uses the filtered `search` service path, so its receipt is labeled `search` rather than `recent`. Bundle `matchedCount` is deliberately a bounded one-result look-ahead, not an exhaustive corpus match count.

Provider enhancements and questions are not agent-service requests and do not create agent access receipts. Valid results record provider/model and generation time in their encrypted caches, but Passage has no separate append-only provider-egress ledger.

## Operational guidance

- Use **Open paused** when evaluating the interface before granting Screen Recording. App Context is optional; leave it off unless richer browser/window attribution and secure-field awareness are worth the additional Accessibility grant. Treat Review onboarding as education, not a permission or data reset.
- Treat enabling a client as granting every same-user process the practical ability to claim that client until strong executable authentication ships.
- Keep focused-window capture enabled. If full-display mode is necessary, prefer application exclusions for highly sensitive tools and do not rely on domain exclusions when sensitive sites can remain visibly open in background windows.
- Secure focused password fields reported through Accessibility stop capture when optional App Context access is granted, and secure nodes' labels/values are never collected. App Context can remain off, but then that Accessibility signal is unavailable; pause Passage before displaying secrets in ordinary permitted fields or windows.
- Treat Enhance and Ask as disclosure actions. Inspect the selected session and its app/window/domain/URL/OCR evidence first, read the exact private-question disclosure, use an OpenAI project with the data controls you require, scope/spend-limit the key outside Passage, and remove the key when it is no longer needed.
- Do not interpret `store: false` as zero retention. Consult the current [OpenAI API data controls](https://platform.openai.com/docs/models/default-usage-policies-by-endpoint) before sending sensitive work.
- Keep macOS, Passage, and the SQLCipher dependency updated; restrict administrator access and protect the login session.
- If Passage remains on **History sealed** after the desktop visibly unlocks, do not treat the view as an empty vault or force access to protected files. Restart or re-establish the macOS login session; if the keybag still does not unlock, diagnose OS authorization extensions or third-party screen-unlock plug-ins at the system level before reopening Passage.
- If history is irreplaceable, understand that ordinary vault-file backups are unusable without the device-only Keychain item. If history is highly sensitive, understand that backups/snapshots can outlive in-app deletion.

## Future security work — not implemented

- Notarization, reproducible release verification, authorized application-identifier/provisioning support for the data-protection Keychain, and an independent security review.
- Executable authentication using audit tokens plus validated code-signing requirements/team identity, or an equivalently authenticated XPC design.
- Per-request approval and least-privilege, per-client capability grants.
- A provider-egress activity ledger, per-field preview/redaction, provider/project retention verification, credential spend controls, and policies for any provider added beyond the current OpenAI path.
- Browser-integrated private-tab verification, change-aware Accessibility diffs, and pre-persistence visual/text redaction beyond the current bounded snapshot and focused secure-field detection.
- A user-controlled recovery/export design with an explicit security tradeoff and authenticated migration between devices.
- Tamper-evident audit receipts, anti-rollback protection, explicit audit retention, and verified deletion/checkpoint or cryptographic-erasure workflows.
- Fuzzing and adversarial testing for IPC framing, migrations, media envelopes, rapid focus changes, multi-display layouts, and exclusion bypasses.
