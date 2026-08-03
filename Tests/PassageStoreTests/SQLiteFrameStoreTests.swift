import PassageCore
import PassageStore
import Foundation
import Testing

@Suite("SQLite frame store")
struct SQLiteFrameStoreTests {
    @Test("Compact OCR regions round-trip without duplicating canonical text")
    func compactOCRRegionRoundTrip() throws {
        let text = "Passage storage\nSecond line of evidence"
        let regions = [
            OCRRegion(text: "Passage storage", confidence: 0.98, x: 0.05, y: 0.80, width: 0.40, height: 0.08),
            OCRRegion(text: "Second line of evidence", confidence: 0.87, x: 0.05, y: 0.68, width: 0.52, height: 0.07),
        ]

        let encoded = try OCRRegionCodec.encode(regions, canonicalText: text)
        let legacyJSON = try JSONEncoder().encode(regions)
        let decoded = try OCRRegionCodec.decode(encoded, canonicalText: text)

        #expect(decoded.map(\.text) == regions.map(\.text))
        #expect(encoded.count < legacyJSON.count)
        #expect(encoded.range(of: Data("Passage storage".utf8)) == nil)
        Self.assertQuantizedRegions(decoded, approximatelyEqualTo: regions)
    }

    @Test("Compact OCR region offsets preserve Unicode grapheme text")
    func unicodeOCRRegionRoundTrip() throws {
        let text = "Cafe\u{301} ☕️\n東京の会議\n👩🏽‍💻 résumé"
        let regions = [
            OCRRegion(text: "Cafe\u{301} ☕️", confidence: 0.91, x: 0.10, y: 0.82, width: 0.30, height: 0.06),
            OCRRegion(text: "東京の会議", confidence: 0.95, x: 0.10, y: 0.70, width: 0.24, height: 0.06),
            OCRRegion(text: "👩🏽‍💻 résumé", confidence: 0.89, x: 0.10, y: 0.58, width: 0.35, height: 0.06),
        ]

        let encoded = try OCRRegionCodec.encode(regions, canonicalText: text)
        let decoded = try OCRRegionCodec.decode(encoded, canonicalText: text)

        #expect(decoded.map(\.text) == regions.map(\.text))
        Self.assertQuantizedRegions(decoded, approximatelyEqualTo: regions)
    }

    @Test("Compact OCR region decoding rejects malformed bounds and payloads")
    func malformedOCRRegionData() throws {
        let text = "abc"
        let regions = [
            OCRRegion(text: text, confidence: 1, x: 0, y: 0, width: 1, height: 1),
        ]
        let valid = try OCRRegionCodec.encode(regions, canonicalText: text)

        var unsupportedVersion = valid
        unsupportedVersion[4] = 0x7F
        #expect(throws: OCRRegionCodecError.self) {
            try OCRRegionCodec.decode(unsupportedVersion, canonicalText: text)
        }

