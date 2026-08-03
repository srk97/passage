# Passage

Passage records what you see on your Mac and makes it searchable.

It takes a screenshot when the screen changes, reads the text in it, and stores
both on the device. You can then search your history by words, by appearance, or
by time. Nothing is uploaded.

`Passage` is the Mac app. `passage` is a command-line tool that gives local AI
agents access to the same history.

## Requirements

- macOS 14 or later
- Apple Silicon Mac
- Disk space for your history, capped at 20 GB by default and adjustable
- Screen Recording permission, required
- Accessibility permission, optional

## Install

Download `Passage.dmg` from the releases page, open it, and drag Passage to your
Applications folder. Open the app and follow the setup steps. You can also
[build it from source](#build-from-source).

Setup shows how search works before it asks for any permission. Screen Recording
is required to save anything. Accessibility is optional and adds browser
addresses, window details, and password-field detection.

## What it saves

Passage checks the screen every 1, 2, or 5 seconds, and saves a frame only when
the visible content changed. Each saved frame is called a moment. A moment
contains:

- the screenshot, in HEIC format
- the text read from it by the on-device OCR engine
- the app name, window title, and web address when available
- the time it was taken

By default Passage captures only the focused window, not the whole screen. It
saves still images, never video.

Sampling slows down on battery power, in Low Power Mode, and under thermal
pressure. Capture stops while you are inactive and resumes when you return.

Old data is deleted automatically. The defaults keep 30 days of history and up
to 20 GB of images. When the size limit is reached, Passage deletes the oldest
images but keeps their text searchable. Both limits are adjustable.

## What it never saves

- Apps you exclude, such as password managers
- Websites you exclude, by domain
- Any window with a focused password field, when Accessibility is granted
- Anything at all while capture is paused

## Finding things

**Recall** searches the text in your history. Filter by time, app, or website.
An empty search browses everything, newest first.

**Visual search** finds moments by how they looked, using a local image model.
Use it for things that were never written as text, such as "a red chart". It
labels these results as appearance matches, not identity claims.

**Memory Lens** searches by example. Select any region of a saved screenshot and
Passage finds other moments that look similar.

**Timeline** shows one day as a track you can drag through, with the image at
each point.

**Sessions** groups continuous work into spans. A span ends after five minutes
with nothing saved. Each span offers a link back to where you were.

## Agent access

Local AI agents can search your history through the `passage` command. This is
off by default. Enable each client individually in Settings.

```sh
passage install-skill claude    # or codex, or cursor
PASSAGE_CLIENT=claude passage remember "the pricing table" --since 3h --json
```

Agents receive text, timestamps, and source details. They never receive
screenshots, file paths, or image data. Every request is recorded in Access
History, which you can read and clear.

Run `passage help` for all commands.

## Privacy and security

All capture, text extraction, indexing, and search run on the device.

Data is encrypted at rest. The index uses SQLCipher. Images and settings use
AES-256-GCM. The encryption key is generated on the device, stored in the login
Keychain, and never synced. If macOS locks the keychain, Passage shows a sealed
state instead of any stored content.

Passage sends nothing to the network by default. The only feature that can send
data is session summaries, described below.

Passage is a prototype, not an audited security product. It has known limits.
The main one: the command-line tool identifies itself by name, and Passage does
not verify that the program using a name is the program you approved. Another
process running as your user account could claim an approved name. Read
[Security and threat model](docs/SECURITY.md) before storing sensitive work.

## Optional: session summaries

You can ask a question about one session, or generate a summary of it. This is
the only feature that uses the network. It runs only when you click Enhance or
Ask, and sends text from at most 20 moments to OpenAI. Screenshots, file paths,
and geometry are never sent. Answers cite the moments they came from and are
cached encrypted on the device. Private sessions require a separate confirmation
each time.

## Build from source

```sh
mkdir -p work/swift-cache work/clang-cache
CLANG_MODULE_CACHE_PATH="$PWD/work/clang-cache" \
SWIFT_MODULECACHE_PATH="$PWD/work/swift-cache" \
swift test --disable-sandbox --no-parallel -j 1

CLANG_MODULE_CACHE_PATH="$PWD/work/clang-cache" \
SWIFT_MODULECACHE_PATH="$PWD/work/swift-cache" \
swift run PassageDesktop
```

To build the installable disk image with the bundled command-line tool:

```sh
scripts/package-app.sh
```

The script writes `outputs/Passage.dmg`. It verifies the bundled image model
against a pinned checksum and signs the app with an available Developer ID
identity. The build is not notarized. Set `PASSAGE_CODESIGN_IDENTITY=-` only for
local development builds.

macOS ties Screen Recording and Accessibility permission to the signing
identity. Changing identities requires granting permission again, then quitting
and reopening the app.

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [Product contract](docs/PRODUCT.md)
- [Security and threat model](docs/SECURITY.md)
- [Performance evidence](docs/PERFORMANCE.md)
- [Release gates](docs/RELEASE-GATES.md)
- [Local visual search](docs/VISUAL-SEARCH.md)
- [Local semantic retrieval](docs/SEMANTIC-RETRIEVAL.md)
- [Memory Lens evaluation](docs/VISUAL-REGION-INTELLIGENCE.md)
- [Session intelligence roadmap](docs/INTELLIGENCE-ROADMAP.md)
- [Image model conversion to Core ML](docs/PE-COREML-CONVERSION.md)
- [Memory segment lifecycle](docs/MEMORY-SEGMENT-GENERATIONS.md)

## License

Passage is licensed under the [Apache License 2.0](LICENSE).

It bundles the Meta PE-Core-S-16-384 image model, also under Apache 2.0, and
uses SQLCipher Community Edition under a BSD-style license. See [NOTICE](NOTICE)
for the full attributions.
