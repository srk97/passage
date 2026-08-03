import PassageCore
import PassageStore
import Foundation

@main
enum PassageBenchmark {
    static func main() async throws {
        // Usage: passage-benchmark [frame-count] [sample-count]
        let arguments = Array(CommandLine.arguments.dropFirst())
        let count = arguments.first.flatMap(Int.init) ?? 100_000
        let requestedSampleCount = arguments.dropFirst().first.flatMap(Int.init) ?? 100
        let sampleCount = min(max(requestedSampleCount, 1), 10_000)
        let coldSampleCount = min(sampleCount, 10)
        let recallFacetLimit = 40
        let contextBundleResultLimit = PassageContextBundleSchema.defaultResultLimit
        let contextBundleByteBudget = PassageContextBundleSchema.defaultUTF8ByteBudget
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("passage-benchmark-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PassagePaths(root: root)
        let vaultKey = try VaultKey.testing(bytes: Data(repeating: 0xa5, count: 32))
        let store = try SQLiteFrameStore(paths: paths, vaultKey: vaultKey)

        let seedStarted = DispatchTime.now().uptimeNanoseconds
        let batchSize = 5_000
        for start in stride(from: 0, to: count, by: batchSize) {
            let end = min(start + batchSize, count)
            let frames = (start..<end).map(Self.frame)
            try await store.insertBatch(frames)
        }
        let seedMilliseconds = milliseconds(since: seedStarted)
        let regionStorage = try regionStorageMetrics(frameCount: count)

        let queries = [
            "northstar checkout",
            "walnut desk",
            "adaptive capture",
            "design review",
            "project handoff"
        ]
        for query in queries {
            _ = try await store.search(SearchQuery(text: query, limit: 50))
        }
        let conversationalQueries = [
            "where I left the northstar checkout",
            "show me the walnut desk",
            "take me back to adaptive capture",
            "what was I working on design review",
            "resume project handoff",
        ]
        for query in conversationalQueries {
            _ = try await conversationalSearch(query, store: store)
        }

        var warmSamples: [Double] = []
        for index in 0..<sampleCount {
            let started = DispatchTime.now().uptimeNanoseconds
            let hits = try await store.search(SearchQuery(text: queries[index % queries.count], limit: 50))
            precondition(!hits.isEmpty)
            warmSamples.append(milliseconds(since: started))
        }

        var coldSamples: [Double] = []
        for index in 0..<coldSampleCount {
            let coldStore = try SQLiteFrameStore(paths: paths, vaultKey: vaultKey, readOnly: true)
            let started = DispatchTime.now().uptimeNanoseconds
            let hits = try await coldStore.search(SearchQuery(text: queries[index % queries.count], limit: 50))
            precondition(!hits.isEmpty)
            coldSamples.append(milliseconds(since: started))
        }

        var rescueSamples: [Double] = []
        for index in 0..<sampleCount {
            let started = DispatchTime.now().uptimeNanoseconds
            let hits = try await conversationalSearch(
                conversationalQueries[index % conversationalQueries.count],
                store: store
            )
            precondition(!hits.isEmpty)
            rescueSamples.append(milliseconds(since: started))
        }

        var zeroHitSamples: [Double] = []
        for index in 0..<sampleCount {
            let started = DispatchTime.now().uptimeNanoseconds
            let hits = try await store.search(SearchQuery(
                text: "absent-term-\(index)-passage",
                limit: 50
            ))
            precondition(hits.isEmpty)
            zeroHitSamples.append(milliseconds(since: started))
        }

        let scopedRecallScopes = (0..<queries.count).map { index in
            RecallScope(
                applicationBundleIdentifiers: ["app.fixture.\(index)"],
                domains: ["example\(index).com"]
            )
        }
        let textMetadataRecallScopes = queries.enumerated().map { index, query in
            RecallScope(
                text: query,
                applicationBundleIdentifiers: ["app.fixture.\(index)"],
                domains: ["example\(index).com"]
            )
        }
        let browseScope = RecallScope()
        _ = try await store.recall(browseScope, after: nil, limit: 60)
        _ = try await store.recallFacets(browseScope, limitPerKind: recallFacetLimit)
        for scope in scopedRecallScopes + textMetadataRecallScopes {
            let page = try await store.recall(scope, after: nil, limit: 60)
            precondition(!page.hits.isEmpty)
        }
        for scope in textMetadataRecallScopes {
            let facets = try await store.recallFacets(scope, limitPerKind: recallFacetLimit)
            precondition(!facets.applications.isEmpty)
            precondition(!facets.domains.isEmpty)
        }

        var recallBrowseSamples: [Double] = []
        var recallBrowseFacetSamples: [Double] = []
        var recallBrowsePresentationSamples: [Double] = []
        var recallScopedSamples: [Double] = []
        var recallTextMetadataSamples: [Double] = []
        var recallTextMetadataFacetSamples: [Double] = []
        var recallTextMetadataPresentationSamples: [Double] = []
        for index in 0..<sampleCount {
            var started = DispatchTime.now().uptimeNanoseconds
            let browsePage = try await store.recall(browseScope, after: nil, limit: 60)
            let browsePageCompleted = DispatchTime.now().uptimeNanoseconds
            let browseFacetsStarted = DispatchTime.now().uptimeNanoseconds
            let browseFacets = try await store.recallFacets(
                browseScope,
                limitPerKind: recallFacetLimit
            )
            let browsePresentationCompleted = DispatchTime.now().uptimeNanoseconds
            precondition(!browsePage.hits.isEmpty)
            precondition(!browseFacets.applications.isEmpty)
            precondition(!browseFacets.domains.isEmpty)
            recallBrowseSamples.append(milliseconds(from: started, to: browsePageCompleted))
            recallBrowseFacetSamples.append(milliseconds(
                from: browseFacetsStarted,
                to: browsePresentationCompleted
            ))
            recallBrowsePresentationSamples.append(milliseconds(
                from: started,
                to: browsePresentationCompleted
            ))

            started = DispatchTime.now().uptimeNanoseconds
            let scopedPage = try await store.recall(
                scopedRecallScopes[index % scopedRecallScopes.count],
                after: nil,
                limit: 60
            )
            precondition(!scopedPage.hits.isEmpty)
            recallScopedSamples.append(milliseconds(since: started))

            started = DispatchTime.now().uptimeNanoseconds
            let textMetadataPage = try await store.recall(
                textMetadataRecallScopes[index % textMetadataRecallScopes.count],
                after: nil,
                limit: 60
            )
            let textMetadataPageCompleted = DispatchTime.now().uptimeNanoseconds
            let textMetadataFacetsStarted = DispatchTime.now().uptimeNanoseconds
            let textMetadataFacets = try await store.recallFacets(
                textMetadataRecallScopes[index % textMetadataRecallScopes.count],
                limitPerKind: recallFacetLimit
            )
            let textMetadataPresentationCompleted = DispatchTime.now().uptimeNanoseconds
            precondition(!textMetadataPage.hits.isEmpty)
            precondition(!textMetadataFacets.applications.isEmpty)
            precondition(!textMetadataFacets.domains.isEmpty)
            recallTextMetadataSamples.append(milliseconds(
                from: started,
                to: textMetadataPageCompleted
            ))
            recallTextMetadataFacetSamples.append(milliseconds(
                from: textMetadataFacetsStarted,
                to: textMetadataPresentationCompleted
            ))
            recallTextMetadataPresentationSamples.append(milliseconds(
                from: started,
                to: textMetadataPresentationCompleted
            ))
        }
        let cursorWalk = try await verifyRecallCursorWalk(store: store)

        for index in queries.indices {
            _ = try await buildContextBundle(
                scope: textMetadataRecallScopes[index],
                store: store
            )
        }
        var contextBundleSamples: [Double] = []
        var contextBundleEncodedBytes: [Double] = []
        for index in 0..<sampleCount {
            let started = DispatchTime.now().uptimeNanoseconds
            let manifest = try await buildContextBundle(
                scope: textMetadataRecallScopes[index % textMetadataRecallScopes.count],
                store: store
            )
            let completed = DispatchTime.now().uptimeNanoseconds
            precondition(manifest.disclosedCount > 0)
            precondition(manifest.encodedUTF8Bytes <= manifest.utf8ByteBudget)
            contextBundleSamples.append(milliseconds(from: started, to: completed))
            contextBundleEncodedBytes.append(Double(manifest.encodedUTF8Bytes))
        }

        let statistics = try await store.statistics()
        print("benchmark_output_schema=2")
        print("frames=\(statistics.frameCount)")
        print("sample_count=\(sampleCount)")
        print("cold_sample_count=\(coldSampleCount)")
        print("recall_facets_limit_per_kind=\(recallFacetLimit)")
        print("context_bundle_result_limit=\(contextBundleResultLimit)")
        print("context_bundle_utf8_byte_budget=\(contextBundleByteBudget)")
        print(String(format: "seed_ms=%.2f", seedMilliseconds))
        print(String(format: "warm_p50_ms=%.2f", percentile(warmSamples, 0.50)))
        print(String(format: "warm_p95_ms=%.2f", percentile(warmSamples, 0.95)))
        print(String(format: "cold_p50_ms=%.2f", percentile(coldSamples, 0.50)))
        print(String(format: "cold_p95_ms=%.2f", percentile(coldSamples, 0.95)))
        print(String(format: "rescue_warm_p50_ms=%.2f", percentile(rescueSamples, 0.50)))
        print(String(format: "rescue_warm_p95_ms=%.2f", percentile(rescueSamples, 0.95)))
        print(String(format: "zero_hit_warm_p50_ms=%.2f", percentile(zeroHitSamples, 0.50)))
        print(String(format: "zero_hit_warm_p95_ms=%.2f", percentile(zeroHitSamples, 0.95)))
        print(String(
            format: "recall_browse_first_page_p50_ms=%.2f",
            percentile(recallBrowseSamples, 0.50)
        ))
        print(String(
            format: "recall_browse_first_page_p95_ms=%.2f",
            percentile(recallBrowseSamples, 0.95)
        ))
        print(String(
            format: "recall_browse_facets_p50_ms=%.2f",
            percentile(recallBrowseFacetSamples, 0.50)
        ))
        print(String(
            format: "recall_browse_facets_p95_ms=%.2f",
            percentile(recallBrowseFacetSamples, 0.95)
        ))
        print(String(
            format: "recall_browse_page_then_facets_p50_ms=%.2f",
            percentile(recallBrowsePresentationSamples, 0.50)
        ))
        print(String(
            format: "recall_browse_page_then_facets_p95_ms=%.2f",
            percentile(recallBrowsePresentationSamples, 0.95)
        ))
        print(String(
            format: "recall_app_domain_p50_ms=%.2f",
            percentile(recallScopedSamples, 0.50)
        ))
        print(String(
            format: "recall_app_domain_p95_ms=%.2f",
            percentile(recallScopedSamples, 0.95)
        ))
        print(String(
            format: "recall_text_metadata_p50_ms=%.2f",
            percentile(recallTextMetadataSamples, 0.50)
        ))
        print(String(
            format: "recall_text_metadata_p95_ms=%.2f",
            percentile(recallTextMetadataSamples, 0.95)
        ))
        print(String(
            format: "recall_text_metadata_facets_p50_ms=%.2f",
            percentile(recallTextMetadataFacetSamples, 0.50)
        ))
        print(String(
            format: "recall_text_metadata_facets_p95_ms=%.2f",
            percentile(recallTextMetadataFacetSamples, 0.95)
        ))
        print(String(
            format: "recall_text_metadata_page_then_facets_p50_ms=%.2f",
            percentile(recallTextMetadataPresentationSamples, 0.50)
        ))
        print(String(
            format: "recall_text_metadata_page_then_facets_p95_ms=%.2f",
            percentile(recallTextMetadataPresentationSamples, 0.95)
        ))
        print(String(
            format: "context_bundle_search_build_p50_ms=%.2f",
            percentile(contextBundleSamples, 0.50)
        ))
        print(String(
            format: "context_bundle_search_build_p95_ms=%.2f",
            percentile(contextBundleSamples, 0.95)
        ))
        print(String(
            format: "context_bundle_encoded_bytes_p50=%.0f",
            percentile(contextBundleEncodedBytes, 0.50)
        ))
        print(String(
            format: "context_bundle_encoded_bytes_p95=%.0f",
            percentile(contextBundleEncodedBytes, 0.95)
        ))
        print("recall_cursor_walk_pages=\(cursorWalk.pages)")
        print("recall_cursor_walk_hits=\(cursorWalk.hits)")
        print("recall_cursor_walk_invariant=ok")
        print("database_bytes=\(statistics.databaseBytes)")
        print("ocr_region_binary_bytes=\(regionStorage.binaryBytes)")
        print("ocr_region_legacy_json_bytes=\(regionStorage.legacyJSONBytes)")
        print(String(
            format: "ocr_region_binary_bytes_per_frame=%.2f",
            Double(regionStorage.binaryBytes) / Double(count)
        ))
        print(String(
            format: "ocr_region_legacy_json_bytes_per_frame=%.2f",
            Double(regionStorage.legacyJSONBytes) / Double(count)
        ))
        print(String(
            format: "ocr_region_size_savings_percent=%.2f",
            100 * (1 - Double(regionStorage.binaryBytes) / Double(regionStorage.legacyJSONBytes))
        ))
    }

    private static func frame(_ index: Int) -> FrameDocument {
        let phrases = [
            "Northstar checkout design review and interaction notes",
            "Solid walnut desk product comparison and dimensions",
            "Adaptive capture performance profiling and frame changes",
            "Design review follow-up with typography and color decisions",
            "Project handoff checklist with source evidence and owner"
        ]
        let appIndex = index % 20
        let capturedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 2))
        let lines = [
            phrases[index % phrases.count],
            "Iteration \(index)",
            "Owner \(index % 50)",
            "Review status complete",
            "Application \(appIndex)",
            "Domain example\(index % 30).com",
        ]
        let ocrText = lines.joined(separator: "\n")
        let ocrRegions = lines.enumerated().map { lineIndex, line in
            OCRRegion(
                text: line,
                confidence: Float(0.82 + Double(lineIndex) * 0.025),
                x: 0.04,
                y: 0.90 - Double(lineIndex) * 0.10,
                width: min(0.90, 0.12 + Double(line.utf8.count) * 0.006),
                height: 0.055
            )
        }
        return FrameDocument(
            id: FrameID(rawValue: String(format: "frame-%08d", index)),
            capturedAt: capturedAt,
            context: ScreenContext(
                applicationName: "Application \(appIndex)",
                bundleIdentifier: "app.fixture.\(appIndex)",
                windowTitle: "Project \(index % 200) — \(phrases[index % phrases.count])",
                url: URL(string: "https://example\(index % 30).com/item/\(index)"),
                domain: "example\(index % 30).com"
            ),
            ocrText: ocrText,
            ocrRegions: ocrRegions,
            imageRelativePath: "Media/fixture/\(index).jpg",
            thumbnailRelativePath: "Thumbnails/fixture/\(index).jpg",
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            visualFingerprint: UInt64(truncatingIfNeeded: index &* 2_654_435_761),
            changeScore: Double(index % 64) / 64
        )
    }

    private static func conversationalSearch(
        _ text: String,
        store: SQLiteFrameStore
    ) async throws -> [SearchHit] {
        let query = SearchQuery(text: text, limit: 50)
        let strict = try await store.search(query)
        guard strict.isEmpty,
              let interpretation = RecallQueryInterpreter().interpret(text) else {
            return strict
        }
        return try await store.search(interpretation.applying(to: query))
    }

    /// Mirrors PassageCapabilityHandler's bounded search-and-build path while
    /// intentionally excluding IPC and durable audit receipt latency.
    private static func buildContextBundle(
        scope: RecallScope,
        store: SQLiteFrameStore
    ) async throws -> PassageContextBundleManifest {
        let request = PassageContextBundleRequest(
            query: SearchQuery(
                text: scope.text,
                startDate: scope.startDate,
                endDate: scope.endDate,
                applicationBundleIdentifiers: scope.applicationBundleIdentifiers,
                domains: scope.domains,
                limit: PassageContextBundleSchema.defaultResultLimit + 1
            )
        )
        let hits = try await store.search(request.query)
        return try PassageContextBundleBuilder.build(request: request, hits: hits)
    }

    private static func regionStorageMetrics(
        frameCount: Int
    ) throws -> (binaryBytes: Int64, legacyJSONBytes: Int64) {
        let jsonEncoder = JSONEncoder()
        var binaryBytes: Int64 = 0
        var legacyJSONBytes: Int64 = 0
        for index in 0..<frameCount {
            let frame = frame(index)
            binaryBytes += Int64(try OCRRegionCodec.encode(
                frame.ocrRegions,
                canonicalText: frame.ocrText
            ).count)
            legacyJSONBytes += Int64(try jsonEncoder.encode(frame.ocrRegions).count)
        }
        return (binaryBytes, legacyJSONBytes)
    }

    private static func verifyRecallCursorWalk(
        store: SQLiteFrameStore,
        maximumPages: Int = 4,
        pageSize: Int = 31
    ) async throws -> (pages: Int, hits: Int) {
        var cursor: RecallCursor?
        var seenFrameIDs = Set<FrameID>()
        var seenCursorTokens = Set<String>()
        var previousHit: SearchHit?
        var pages = 0

        for _ in 0..<maximumPages {
            let page = try await store.recall(RecallScope(), after: cursor, limit: pageSize)
            pages += 1
            precondition(page.hasMore == (page.nextCursor != nil))
            precondition(page.hits.count <= pageSize)
            precondition(!page.hasMore || page.hits.count == pageSize)

            for hit in page.hits {
                precondition(seenFrameIDs.insert(hit.id).inserted)
                if let previousHit {
                    let isStrictlyOlder = hit.capturedAt < previousHit.capturedAt
                        || (hit.capturedAt == previousHit.capturedAt
                            && hit.id.rawValue < previousHit.id.rawValue)
                    precondition(isStrictlyOlder)
                }
                previousHit = hit
            }

            guard let nextCursor = page.nextCursor else { break }
            precondition(!nextCursor.token.isEmpty)
            precondition(seenCursorTokens.insert(nextCursor.token).inserted)
            cursor = nextCursor
        }

        return (pages: pages, hits: seenFrameIDs.count)
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        Double(end - start) / 1_000_000
    }

    private static func percentile(_ values: [Double], _ percentile: Double) -> Double {
        let sorted = values.sorted()
        let index = min(Int(Double(sorted.count - 1) * percentile), sorted.count - 1)
        return sorted[index]
    }
}