        var outOfBoundsText = valid
        outOfBoundsText[9] = 4 // Header is 8 bytes; byte 9 is this record's text length.
        #expect(throws: OCRRegionCodecError.self) {
            try OCRRegionCodec.decode(outOfBoundsText, canonicalText: text)
        }
        #expect(throws: OCRRegionCodecError.self) {
            try OCRRegionCodec.decode(valid, canonicalText: "abcd")
        }

        var outOfBoundsGeometry = valid
        outOfBoundsGeometry[12] = 0xFF
        outOfBoundsGeometry[13] = 0xFF // x = 1 while width remains 1.
        #expect(throws: OCRRegionCodecError.self) {
            try OCRRegionCodec.decode(outOfBoundsGeometry, canonicalText: text)
        }

        #expect(throws: OCRRegionCodecError.self) {
            try OCRRegionCodec.decode(valid.dropLast(), canonicalText: text)
        }

        var trailingData = valid
        trailingData.append(0)
        #expect(throws: OCRRegionCodecError.self) {
            try OCRRegionCodec.decode(trailingData, canonicalText: text)
        }

        let unicodeText = "é"
        var invalidUnicodeBoundary = try OCRRegionCodec.encode(
            [OCRRegion(text: unicodeText, confidence: 1, x: 0, y: 0, width: 1, height: 1)],
            canonicalText: unicodeText
        )
        invalidUnicodeBoundary[8] = 1
        invalidUnicodeBoundary[9] = 1
        #expect(throws: OCRRegionCodecError.self) {
            try OCRRegionCodec.decode(invalidUnicodeBoundary, canonicalText: unicodeText)
        }

        #expect(throws: OCRRegionCodecError.self) {
            try OCRRegionCodec.encode(
                [OCRRegion(text: text, confidence: .nan, x: 0, y: 0, width: 1, height: 1)],
                canonicalText: text
            )
        }
        #expect(throws: OCRRegionCodecError.self) {
            try OCRRegionCodec.encode(
                [OCRRegion(text: text, confidence: 1, x: 0.8, y: 0, width: 0.3, height: 1)],
                canonicalText: text
            )
        }
        #expect(throws: OCRRegionCodecError.self) {
            try OCRRegionCodec.encode(
                [OCRRegion(text: "missing", confidence: 1, x: 0, y: 0, width: 1, height: 1)],
                canonicalText: text
            )
        }
    }

    @Test("Legacy JSON OCR region blobs remain readable")
    func legacyJSONOCRRegions() throws {
        let text = "Legacy café\nsecond region"
        let regions = [
            OCRRegion(text: "Legacy café", confidence: 0.75, x: 0.1, y: 0.8, width: 0.3, height: 0.1),
            OCRRegion(text: "second region", confidence: 0.5, x: 0.1, y: 0.6, width: 0.4, height: 0.1),
        ]
        let legacyJSON = try JSONEncoder().encode(regions)

        #expect(try OCRRegionCodec.decode(legacyJSON, canonicalText: text) == regions)
        #expect(throws: OCRRegionCodecError.self) {
            try OCRRegionCodec.decode(Data("[{".utf8), canonicalText: text)
        }
    }

    @Test("FTS returns relevant frames and respects metadata filters")
    func searchAndFilters() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        try await store.insert(Self.frame(
            id: "desk",
            date: Date(timeIntervalSince1970: 100),
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: "furniture.example",
            text: "Solid walnut writing desk with two drawers"
        ))
        try await store.insert(Self.frame(
            id: "code",
            date: Date(timeIntervalSince1970: 200),
            app: "Xcode",
            bundle: "com.apple.dt.Xcode",
            domain: nil,
            text: "CaptureCoordinator adaptive screen sampling"
        ))

        let desk = try await store.search(SearchQuery(text: "walnut desk"))
        #expect(desk.map(\.id.rawValue) == ["desk"])

        let filtered = try await store.search(SearchQuery(
            text: "capture",
            applicationBundleIdentifiers: ["com.apple.dt.Xcode"]
        ))
        #expect(filtered.map(\.id.rawValue) == ["code"])

        let excluded = try await store.search(SearchQuery(
            text: "capture",
            domains: ["furniture.example"]
        ))
        #expect(excluded.isEmpty)
    }

    @Test("Missing browser domains backfill only from trusted source URLs")
    func browserDomainBackfill() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        var browser = Self.frame(
            id: "browser",
            date: Date(timeIntervalSince1970: 100),
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: nil,
            text: "www.youtube.com/watch?v=example"
        )
        browser.context.url = URL(string: "https://www.youtube.com/watch?v=example")
        browser.context.windowTitle = nil
        var ordinary = Self.frame(
            id: "ordinary",
            date: Date(timeIntervalSince1970: 500),
            app: "Notes",
            bundle: "com.apple.Notes",
            domain: nil,
            text: "www.notes.example"
        )
        ordinary.context.url = URL(string: "https://www.notes.example/page")
        var sensitive = Self.frame(
            id: "sensitive",
            date: Date(timeIntervalSince1970: 900),
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: nil,
            text: browser.ocrText,
            isSensitive: true
        )
        sensitive.context.url = URL(string: "https://private.example/secret")
        var legacyOCR = Self.frame(
            id: "legacy-ocr",
            date: Date(timeIntervalSince1970: 700),
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: nil,
            text: "visible.example/path"
        )
        legacyOCR.ocrRegions = [OCRRegion(
            text: legacyOCR.ocrText,
            confidence: 0.99,
            x: 0.2,
            y: 0.89,
            width: 0.5,
            height: 0.025
        )]
        try await store.insertBatch([browser, ordinary, legacyOCR, sensitive])

        #expect(try await store.backfillMissingBrowserDomains() == 1)
        #expect(try await store.frame(id: browser.id)?.context.domain == "www.youtube.com")
        #expect(try await store.frame(id: ordinary.id)?.context.domain == nil)
        // The region satisfies the focused-window parser, but legacy frames do
        // not say whether their pixels came from one window or a full display.
        // Unknown capture scope therefore remains ineligible for OCR recovery.
        #expect(try await store.frame(id: legacyOCR.id)?.context.domain == nil)
        #expect(try await store.frame(id: sensitive.id)?.context.domain == nil)
        #expect(try await store.recallFacets(RecallScope(), limitPerKind: 10)
            .domains.map(\.domain) == ["www.youtube.com"])
        #expect(try await store.activitySessions(ActivitySessionQuery(limit: 10))
            .first { $0.id.rawValue == "browser" }?.title == "www.youtube.com")
        #expect(try await store.backfillMissingBrowserDomains() == 0)
    }

    @Test("Browser-domain backfill advances past an unrepairable batch")
    func browserDomainBackfillProgressesPastUnrepairableRows() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        var repairable = Self.frame(
            id: "older-repairable",
            date: Date(timeIntervalSince1970: 100),
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: nil,
            text: "older website"
        )
        repairable.context.url = URL(string: "https://older.example/page")
        let unrepairableOne = Self.frame(
            id: "newer-unrepairable-one",
            date: Date(timeIntervalSince1970: 500),
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: nil,
            text: "no source URL"
        )
        let unrepairableTwo = Self.frame(
            id: "newer-unrepairable-two",
            date: Date(timeIntervalSince1970: 900),
            app: "Notes",
            bundle: "com.apple.Notes",
            domain: nil,
            text: "ordinary app"
        )
        try await store.insertBatch([repairable, unrepairableOne, unrepairableTwo])

        #expect(try await store.backfillMissingBrowserDomains(limit: 2) == 0)
        #expect(try await store.frame(id: repairable.id)?.context.domain == nil)
        #expect(try await store.backfillMissingBrowserDomains(limit: 2) == 1)
        #expect(try await store.frame(id: repairable.id)?.context.domain == "older.example")
        #expect(try await store.backfillMissingBrowserDomains(limit: 2) == 0)
    }

    @Test("Browser-domain maintenance drains more than one default-size page")
    func browserDomainBackfillDrainsLargeLibrary() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        var repairable = Self.frame(
            id: "oldest-repairable",
            date: Date(timeIntervalSince1970: 1),
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: nil,
            text: "old source address"
        )
        repairable.context.url = URL(string: "https://archive.example/page")
        let newerUnrepairable = (0..<2_001).map { index in
            Self.frame(
                id: "newer-unrepairable-\(index)",
                date: Date(timeIntervalSince1970: TimeInterval(index + 2)),
                app: "Safari",
                bundle: "com.apple.Safari",
                domain: nil,
                text: "browser page without source metadata"
            )
        }
        try await store.insertBatch([repairable] + newerUnrepairable)

        #expect(try await store.drainMissingBrowserDomains() == 1)
        #expect(try await store.frame(id: repairable.id)?.context.domain == "archive.example")
        #expect(try await store.backfillMissingBrowserDomains() == 0)
    }

    @Test("Browser-domain maintenance honors task cancellation")
    func browserDomainBackfillCancellation() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let maintenance = Task {
            withUnsafeCurrentTask { task in task?.cancel() }
            return try await store.drainMissingBrowserDomains(batchLimit: 1)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await maintenance.value
        }
    }

    @Test("Equal-relevance search candidates have a stable evidence order")
    func equalRelevanceOrderingIsDeterministic() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let timestamp = Date(timeIntervalSince1970: 200)
        for id in ["candidate-a", "candidate-z"] {
            try await store.insert(Self.frame(
                id: id,
                date: timestamp,
                app: "Notes",
                bundle: "com.apple.Notes",
                domain: nil,
                text: "identical passage evidence"
            ))
        }

        let unscoped = try await store.search(SearchQuery(text: "identical", limit: 10))
        #expect(unscoped.map(\.id.rawValue) == ["candidate-z", "candidate-a"])

        let scoped = try await store.search(SearchQuery(
            text: "identical",
            applicationBundleIdentifiers: ["com.apple.Notes"],
            limit: 10
        ))
        #expect(scoped.map(\.id.rawValue) == ["candidate-z", "candidate-a"])
    }

    @Test("OCR refinement atomically replaces frame evidence and its aligned search row")
    func ocrRefinementReplacesFrameAndSearch() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        var legacy = Self.frame(
            id: "ocr-repair",
            date: Date(timeIntervalSince1970: 100),
            app: "Slack",
            bundle: "com.tinyspeck.slackmacgap",
            domain: nil,
            text: "Me55age5 & Add carhwd5"
        )
        legacy.ocrRegions = [
            OCRRegion(
                text: legacy.ocrText,
                confidence: 0.31,
                x: 0.1,
                y: 0.8,
                width: 0.5,
                height: 0.05
            ),
        ]
        try await store.insert(legacy)

        let correctedText = "Messages and Add canvas"
        let correctedRegions = [
            OCRRegion(
                text: correctedText,
                confidence: 0.97,
                x: 0.1,
                y: 0.8,
                width: 0.5,
                height: 0.05
            ),
        ]
        let replacement = try await store.replaceOCR(
            for: legacy.id,
            expectedVisualFingerprint: legacy.visualFingerprint,
            text: correctedText,
            regions: correctedRegions
        )

        #expect(replacement?.ocrText == correctedText)
        #expect(replacement?.ocrRegions.map(\.text) == [correctedText])
        #expect(try await store.frame(id: legacy.id)?.ocrText == correctedText)
        #expect(try await store.search(SearchQuery(text: "canvas")).map(\.id) == [legacy.id])
        #expect(try await store.search(SearchQuery(text: "carhwd5")).isEmpty)
    }

    @Test("OCR refinement with a stale visual fingerprint is a no-op")
    func staleOCRRefinementIsNoOp() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let original = Self.frame(
            id: "stale-ocr-repair",
            date: Date(timeIntervalSince1970: 100),
            app: "Notes",
            bundle: "com.apple.Notes",
            domain: nil,
            text: "original evidence"
        )
        try await store.insert(original)

        let replacement = try await store.replaceOCR(
            for: original.id,
            expectedVisualFingerprint: original.visualFingerprint &+ 1,
            text: "incorrect replacement",
            regions: [
                OCRRegion(
                    text: "incorrect replacement",
                    confidence: 0.99,
                    x: 0,
                    y: 0,
                    width: 1,
                    height: 1
                ),
            ]
        )

        #expect(replacement == nil)
        #expect(try await store.frame(id: original.id)?.ocrText == original.ocrText)
        #expect(try await store.search(SearchQuery(text: "original")).map(\.id) == [original.id])
        #expect(try await store.search(SearchQuery(text: "incorrect")).isEmpty)
    }

    @Test("OCR refinement never recreates a frame deleted by retention")
    func deletedOCRRefinementIsNoOp() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let original = Self.frame(
            id: "deleted-ocr-repair",
            date: Date(timeIntervalSince1970: 100),
            app: "Notes",
            bundle: "com.apple.Notes",
            domain: nil,
            text: "soon deleted evidence"
        )
        try await store.insert(original)
        _ = try await store.deleteFrames(from: nil, through: nil)

        let replacement = try await store.replaceOCR(
            for: original.id,
            expectedVisualFingerprint: original.visualFingerprint,
            text: "must not return",
            regions: [
                OCRRegion(
                    text: "must not return",
                    confidence: 0.99,
                    x: 0,
                    y: 0,
                    width: 1,
                    height: 1
                ),
            ]
        )

        #expect(replacement == nil)
        #expect(try await store.frame(id: original.id) == nil)
        #expect(try await store.search(SearchQuery(text: "return")).isEmpty)
        #expect(try await store.statistics().frameCount == 0)
    }

    @Test("FTS snippets use the best matching metadata column")
    func metadataSnippetUsesBestColumn() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        var frame = Self.frame(
            id: "title-match",
            date: Date(timeIntervalSince1970: 100),
            app: "Figma",
            bundle: "com.figma.Desktop",
            domain: nil,
            text: "Ambient pixels without the requested project name"
        )
        frame.context.windowTitle = "Northstar checkout review"
        try await store.insert(frame)

        let unfiltered = try #require(
            await store.search(SearchQuery(text: "Northstar")).first
        )
        #expect(unfiltered.snippet.contains("‹Northstar›"))
        #expect(!unfiltered.snippet.contains("Ambient pixels"))

        let filtered = try #require(await store.search(SearchQuery(
            text: "Northstar",
            applicationBundleIdentifiers: ["com.figma.Desktop"]
        )).first)
        #expect(filtered.snippet.contains("‹Northstar›"))
        #expect(!filtered.snippet.contains("Ambient pixels"))
    }

    @Test("Activity sessions preserve cross-app work and split at exactly five minutes")
    func activitySessionization() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let first = Self.frame(
            id: "research",
            date: Date(timeIntervalSince1970: 100),
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: "passage.example",
            text: "Session research evidence"
        )
        let editor = Self.frame(
            id: "editor",
            date: Date(timeIntervalSince1970: 399),
            app: "Xcode",
            bundle: "com.apple.dt.Xcode",
            domain: nil,
            text: "Session implementation evidence"
        )
        let afterBreak = Self.frame(
            id: "after-break",
            date: Date(timeIntervalSince1970: 699),
            app: "Notes",
            bundle: "com.apple.Notes",
            domain: nil,
            text: "A new work bout"
        )
        try await store.insertBatch([afterBreak, editor, first])

        let sessions = try await store.activitySessions(ActivitySessionQuery(limit: 10))
        #expect(sessions.map(\.id.rawValue) == ["after-break", "research"])
        #expect(sessions[1].frameCount == 2)
        #expect(sessions[1].latestApplicationName == "Xcode")
        #expect(sessions[1].representativeFrameID.rawValue == "editor")
        #expect(sessions[1].resumeTarget.url?.absoluteString == "https://passage.example/page")
        #expect(sessions[1].resumeTarget.restoresExactSource)

        let detail = try #require(await store.activitySession(
            id: ActivitySessionID(rawValue: "research"),
            momentLimit: 10
        ))
        #expect(detail.moments.map(\.id.rawValue) == ["editor", "research"])
        #expect(detail.moments.allSatisfy {
            $0.activitySessionID == ActivitySessionID(rawValue: "research")
        })

        let filtered = try await store.search(SearchQuery(
            text: "Session",
            activitySessionIDs: [ActivitySessionID(rawValue: "research")]
        ))
        #expect(Set(filtered.map(\.id.rawValue)) == ["research", "editor"])
    }

    @Test("An out-of-order insert deterministically rebuilds and bridges sessions")
    func outOfOrderSessionRebuild() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        try await store.insert(Self.frame(
            id: "first",
            date: Date(timeIntervalSince1970: 100),
            app: "Safari",
            bundle: "com.apple.Safari",
            domain: "example.com",
            text: "first"
        ))
        try await store.insert(Self.frame(
            id: "last",
            date: Date(timeIntervalSince1970: 650),
            app: "Notes",
            bundle: "com.apple.Notes",
            domain: nil,
            text: "last"
        ))
        #expect(try await store.activitySessions(ActivitySessionQuery()).count == 2)

        try await store.insert(Self.frame(
            id: "bridge",
            date: Date(timeIntervalSince1970: 380),
            app: "Xcode",
            bundle: "com.apple.dt.Xcode",
            domain: nil,
            text: "bridge"
        ))

        let sessions = try await store.activitySessions(ActivitySessionQuery())
        #expect(sessions.map(\.id.rawValue) == ["first"])
        #expect(sessions.first?.frameCount == 3)
        let detail = try #require(await store.activitySession(
            id: ActivitySessionID(rawValue: "first"),
            momentLimit: 10
        ))
        #expect(detail.moments.map(\.id.rawValue) == ["last", "bridge", "first"])
    }

    @Test("Deleting a middle range repairs and splits the affected session")
    func activitySessionDeletionRepair() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        for (id, time) in [("head", 100.0), ("middle", 250.0), ("tail", 500.0)] {
            try await store.insert(Self.frame(
                id: id,
                date: Date(timeIntervalSince1970: time),
                app: "Notes",
                bundle: "com.apple.Notes",
                domain: nil,
                text: id
            ))
        }
        #expect(try await store.activitySessions(ActivitySessionQuery()).count == 1)

        _ = try await store.deleteFrames(
            from: Date(timeIntervalSince1970: 250),
            through: Date(timeIntervalSince1970: 250)
        )
        let repaired = try await store.activitySessions(ActivitySessionQuery(limit: 10))
        #expect(repaired.map(\.id.rawValue) == ["tail", "head"])
        #expect(repaired.allSatisfy { $0.frameCount == 1 })

        _ = try await store.deleteOldestFrames(limit: 1)
        let remaining = try await store.activitySessions(ActivitySessionQuery(limit: 10))
        #expect(remaining.map(\.id.rawValue) == ["tail"])
    }

    @Test("Media expiry moves a session preview to a surviving visual")
    func activitySessionMediaRepair() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        var strong = Self.frame(
            id: "strong",
            date: Date(timeIntervalSince1970: 100),
            app: "Preview",
            bundle: "com.apple.Preview",
            domain: nil,
            text: "strong visual"
        )
        strong.changeScore = 0.9
        var survivor = Self.frame(
            id: "survivor",
            date: Date(timeIntervalSince1970: 200),
            app: "Preview",
            bundle: "com.apple.Preview",
            domain: nil,
            text: "surviving visual"
        )
        survivor.changeScore = 0.2
        try await store.insertBatch([strong, survivor])
        #expect(try await store.activitySessions(ActivitySessionQuery()).first?.representativeFrameID.rawValue == "strong")

        _ = try await store.expireOldestMedia(limit: 1)
        let repaired = try #require(await store.activitySessions(ActivitySessionQuery()).first)
        #expect(repaired.representativeFrameID.rawValue == "survivor")
        #expect(repaired.representativeThumbnailRelativePath == "Thumbnails/survivor.jpg")
    }

    @Test("Sensitive and unsafe resume metadata fail closed")
    func activitySessionDisclosureSafety() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        var visible = Self.frame(
            id: "visible-session",
            date: Date(timeIntervalSince1970: 100),
            app: "Finder",
            bundle: "com.apple.finder",
            domain: nil,
            text: "ordinary context"
        )
        visible.context.url = URL(fileURLWithPath: "/private/tmp/private-document")
        let sensitive = Self.frame(
            id: "sensitive-session",
            date: Date(timeIntervalSince1970: 150),
            app: "Finder",
            bundle: "com.apple.finder",
            domain: nil,
            text: "sensitive context",
            isSensitive: true
        )
        try await store.insertBatch([visible, sensitive])

        let privateSessions = try await store.activitySessions(ActivitySessionQuery(includeSensitive: true))
        #expect(privateSessions.count == 1)
        #expect(privateSessions[0].containsSensitive)
        #expect(privateSessions[0].resumeTarget.url == nil)
        #expect(privateSessions[0].resumeTarget.bundleIdentifier == "com.apple.finder")
        #expect(try await store.activitySessions(ActivitySessionQuery(includeSensitive: false)).isEmpty)
    }

    @Test("Sensitive context survives persistence and is excluded from agent bundles")
    func sensitiveContextPersistence() async throws {
        let fixture = try StoreFixture()
        do {
            let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
            try await store.insertBatch([
                Self.frame(
                    id: "sensitive",
                    date: Date(timeIntervalSince1970: 200),
                    app: "Passwords",
                    bundle: "com.apple.Passwords",
                    domain: nil,
                    text: "private payroll budget secret",
                    isSensitive: true
                ),
                Self.frame(
                    id: "visible",
                    date: Date(timeIntervalSince1970: 100),
                    app: "Notes",
                    bundle: "com.apple.Notes",
                    domain: nil,
                    text: "public project budget summary"
                ),
            ])
        }

        let reopened = try SQLiteFrameStore(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey,
            readOnly: true
        )
        #expect(try await reopened.frame(id: FrameID(rawValue: "sensitive"))?.context.isSensitive == true)
        #expect(try await reopened.frame(id: FrameID(rawValue: "visible"))?.context.isSensitive == false)

        let unfiltered = try await reopened.search(SearchQuery(text: "budget", limit: 10))
        let sensitivityByID = Dictionary(
            uniqueKeysWithValues: unfiltered.map { ($0.id.rawValue, $0.context.isSensitive) }
        )
        #expect(sensitivityByID == ["sensitive": true, "visible": false])

        let filtered = try await reopened.search(SearchQuery(
            text: "secret",
            applicationBundleIdentifiers: ["com.apple.Passwords"],
            limit: 10
        ))
        #expect(filtered.map(\.id.rawValue) == ["sensitive"])
        #expect(filtered.first?.context.isSensitive == true)

        let recent = try await reopened.recent(limit: 10)
        #expect(recent.first { $0.id.rawValue == "sensitive" }?.context.isSensitive == true)

        let bundle = try PassageContextBundleBuilder.build(
            request: PassageContextBundleRequest(
                query: SearchQuery(text: "budget"),
                resultLimit: 10,
                utf8ByteBudget: 4_096
            ),
            hits: unfiltered
        )
        #expect(bundle.matchedCount == 2)
        #expect(bundle.sources.map(\.frameID.rawValue) == ["visible"])
        #expect(bundle.truncated)
    }

    @Test("Agent-safe reads filter sensitive rows before bounded result selection")
    func agentSafeReadsFilterBeforeLimit() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let sharedBundle = "com.example.Shared"
        try await store.insertBatch([
            Self.frame(
                id: "private-one",
                date: Date(timeIntervalSince1970: 1_200),
                app: "Passwords",
                bundle: sharedBundle,
                domain: nil,
                text: "amberglass",
                isSensitive: true
            ),
            Self.frame(
                id: "private-two",
                date: Date(timeIntervalSince1970: 1_100),
                app: "Passwords",
                bundle: sharedBundle,
                domain: nil,
                text: "amberglass",
                isSensitive: true
            ),
            Self.frame(
                id: "ordinary-in-private-session",
                date: Date(timeIntervalSince1970: 1_000),
                app: "Notes",
                bundle: sharedBundle,
                domain: nil,
                text: "amberglass"
            ),
            Self.frame(
                id: "visible-newer",
                date: Date(timeIntervalSince1970: 600),
                app: "Notes",
                bundle: sharedBundle,
                domain: nil,
                text: "ordinary retained team notes mentioning amberglass with public context"
            ),
            Self.frame(
                id: "visible-older",
                date: Date(timeIntervalSince1970: 500),
                app: "Notes",
                bundle: sharedBundle,
                domain: nil,
                text: "another ordinary public project summary about amberglass and its timeline"
            ),
        ])

        // The three best lexical matches and newest rows all belong to the
        // sensitive session. One row is ordinary by itself, but the whole
        // session must remain undisclosed and must not consume the safe limit.
        let lexicalPrefix = try await store.search(SearchQuery(text: "amberglass", limit: 3))
        #expect(lexicalPrefix.count == 3)
        #expect(Set(lexicalPrefix.map(\.id.rawValue)) == [
            "private-one", "private-two", "ordinary-in-private-session",
        ])
        #expect(try await store.recent(limit: 3).map(\.id.rawValue) == [
            "private-one", "private-two", "ordinary-in-private-session",
        ])

        let safeLexical = try await store.search(
            SearchQuery(text: "amberglass", limit: 2),
            includeSensitive: false
        )
        #expect(safeLexical.count == 2)
        #expect(Set(safeLexical.map(\.id.rawValue)) == ["visible-newer", "visible-older"])
        #expect(safeLexical.allSatisfy { !$0.context.isSensitive })

        let safeFilteredLexical = try await store.search(
            SearchQuery(
                text: "amberglass",
                applicationBundleIdentifiers: [sharedBundle],
                limit: 2
            ),
            includeSensitive: false
        )
        #expect(Set(safeFilteredLexical.map(\.id.rawValue)) == ["visible-newer", "visible-older"])
        #expect(safeFilteredLexical.allSatisfy { !$0.context.isSensitive })

        let safeEmptySearch = try await store.search(
            SearchQuery(limit: 2),
            includeSensitive: false
        )
        #expect(safeEmptySearch.map(\.id.rawValue) == ["visible-newer", "visible-older"])
        #expect(try await store.recent(limit: 2, includeSensitive: false).map(\.id.rawValue)
            == ["visible-newer", "visible-older"])

        #expect(try await store.frame(
            id: FrameID(rawValue: "private-one"),
            includeSensitive: false
        ) == nil)
        #expect(try await store.frame(
            id: FrameID(rawValue: "ordinary-in-private-session"),
            includeSensitive: false
        ) == nil)
        #expect(try await store.agentSafeFrame(
            id: FrameID(rawValue: "ordinary-in-private-session")
        ) == nil)
        #expect(try await store.frame(
            id: FrameID(rawValue: "ordinary-in-private-session")
        )?.id.rawValue == "ordinary-in-private-session")

        let initialEvidence = try #require(await store.agentSafeFrame(
            id: FrameID(rawValue: "visible-newer")
        ))
        #expect(initialEvidence.frame.id.rawValue == "visible-newer")
        #expect(initialEvidence.activitySessionID.rawValue == "visible-older")

        // An out-of-order insert repartitions sessions. The safe resolver must
        // return the current database membership, not a previously cached ID.
        try await store.insert(Self.frame(
            id: "visible-earliest",
            date: Date(timeIntervalSince1970: 450),
            app: "Notes",
            bundle: sharedBundle,
            domain: nil,
            text: "earliest ordinary amberglass project note"
        ))
        let currentEvidence = try #require(await store.agentSafeFrame(
            id: FrameID(rawValue: "visible-newer")
        ))
        #expect(currentEvidence.activitySessionID.rawValue == "visible-earliest")
        #expect(try await store.frame(
            id: FrameID(rawValue: "visible-newer"),
            includeSensitive: false
        )?.id.rawValue == "visible-newer")
    }

    @Test("Recent frames, detail decoding, statistics, and retention agree")
    func lifecycle() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let old = Self.frame(id: "old", date: Date(timeIntervalSince1970: 100), app: "Notes", bundle: nil, domain: nil, text: "old note")
        let new = Self.frame(id: "new", date: Date(timeIntervalSince1970: 300), app: "Mail", bundle: nil, domain: nil, text: "new message")
        try await store.insert(old)
        try await store.insert(new)

        let recent = try await store.recent(limit: 10)
        #expect(recent.map(\.id.rawValue) == ["new", "old"])
        let decoded = try await store.frame(id: FrameID(rawValue: "new"))
        #expect(decoded?.ocrText == "new message")
        #expect(decoded?.ocrRegions.map(\.text) == new.ocrRegions.map(\.text))
        #expect(decoded?.visualFingerprint == new.visualFingerprint)
        #expect(decoded?.context.displayID == 7)
        #expect(decoded?.context.windowID == 42)
        #expect(decoded?.context.windowBounds == ScreenRect(x: 12, y: 24, width: 900, height: 640))
        #expect(recent.first?.context.windowID == 42)

        var stats = try await store.statistics()
        #expect(stats.frameCount == 2)
        let paths = try await store.deleteFrames(olderThan: Date(timeIntervalSince1970: 200))
        #expect(paths.contains("Media/old.jpg"))
        stats = try await store.statistics()
        #expect(stats.frameCount == 1)
        #expect(try await store.frame(id: FrameID(rawValue: "old")) == nil)

        let remainingPaths = try await store.deleteFrames(from: nil, through: nil)
        #expect(remainingPaths.contains("Media/new.jpg"))
        #expect(try await store.statistics().frameCount == 0)
    }

    @Test("Statistics media bytes are cached between measurements and refreshed after media-releasing deletes")
    func statisticsMediaByteCache() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let frame = Self.frame(
            id: "cached",
            date: Date(timeIntervalSince1970: 100),
            app: "Notes",
            bundle: nil,
            domain: nil,
            text: "cached media bytes"
        )
        try await store.insert(frame)
        let referencedMedia = fixture.paths.media.appendingPathComponent("cached.jpg")
        try Data(repeating: 0xAB, count: 1_024).write(to: referencedMedia)

        let populated = try await store.statistics()
        #expect(populated.frameCount == 1)
        #expect(populated.oldestCapture == Date(timeIntervalSince1970: 100))
        #expect(populated.newestCapture == Date(timeIntervalSince1970: 100))
        #expect(populated.mediaBytes == 1_024)

        // Growth is allowed to read from the cache within its lifetime; only
        // media-releasing operations must force a fresh measurement.
        let unreferencedMedia = fixture.paths.media.appendingPathComponent("unreferenced.jpg")
        try Data(repeating: 0xCD, count: 2_048).write(to: unreferencedMedia)
        #expect(try await store.statistics().mediaBytes == 1_024)

        let orphaned = try await store.deleteFrames(olderThan: Date(timeIntervalSince1970: 200))
        #expect(orphaned.contains("Media/cached.jpg"))
        try FileManager.default.removeItem(at: referencedMedia)

        let emptied = try await store.statistics()
        #expect(emptied.frameCount == 0)
        #expect(emptied.oldestCapture == nil)
        #expect(emptied.newestCapture == nil)
        #expect(emptied.mediaBytes == 2_048)
    }

    @Test("Retention unlinks shared media only after its final reference disappears")
    func sharedMediaRetention() async throws {
        let sharedImage = "Media/v2/aa/shared.bin"
        let sharedThumbnail = "Thumbnails/v2/bb/shared.bin"
        let expectedPaths = Set([sharedImage, sharedThumbnail])

        func frames() -> [FrameDocument] {
            var first = Self.frame(
                id: "first-shared",
                date: Date(timeIntervalSince1970: 100),
                app: "Notes",
                bundle: "com.apple.Notes",
                domain: nil,
                text: "first shared reference"
            )
            first.imageRelativePath = sharedImage
            first.thumbnailRelativePath = sharedThumbnail
            var second = Self.frame(
                id: "second-shared",
                date: Date(timeIntervalSince1970: 300),
                app: "Notes",
                bundle: "com.apple.Notes",
                domain: nil,
                text: "second shared reference"
            )
            second.imageRelativePath = sharedImage
            second.thumbnailRelativePath = sharedThumbnail
            return [first, second]
        }

        do {
            let fixture = try StoreFixture()
            let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
            try await store.insertBatch(frames())
            #expect(try await store.deleteFrames(
                olderThan: Date(timeIntervalSince1970: 200)
            ).isEmpty)
            let finalPaths = try await store.deleteFrames(
                olderThan: Date(timeIntervalSince1970: 400)
            )
            #expect(Set(finalPaths) == expectedPaths)
            #expect(finalPaths.count == expectedPaths.count)
        }

        do {
            let fixture = try StoreFixture()
            let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
            try await store.insertBatch(frames())
            #expect(try await store.deleteFrames(
                from: nil,
                through: Date(timeIntervalSince1970: 200)
            ).isEmpty)
            let finalPaths = try await store.deleteFrames(from: nil, through: nil)
            #expect(Set(finalPaths) == expectedPaths)
            #expect(finalPaths.count == expectedPaths.count)
        }

        do {
            let fixture = try StoreFixture()
            let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
            try await store.insertBatch(frames())
            #expect(try await store.deleteOldestFrames(limit: 1).isEmpty)
            let finalPaths = try await store.deleteOldestFrames(limit: 1)
            #expect(Set(finalPaths) == expectedPaths)
            #expect(finalPaths.count == expectedPaths.count)
        }

        do {
            let fixture = try StoreFixture()
            let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
            try await store.insertBatch(frames())
            #expect(try await store.expireOldestMedia(limit: 1).isEmpty)
            let survivor = try #require(await store.frame(id: FrameID(rawValue: "second-shared")))
            #expect(survivor.imageRelativePath == sharedImage)
            #expect(survivor.thumbnailRelativePath == sharedThumbnail)
            let finalPaths = try await store.expireOldestMedia(limit: 1)
            #expect(Set(finalPaths) == expectedPaths)
            #expect(finalPaths.count == expectedPaths.count)
        }
    }

    @Test("Storage pressure removes the oldest bounded batch first")
    func oldestBatch() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        for (id, time) in [("first", 100.0), ("second", 200.0), ("third", 300.0)] {
            try await store.insert(Self.frame(
                id: id,
                date: Date(timeIntervalSince1970: time),
                app: "Notes",
                bundle: nil,
                domain: nil,
                text: id
            ))
        }

        let deletedPaths = try await store.deleteOldestFrames(limit: 2)
        #expect(deletedPaths.contains("Media/first.jpg"))
        #expect(deletedPaths.contains("Media/second.jpg"))
        #expect(!deletedPaths.contains("Media/third.jpg"))
        #expect(try await store.recent(limit: 10).map(\.id.rawValue) == ["third"])
    }

    @Test("Media expiry preserves searchable evidence and expires oldest visuals first")
    func mediaExpiry() async throws {
        let fixture = try StoreFixture()
        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        for (id, time) in [("first", 100.0), ("second", 200.0), ("third", 300.0)] {
            try await store.insert(Self.frame(
                id: id,
                date: Date(timeIntervalSince1970: time),
                app: "Notes",
                bundle: nil,
                domain: nil,
                text: "searchable \(id) evidence"
            ))
        }

        let expiredPaths = try await store.expireOldestMedia(limit: 2)
        #expect(expiredPaths.contains("Media/first.jpg"))
        #expect(expiredPaths.contains("Media/second.jpg"))
        #expect(!expiredPaths.contains("Media/third.jpg"))
        #expect(try await store.statistics().frameCount == 3)
        #expect(try await store.search(SearchQuery(text: "searchable")).count == 3)
        #expect(try await store.frame(id: FrameID(rawValue: "first"))?.imageRelativePath == "")
        #expect(try await store.frame(id: FrameID(rawValue: "third"))?.imageRelativePath == "Media/third.jpg")
    }

    @Test("The index has an encrypted header, a verified cipher, and rejects a wrong key")
    func encryptionBoundary() async throws {
        let fixture = try StoreFixture()
        do {
            let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
            #expect(!store.encryptionStatus.cipherVersion.isEmpty)
            #expect(store.encryptionStatus.cipherStatus == "1")
            try await store.insert(Self.frame(
                id: "encrypted",
                date: Date(timeIntervalSince1970: 400),
                app: "Preview",
                bundle: "com.apple.Preview",
                domain: nil,
                text: "This text must never appear in a plaintext SQLite page"
            ))
            for suffix in ["-wal", "-shm"] {
                let sidecarPath = fixture.paths.database.path + suffix
                if FileManager.default.fileExists(atPath: sidecarPath) {
                    let attributes = try FileManager.default.attributesOfItem(atPath: sidecarPath)
                    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
                }
            }
        }

        let header = try Data(contentsOf: fixture.paths.database).prefix(16)
        #expect(header != Data("SQLite format 3\0".utf8))
        #expect(header.count == 16)

        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.paths.database.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: fixture.root.path)
        #expect((rootAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let wrongKey = try VaultKey.testing(bytes: Data(repeating: 0x99, count: VaultKey.byteCount))
        #expect(throws: (any Error).self) {
            _ = try SQLiteFrameStore(paths: fixture.paths, vaultKey: wrongKey, readOnly: true)
        }
        let correctlyReopened = try SQLiteFrameStore(
            paths: fixture.paths,
            vaultKey: fixture.vaultKey,
            readOnly: true
        )
        #expect(try await correctlyReopened.frame(id: FrameID(rawValue: "encrypted"))?.ocrText.hasPrefix("This text") == true)
    }

    @Test("Vault subkeys are deterministic and separated by purpose and object context")
    func subkeySeparation() throws {
        let vaultKey = try VaultKey.testing(bytes: Data(repeating: 0x44, count: VaultKey.byteCount))
        let databaseKey = vaultKey.withDerivedKeyBytes(for: .databaseIndex) { Data($0) }
        let repeatedDatabaseKey = vaultKey.withDerivedKeyBytes(for: .databaseIndex) { Data($0) }
        let frameA = vaultKey.withDerivedKeyBytes(for: .frameMedia, context: "frame-a") { Data($0) }
        let frameB = vaultKey.withDerivedKeyBytes(for: .frameMedia, context: "frame-b") { Data($0) }
        let preferences = vaultKey.withDerivedKeyBytes(for: .privacyPreferences) { Data($0) }

        #expect(databaseKey.count == 32)
        #expect(databaseKey == repeatedDatabaseKey)
        #expect(databaseKey != frameA)
        #expect(frameA != frameB)
        #expect(preferences != frameA)
    }

    @Test("A legacy plaintext index is validated, backed up, and atomically encrypted")
    func plaintextMigration() async throws {
        let fixture = try StoreFixture()
        let legacyRegions = try Self.createLegacyPlaintextDatabase(at: fixture.paths.database)

        #expect(throws: EncryptedStoreError.self) {
            _ = try SQLiteFrameStore(
                paths: fixture.paths,
                vaultKey: fixture.vaultKey,
                readOnly: true
            )
        }

        let store = try SQLiteFrameStore(paths: fixture.paths, vaultKey: fixture.vaultKey)
        let migratedFrame = try await store.frame(id: FrameID(rawValue: "legacy"))
        #expect(migratedFrame?.ocrText == "legacy plaintext frame")
        #expect(migratedFrame?.ocrRegions == legacyRegions)
        #expect(migratedFrame?.context.isSensitive == false)
        #expect(try await store.recent(limit: 1).first?.context.isSensitive == false)
        let sessions = try await store.activitySessions(ActivitySessionQuery())
        #expect(sessions.map(\.id.rawValue) == ["legacy"])
        #expect(sessions.first?.frameCount == 1)

        let encryptedHeader = try Data(contentsOf: fixture.paths.database).prefix(16)
        #expect(encryptedHeader != Data("SQLite format 3\0".utf8))

        let recoveryArtifacts = try FileManager.default.contentsOfDirectory(
            at: fixture.root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("chronicle-plaintext-backup-") }
        #expect(recoveryArtifacts.isEmpty)
    }

    private static func createLegacyPlaintextDatabase(at url: URL) throws -> [OCRRegion] {
        let legacyRegions = [
            OCRRegion(
                text: "legacy plaintext frame",
                confidence: 0.82,
                x: 0.1,
                y: 0.8,
                width: 0.5,
                height: 0.1
            ),
        ]
        let regionHex = try JSONEncoder().encode(legacyRegions)
            .map { String(format: "%02X", $0) }
            .joined()
        let schema = """
            CREATE TABLE frames (
                id TEXT PRIMARY KEY NOT NULL,
                captured_at REAL NOT NULL,
                application_name TEXT NOT NULL,
                bundle_identifier TEXT,
                window_title TEXT,
                url TEXT,
                domain TEXT,
                ocr_text TEXT NOT NULL,
                ocr_regions BLOB NOT NULL,
                image_path TEXT NOT NULL,
                thumbnail_path TEXT,
                pixel_width INTEGER NOT NULL,
                pixel_height INTEGER NOT NULL,
                visual_fingerprint INTEGER NOT NULL,
                change_score REAL NOT NULL
            );
            INSERT INTO frames VALUES (
                'legacy', 123, 'Notes', 'com.apple.Notes', 'Old note', NULL, NULL,
                'legacy plaintext frame', X'\(regionHex)', 'Media/legacy.jpg', NULL,
                800, 600, 42, 0.5
            );
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [url.path, schema]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
            throw NSError(
                domain: "PassageStoreTests.LegacySQLite",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)]
            )
        }
        return legacyRegions
    }

    private static func assertQuantizedRegions(
        _ actual: [OCRRegion],
        approximatelyEqualTo expected: [OCRRegion]
    ) {
        let tolerance = 1.0 / Double(UInt16.max)
        #expect(actual.count == expected.count)
        for (actualRegion, expectedRegion) in zip(actual, expected) {
            #expect(abs(Double(actualRegion.confidence - expectedRegion.confidence)) <= tolerance)
            #expect(abs(actualRegion.x - expectedRegion.x) <= tolerance)
            #expect(abs(actualRegion.y - expectedRegion.y) <= tolerance)
            #expect(abs(actualRegion.width - expectedRegion.width) <= tolerance)
            #expect(abs(actualRegion.height - expectedRegion.height) <= tolerance)
        }
    }

    private static func frame(
        id: String,
        date: Date,
        app: String,
        bundle: String?,
        domain: String?,
        text: String,
        isSensitive: Bool = false
    ) -> FrameDocument {
        FrameDocument(
            id: FrameID(rawValue: id),
            capturedAt: date,
            context: ScreenContext(
                applicationName: app,
                bundleIdentifier: bundle,
                windowTitle: "\(app) window",
                url: domain.flatMap { URL(string: "https://\($0)/page") },
                domain: domain,
                displayID: 7,
                windowID: 42,
                windowBounds: ScreenRect(x: 12, y: 24, width: 900, height: 640),
                isSensitive: isSensitive
            ),
            ocrText: text,
            ocrRegions: [OCRRegion(text: text, confidence: 0.99, x: 0, y: 0, width: 1, height: 1)],
            imageRelativePath: "Media/\(id).jpg",
            thumbnailRelativePath: "Thumbnails/\(id).jpg",
            pixelWidth: 1280,
            pixelHeight: 720,
            visualFingerprint: UInt64(id.hashValue.magnitude),
            changeScore: 0.5
        )
    }
}

private final class StoreFixture {
    let root: URL
    let paths: PassagePaths
    let vaultKey: VaultKey

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-tests-\(UUID().uuidString)", isDirectory: true)
        paths = PassagePaths(root: root)
        vaultKey = try VaultKey.testing(bytes: Data(repeating: 0x31, count: VaultKey.byteCount))
        try paths.createDirectories()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}
