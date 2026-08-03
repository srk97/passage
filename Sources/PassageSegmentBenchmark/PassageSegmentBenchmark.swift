import PassageCore
import PassageStore
import Foundation

@main
enum PassageSegmentBenchmark {
    private static let maximumFramesPerSegment = 64

    static func main() async {
        do {
            let configuration = try BenchmarkConfiguration.parse(
                Array(CommandLine.arguments.dropFirst())
            )
            let report = try await run(configuration)
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let encoded = try encoder.encode(report)
            var terminated = encoded
            terminated.append(0x0a)
            if let outputPath = configuration.outputPath {
                let output = URL(fileURLWithPath: outputPath).standardizedFileURL
                try FileManager.default.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try terminated.write(to: output, options: .atomic)
            }
            FileHandle.standardOutput.write(terminated)
        } catch BenchmarkArgumentError.helpRequested {
            print(BenchmarkConfiguration.usage)
        } catch {
            let message = "passage-segment-benchmark: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            FileHandle.standardError.write(Data((BenchmarkConfiguration.usage + "\n").utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func run(
        _ configuration: BenchmarkConfiguration
    ) async throws -> MemorySegmentBenchmarkReport {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "passage-segment-benchmark-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = PassagePaths(root: root)
        let key = try VaultKey.testing(bytes: Data(repeating: 0x73, count: VaultKey.byteCount))
        let store = try SQLiteFrameStore(paths: paths, vaultKey: key)
        let corpus = DeterministicSegmentCorpus(
            frameCount: configuration.frameCount,
            framesPerSession: configuration.framesPerSession,
            contextKeyCount: configuration.contextKeyCount
        )

        let seedStarted = DispatchTime.now().uptimeNanoseconds
        var seedBatchSamples = [Double]()
        for start in stride(from: 0, to: configuration.frameCount, by: configuration.batchSize) {
            let end = min(start + configuration.batchSize, configuration.frameCount)
            let batchStarted = DispatchTime.now().uptimeNanoseconds
            try await store.insertBatch(corpus.frames(in: start..<end))
            seedBatchSamples.append(elapsedMilliseconds(since: batchStarted))
        }
        let seedMilliseconds = elapsedMilliseconds(since: seedStarted)
        let seedCheckpointStarted = DispatchTime.now().uptimeNanoseconds
        try await store.checkpointStorageForDiagnostics()
        let seedCheckpointMilliseconds = elapsedMilliseconds(since: seedCheckpointStarted)
        let walAfterSeedCheckpoint = fileBytes(at: walURL(for: paths))
        let beforeIndex = try await store.statistics()
        let beforeIndexStorage = try await store.memorySegmentStorageDiagnostics()

        let rebuildStarted = DispatchTime.now().uptimeNanoseconds
        let firstRevision = try await store.rebuildMemorySegmentIndex()
        let initialRebuildMilliseconds = elapsedMilliseconds(since: rebuildStarted)
        let initialCheckpointStarted = DispatchTime.now().uptimeNanoseconds
        try await store.checkpointStorageForDiagnostics()
        let initialCheckpointMilliseconds = elapsedMilliseconds(since: initialCheckpointStarted)
        let walAfterInitialCheckpoint = fileBytes(at: walURL(for: paths))
        let readyStatus = try await requireIndexStatistics(store)
        let afterInitialIndexStorage = try await store.memorySegmentStorageDiagnostics()

        let verificationStarted = DispatchTime.now().uptimeNanoseconds
        let secondRevision = try await store.rebuildMemorySegmentIndex()
        let verificationRebuildMilliseconds = elapsedMilliseconds(since: verificationStarted)
        let verificationCheckpointStarted = DispatchTime.now().uptimeNanoseconds
        try await store.checkpointStorageForDiagnostics()
        let verificationCheckpointMilliseconds = elapsedMilliseconds(
            since: verificationCheckpointStarted
        )
        let walAfterVerificationCheckpoint = fileBytes(at: walURL(for: paths))
        let verifiedStatus = try await requireIndexStatistics(store)
        let afterVerificationIndexStorage = try await store.memorySegmentStorageDiagnostics()

        let emptyScope = try MemorySegmentScope()
        let app2Site12Scope = try MemorySegmentScope(
            applicationBundleIdentifiers: ["app.fixture.2"],
            domains: ["site12.example"]
        )
        let session42Scope = try corpus.scope(forSession: 42)

        let topic42Total = corpus.expectedSegmentCount(topic: 42)
        let topic42Frames = corpus.expectedFrameCount(topic: 42)
        let topic42App2Site12Total = corpus.expectedSegmentCount(
            topic: 42,
            application: 2,
            site: 12
        )
        let topic42App2Site12Frames = corpus.expectedFrameCount(
            topic: 42,
            application: 2,
            site: 12
        )
        let app2Site12Total = corpus.expectedSegmentCount(application: 2, site: 12)
        let app2Site12Frames = corpus.expectedFrameCount(application: 2, site: 12)
        let agentTopic42Total = corpus.expectedSegmentCount(topic: 42, agentSafe: true)
        let agentTopic42Frames = corpus.expectedFrameCount(topic: 42, agentSafe: true)

        let workloads = [
            try WorkloadDefinition(
                name: "private_full_browse",
                boundary: .privateLocal,
                requestShape: "all-segments-first-page",
                request: request(scope: emptyScope, limit: configuration.pageLimit),
                expectedTotalSegmentCount: corpus.expectedSegmentCount,
                expectedFrameCount: configuration.frameCount
            ),
            try WorkloadDefinition(
                name: "private_topic42",
                boundary: .privateLocal,
                requestShape: "saved-text:topic42",
                request: request(
                    text: "topic42",
                    scope: emptyScope,
                    limit: configuration.pageLimit
                ),
                expectedTotalSegmentCount: topic42Total,
                expectedFrameCount: topic42Frames
            ),
            try WorkloadDefinition(
                name: "private_topic42_app2_site12",
                boundary: .privateLocal,
                requestShape: "saved-text:topic42+app.fixture.2+site12.example",
                request: request(
                    text: "topic42",
                    scope: app2Site12Scope,
                    limit: configuration.pageLimit
                ),
                expectedTotalSegmentCount: topic42App2Site12Total,
                expectedFrameCount: topic42App2Site12Frames
            ),
            try WorkloadDefinition(
                name: "private_metadata_app2_site12",
                boundary: .privateLocal,
                requestShape: "app.fixture.2+site12.example",
                request: request(
                    scope: app2Site12Scope,
                    limit: configuration.pageLimit
                ),
                expectedTotalSegmentCount: app2Site12Total,
                expectedFrameCount: app2Site12Frames
            ),
            try WorkloadDefinition(
                name: "private_needle4242",
                boundary: .privateLocal,
                requestShape: "saved-text:needle4242",
                request: request(
                    text: "needle4242",
                    scope: emptyScope,
                    limit: configuration.pageLimit
                ),
                expectedTotalSegmentCount: 1,
                expectedFrameCount: 1
            ),
            try WorkloadDefinition(
                name: "private_zero_hit",
                boundary: .privateLocal,
                requestShape: "saved-text:termdoesnotexistpassage",
                request: request(
                    text: "termdoesnotexistpassage",
                    scope: emptyScope,
                    limit: configuration.pageLimit
                ),
                expectedTotalSegmentCount: 0,
                expectedFrameCount: 0
            ),
            try WorkloadDefinition(
                name: "private_session42_context",
                boundary: .privateLocal,
                requestShape: "activity-session:42",
                request: request(
                    scope: session42Scope,
                    limit: configuration.pageLimit
                ),
                expectedTotalSegmentCount: DeterministicSegmentCorpus.segmentsPerSession,
                expectedFrameCount: configuration.framesPerSession
            ),
            try WorkloadDefinition(
                name: "agent_topic42",
                boundary: .agentSafe,
                requestShape: "saved-text:topic42+agent-safe",
                request: request(
                    text: "topic42",
                    scope: emptyScope,
                    limit: configuration.pageLimit
                ),
                expectedTotalSegmentCount: agentTopic42Total,
                expectedFrameCount: agentTopic42Frames
            ),
        ]

        var workloadReports = [BenchmarkWorkloadReport]()
        var workloadProbes = [String: MemorySegmentPage]()
        for workload in workloads {
            let measurement = try await measure(
                workload,
                sampleCount: configuration.sampleCount,
                store: store
            )
            workloadReports.append(measurement.report)
            workloadProbes[workload.name] = measurement.lastPage
        }

        let walkedWorkloads = workloads.filter { $0.name != "private_full_browse" }
        var cursorWalks = [BenchmarkCursorWalkReport]()
        for workload in walkedWorkloads {
            cursorWalks.append(try await cursorWalk(
                workload,
                pageLimit: configuration.pageLimit,
                store: store
            ))
        }

        let freshWorkload = try requireWorkload(
            named: "private_topic42_app2_site12",
            in: workloads
        )
        let freshConnection = try await measureFreshConnections(
            workload: freshWorkload,
            sampleCount: configuration.freshConnectionSampleCount,
            paths: paths,
            key: key
        )

        let captureStart = configuration.frameCount
        let captureEnd = captureStart + configuration.captureProbeCount
        let captureRange = captureStart..<captureEnd
        let appendedFrameIDs = Set(captureRange.map(corpus.frameID))
        var captureSamples = [Double]()
        for index in captureRange {
            let started = DispatchTime.now().uptimeNanoseconds
            try await store.insert(corpus.frame(index))
            captureSamples.append(elapsedMilliseconds(since: started))
        }
        let postCaptureStatus = try await store.memorySegmentIndexStatistics()
        let captureScope = try corpus.scope(forFrameRange: captureRange)
        let captureRequest = try request(scope: captureScope, limit: configuration.pageLimit)
        let dirtyOverlayPage = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(captureRequest)
        )
        let dirtyOverlayFrameIDs = Set(dirtyOverlayPage.segments.flatMap(\.frameIDs))
        let postCaptureOmissions = omissionReasons(dirtyOverlayPage)
        let retrievalAvailableAfterCapture = dirtyOverlayPage.accessBoundary == .privateLocal
            && dirtyOverlayPage.isComplete
            && !dirtyOverlayPage.segments.isEmpty
            && !dirtyOverlayPage.omissions.contains { $0.reason == .incompleteIndex }
        let captureWalBytes = fileBytes(at: walURL(for: paths))
        try await store.checkpointStorageForDiagnostics()
        let walAfterCaptureCheckpoint = fileBytes(at: walURL(for: paths))

        var maintenanceSamples = [Double]()
        var maintenanceAttemptCount = 0
        var maintainedSessionCount = 0
        var deferredSessionCount = 0
        var reachedNoWork = false
        while maintenanceAttemptCount <= configuration.captureProbeCount + 1 {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = try await store.maintainNextMemorySegmentSession(maxFrames: 512)
            maintenanceSamples.append(elapsedMilliseconds(since: started))
            maintenanceAttemptCount += 1
            switch result {
            case .maintained:
                maintainedSessionCount += 1
            case .deferred:
                deferredSessionCount += 1
                break
            case .noWork:
                reachedNoWork = true
            }
            if reachedNoWork || deferredSessionCount > 0 { break }
        }
        let maintenanceWalBytes = fileBytes(at: walURL(for: paths))
        let postMaintenanceStatus = try await store.memorySegmentIndexStatistics()
        let postMaintenancePage = try await store.retrievePrivateMemorySegments(
            PrivateMemorySegmentRequest(captureRequest)
        )
        let postMaintenanceOmissions = omissionReasons(postMaintenancePage)
        let retrievalAvailableAfterMaintenance = postMaintenancePage.accessBoundary == .privateLocal
            && postMaintenancePage.isComplete
            && !postMaintenancePage.segments.isEmpty
            && !postMaintenancePage.omissions.contains { $0.reason == .incompleteIndex }
        try await store.checkpointStorageForDiagnostics()
        let walAfterMaintenanceCheckpoint = fileBytes(at: walURL(for: paths))

        let expectedSegmentCountAfterMaintenance = corpus.expectedSegmentCount + 1
        let shadowBytes = afterInitialIndexStorage.memorySegmentShadowBytes
        let shadowBytesPerFrame = Double(shadowBytes) / Double(configuration.frameCount)
        let shadowOverheadRatio = Double(shadowBytes)
            / Double(afterInitialIndexStorage.canonicalLiveBytes)
        let maintenanceAmplification = Double(maintenanceWalBytes)
            / Double(max(captureWalBytes, 1))
        let verificationShadowGrowth = afterVerificationIndexStorage.memorySegmentShadowBytes
            - shadowBytes
        let verificationShadowGrowthBudget = max(
            afterInitialIndexStorage.pageSizeBytes * 16,
            Int64(ceil(Double(shadowBytes) * 0.001))
        )
        let stableStorage = afterInitialIndexStorage.canonicalLiveBytes
                == afterVerificationIndexStorage.canonicalLiveBytes
            && afterInitialIndexStorage.memorySegmentSchemaObjects
                == afterVerificationIndexStorage.memorySegmentSchemaObjects
            && afterInitialIndexStorage.memorySegmentDBStatObjects
                == afterVerificationIndexStorage.memorySegmentDBStatObjects
            && abs(verificationShadowGrowth) <= verificationShadowGrowthBudget
        let frameKeySupportObjects: Set<String> = [
            "frame_key_sequence",
            "frames_frame_key",
        ]
        let frameKeySupportObjectsAreAccounted = frameKeySupportObjects.isSubset(
            of: Set(afterInitialIndexStorage.memorySegmentSchemaObjects)
        ) && frameKeySupportObjects.isSubset(
            of: Set(afterInitialIndexStorage.memorySegmentDBStatObjects)
        ) && frameKeySupportObjects.isSubset(
            of: Set(afterInitialIndexStorage.memorySegmentObjectLiveBytes.map(\.name))
        )
        let checkpointedWAL = [
            walAfterSeedCheckpoint,
            walAfterInitialCheckpoint,
            walAfterVerificationCheckpoint,
            walAfterCaptureCheckpoint,
            walAfterMaintenanceCheckpoint,
        ].allSatisfy { $0 == 0 }

        let session42Probe = try requirePage(
            named: "private_session42_context",
            in: workloadProbes
        )
        let domainlessSegments = session42Probe.segments.filter { $0.scope.domains.isEmpty }
        let domainlessContextIsPreserved = domainlessSegments.count == 1
            && domainlessSegments[0].frameIDs.count == 2
            && domainlessSegments[0].representativeEvidence.allSatisfy { $0.domain == nil }

        let workloadAccessBoundariesMatch = workloads.allSatisfy { workload in
            workloadProbes[workload.name]?.accessBoundary == workload.boundary
        }
        let workloadFirstPageCountsMatch = workloadReports.allSatisfy { report in
            report.minimumReturnedSegments == report.expectedFirstPageSegmentCount
                && report.maximumReturnedSegments == report.expectedFirstPageSegmentCount
        }
        let cursorWalkByName = Dictionary(
            uniqueKeysWithValues: cursorWalks.map { ($0.name, $0) }
        )
        let cursorWalksMatch = cursorWalks.allSatisfy(cursorWalkPassed)
        let agentCursor = cursorWalkByName["agent_topic42"]
        let agentPrivacyMatches = agentCursor.map {
            cursorWalkPassed($0)
                && $0.returnedSegmentCount == agentTopic42Total
                && $0.returnedUniqueFrameCount == agentTopic42Frames
                && $0.agentSafeSegments
                && $0.policyOmissionCountHidden
                && $0.omissionReasons == [MemorySegmentOmissionReason.policyFiltered.rawValue]
        } ?? false

        let frozenMillionCorpus = DeterministicSegmentCorpus(
            frameCount: BenchmarkConfiguration.millionFrameCount,
            framesPerSession: BenchmarkConfiguration.framesPerSession,
            contextKeyCount: BenchmarkConfiguration.contextKeyCount
        )
        let frozenCountsMatch = frozenMillionCorpus.expectedSegmentCount(topic: 42) == 390
            && frozenMillionCorpus.expectedSegmentCount(
                topic: 42,
                application: 2,
                site: 12
            ) == 12
            && frozenMillionCorpus.expectedSegmentCount(application: 2, site: 12) == 332
            && frozenMillionCorpus.expectedSegmentCount(topic: 42, agentSafe: true) == 365
        let corpusProtocolMatches = validateCorpusProtocol(corpus)

        var validations = [String: Bool]()
        validations["corpus_protocol_matches_revision"] = corpusProtocolMatches
        validations["corpus_exact_counts_match"] = frozenCountsMatch
        validations["index_ready_after_rebuild"] = verifiedStatus.lifecycle == "ready"
        validations["canonical_frame_count_matches"] =
            verifiedStatus.canonicalFrameCount == configuration.frameCount
        validations["segment_count_matches_deterministic_corpus"] =
            verifiedStatus.segmentCount == corpus.expectedSegmentCount
        validations["rebuild_revision_is_deterministic"] = firstRevision == secondRevision
            && readyStatus.lastFullRebuildRevision == firstRevision
            && verifiedStatus.lastFullRebuildRevision == secondRevision
        validations["verification_storage_growth_within_budget"] = stableStorage
        validations["shadow_footprint_is_positive"] = shadowBytes > 0
            && afterInitialIndexStorage.canonicalLiveBytes > 0
        validations["workload_access_boundaries_match"] = workloadAccessBoundariesMatch
        validations["workload_first_page_counts_match"] = workloadFirstPageCountsMatch
        validations["full_cursor_walks_match_expected_results"] = cursorWalksMatch
        validations["agent_privacy_full_cursor_walk_matches"] = agentPrivacyMatches
        validations["domainless_context_is_preserved"] = domainlessContextIsPreserved
        validations["fresh_connection_first_query_available"] =
            freshConnection.retrievalAvailable
        validations["frame_key_support_objects_are_accounted"] =
            frameKeySupportObjectsAreAccounted
        validations["first_page_hydration_within_limit"] =
            workloadReports.allSatisfy { $0.firstPageHydration.withinLimit }
                && freshConnection.firstPageHydration.withinLimit
        validations["dirty_overlay_retrieves_all_appended_frame_ids"] =
            dirtyOverlayFrameIDs == appendedFrameIDs
        validations["capture_keeps_index_ready_and_available"] =
            postCaptureStatus?.lifecycle == "ready"
                && postCaptureStatus?.pendingSessionCount == 1
                && retrievalAvailableAfterCapture
        validations["maintenance_queue_drains_to_zero"] = reachedNoWork
            && deferredSessionCount == 0
            && postMaintenanceStatus?.pendingSessionCount == 0
        validations["post_maintenance_result_equals_dirty_overlay"] =
            postMaintenancePage.segments == dirtyOverlayPage.segments
        validations["post_maintenance_revision_equals_dirty_overlay"] =
            postMaintenancePage.revision == dirtyOverlayPage.revision
        validations["post_maintenance_index_counts_match"] =
            postMaintenanceStatus?.canonicalFrameCount
                == configuration.frameCount + configuration.captureProbeCount
                && postMaintenanceStatus?.segmentCount == expectedSegmentCountAfterMaintenance
        validations["storage_is_checkpointed"] = checkpointedWAL
        validations["write_amplification_samples_are_nonzero"] =
            captureWalBytes > 0 && maintenanceWalBytes > 0

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let systemReport = BenchmarkSystemReport(
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architectureName,
            processorCount: ProcessInfo.processInfo.processorCount
        )
        let configurationReport = BenchmarkConfigurationReport(
            profile: configuration.profile.rawValue,
            runOrdinal: configuration.runOrdinal,
            requiredRunCount: configuration.requiredRunCount,
            frameCount: configuration.frameCount,
            sampleCount: configuration.sampleCount,
            freshConnectionSampleCount: configuration.freshConnectionSampleCount,
            batchSize: configuration.batchSize,
            framesPerSession: configuration.framesPerSession,
            contextKeyCount: configuration.contextKeyCount,
            pageLimit: configuration.pageLimit,
            captureProbeCount: configuration.captureProbeCount
        )
        let corpusReport = BenchmarkCorpusReport(
            revision: DeterministicSegmentCorpus.revision,
            sessionCount: corpus.sessionCount,
            sensitiveSessionCount: corpus.sensitiveSessionCount,
            applicationCount: DeterministicSegmentCorpus.applicationCount,
            siteCount: DeterministicSegmentCorpus.siteCount,
            topicCount: DeterministicSegmentCorpus.topicCount,
            contextKeyFrameDistribution: DeterministicSegmentCorpus.keyDistribution,
            domainlessContextKey: DeterministicSegmentCorpus.domainlessContextKey,
            needleFrameIndex: DeterministicSegmentCorpus.needleFrameIndex,
            needleFrameCount: corpus.expectedNeedleFrameCount,
            expectedSegmentCount: corpus.expectedSegmentCount,
            expectedAgentSafeSegmentCount: corpus.expectedAgentSafeSegmentCount,
            expectedTopic42SegmentCount: topic42Total,
            expectedTopic42FrameCount: topic42Frames,
            expectedTopic42App2Site12SegmentCount: topic42App2Site12Total,
            expectedTopic42App2Site12FrameCount: topic42App2Site12Frames,
            expectedApp2Site12SegmentCount: app2Site12Total,
            expectedApp2Site12FrameCount: app2Site12Frames,
            expectedAgentSafeTopic42SegmentCount: agentTopic42Total,
            expectedAgentSafeTopic42FrameCount: agentTopic42Frames
        )
        let seedReport = BenchmarkSeedReport(
            totalMilliseconds: seedMilliseconds,
            framesPerSecond: Double(configuration.frameCount) / (seedMilliseconds / 1_000),
            batchLatency: BenchmarkLatencySummary(samples: seedBatchSamples),
            checkpointMilliseconds: seedCheckpointMilliseconds
        )
        let beforeIndexSnapshot = storageSnapshot(beforeIndexStorage)
        let afterInitialIndexSnapshot = storageSnapshot(afterInitialIndexStorage)
        let afterVerificationIndexSnapshot = storageSnapshot(afterVerificationIndexStorage)
        let storageReport = BenchmarkStorageReport(
            measurement: "checkpointed-dbstat-v3-exact-memory-segment-shadow-live-bytes",
            accountingNotes: [
                "frame-key-sequence-and-frames-frame-key-index-count-as-shadow-support",
                "frames.frame_key-column-bytes-remain-in-canonical-frames-btree-and-are-not-separable-by-dbstat",
                "sqlite-pending-byte-locking-page-excluded-from-dbstat-when-main-db-exceeds-0x40000000-bytes",
            ],
            beforeIndex: beforeIndexSnapshot,
            afterInitialIndex: afterInitialIndexSnapshot,
            afterVerificationIndex: afterVerificationIndexSnapshot,
            shadowBytesPerFrame: shadowBytesPerFrame,
            shadowOverheadRatio: shadowOverheadRatio,
            verificationShadowGrowthBytes: verificationShadowGrowth,
            verificationShadowGrowthBudgetBytes: verificationShadowGrowthBudget,
            stableAcrossVerificationRebuild: stableStorage,
            mediaBytes: beforeIndex.mediaBytes,
            memorySegmentSchemaObjects:
                afterInitialIndexStorage.memorySegmentSchemaObjects,
            memorySegmentDBStatObjects:
                afterInitialIndexStorage.memorySegmentDBStatObjects,
            captureWalBytes: captureWalBytes,
            maintenanceWalBytes: maintenanceWalBytes,
            maintenanceToCaptureWalAmplification: maintenanceAmplification,
            writeAmplificationScope:
                "incremental-maintenance-to-capture-wal-proxy-not-device-writes"
        )
        let indexReport = BenchmarkIndexReport(
            lifecycle: verifiedStatus.lifecycle,
            lastFullRebuildRevision: verifiedStatus.lastFullRebuildRevision?.rawValue,
            canonicalFrameCount: verifiedStatus.canonicalFrameCount,
            segmentCount: verifiedStatus.segmentCount,
            pendingSessionCount: verifiedStatus.pendingSessionCount,
            initialRebuildMilliseconds: initialRebuildMilliseconds,
            initialCheckpointMilliseconds: initialCheckpointMilliseconds,
            verificationRebuildMilliseconds: verificationRebuildMilliseconds,
            verificationCheckpointMilliseconds: verificationCheckpointMilliseconds,
            deterministicLastFullRebuildRevision: firstRevision == secondRevision
        )
        let captureReport = BenchmarkCaptureProbeReport(
            appendedFrameCount: configuration.captureProbeCount,
            expectedAppendedFrameIDCount: appendedFrameIDs.count,
            retrievedAppendedFrameIDCount: dirtyOverlayFrameIDs.count,
            insertLatency: BenchmarkLatencySummary(samples: captureSamples),
            lifecycleAfterAppend: postCaptureStatus?.lifecycle,
            pendingSessionCountAfterAppend: postCaptureStatus?.pendingSessionCount,
            dirtyOverlaySegmentCount: dirtyOverlayPage.segments.count,
            dirtyOverlayFrameCount: dirtyOverlayFrameIDs.count,
            dirtyOverlayContainsEveryAppendedFrameID: dirtyOverlayFrameIDs == appendedFrameIDs,
            dirtyOverlayRevision: dirtyOverlayPage.revision.rawValue,
            retrievalAvailableAfterAppend: retrievalAvailableAfterCapture,
            retrievalOmissionReasons: postCaptureOmissions,
            interferenceModel:
                "capture-then-dirty-overlay-read-then-bounded-maintenance-on-one-store-actor"
        )
        let maintenanceReport = BenchmarkMaintenanceReport(
            attemptCount: maintenanceAttemptCount,
            maintainedSessionCount: maintainedSessionCount,
            deferredSessionCount: deferredSessionCount,
            reachedNoWork: reachedNoWork,
            latency: BenchmarkLatencySummary(samples: maintenanceSamples),
            lifecycleAfterMaintenance: postMaintenanceStatus?.lifecycle,
            pendingSessionCountAfterMaintenance: postMaintenanceStatus?.pendingSessionCount,
            canonicalFrameCountAfterMaintenance: postMaintenanceStatus?.canonicalFrameCount,
            segmentCountAfterMaintenance: postMaintenanceStatus?.segmentCount,
            expectedSegmentCountAfterMaintenance: expectedSegmentCountAfterMaintenance,
            postMaintenanceEqualsDirtyOverlay:
                postMaintenancePage.segments == dirtyOverlayPage.segments,
            postMaintenanceRevisionEqualsDirtyOverlay:
                postMaintenancePage.revision == dirtyOverlayPage.revision,
            retrievalAvailableAfterMaintenance: retrievalAvailableAfterMaintenance,
            retrievalOmissionReasons: postMaintenanceOmissions
        )
        return MemorySegmentBenchmarkReport(
            schemaVersion: MemorySegmentBenchmarkReport.schemaVersion,
            protocolRevision: MemorySegmentBenchmarkReport.protocolRevision,
            benchmark: "chronicle-memory-segments",
            claimScope: "store-only",
            cacheState: "warm-os-cache",
            corpusKind: "synthetic-deterministic",
            mediaFixture: "path-references-only-no-media-files",
            excludedClaims: [
                "concurrent-writer-contention",
                "device-level-physical-write-amplification",
                "end-to-end-product-latency",
                "media-io-or-decoding",
                "physical-cold-disk-latency",
                "real-world-relevance",
            ],
            generatedAt: formatter.string(from: Date()),
            system: systemReport,
            configuration: configurationReport,
            corpus: corpusReport,
            seed: seedReport,
            storage: storageReport,
            index: indexReport,
            workloads: workloadReports,
            cursorWalks: cursorWalks,
            freshConnection: freshConnection,
            captureProbe: captureReport,
            maintenance: maintenanceReport,
            validations: validations
        )
    }

    private static func request(
        text: String = "",
        scope: MemorySegmentScope,
        after: MemorySegmentCursor? = nil,
        limit: Int
    ) throws -> MemorySegmentRequest {
        try MemorySegmentRequest(
            text: text,
            scope: scope,
            retrievalModalities: [.savedText],
            after: after,
            limit: limit
        )
    }

    private static func request(
        basedOn request: MemorySegmentRequest,
        after: MemorySegmentCursor?,
        limit: Int
    ) throws -> MemorySegmentRequest {
        try MemorySegmentRequest(
            text: request.text,
            scope: request.scope,
            retrievalModalities: request.retrievalModalities,
            after: after,
            limit: limit
        )
    }

    private static func retrieve(
        _ workload: WorkloadDefinition,
        from store: SQLiteFrameStore,
        after: MemorySegmentCursor? = nil,
        limit: Int? = nil
    ) async throws -> MemorySegmentPage {
        let retrieval = try request(
            basedOn: workload.request,
            after: after,
            limit: limit ?? workload.request.limit
        )
        return switch workload.boundary {
        case .privateLocal:
            try await store.retrievePrivateMemorySegments(
                PrivateMemorySegmentRequest(retrieval)
            )
        case .agentSafe:
            try await store.retrieveAgentSafeMemorySegments(
                AgentSafeMemorySegmentRequest(retrieval)
            )
        }
    }

    private static func retrieveForDiagnostics(
        _ workload: WorkloadDefinition,
        from store: SQLiteFrameStore
    ) async throws -> MemorySegmentPageDiagnostics {
        switch workload.boundary {
        case .privateLocal:
            try await store.retrievePrivateMemorySegmentsForDiagnostics(
                PrivateMemorySegmentRequest(workload.request)
            )
        case .agentSafe:
            try await store.retrieveAgentSafeMemorySegmentsForDiagnostics(
                AgentSafeMemorySegmentRequest(workload.request)
            )
        }
    }

    private static func requireIndexStatistics(
        _ store: SQLiteFrameStore
    ) async throws -> MemorySegmentIndexStatistics {
        guard let statistics = try await store.memorySegmentIndexStatistics() else {
            throw BenchmarkRunError.missingIndexStatistics
        }
        return statistics
    }

    private static func measure(
        _ workload: WorkloadDefinition,
        sampleCount: Int,
        store: SQLiteFrameStore
    ) async throws -> (report: BenchmarkWorkloadReport, lastPage: MemorySegmentPage) {
        let warmMeasurement = try await retrieveForDiagnostics(workload, from: store)
        let warmPage = warmMeasurement.page
        var samples = [Double]()
        var hydratedFrameCounts = [warmMeasurement.hydratedCanonicalFrameCount]
        var returnedFrameCounts = [returnedFrameCount(warmPage)]
        var minimumReturnedSegments = Int.max
        var maximumReturnedSegments = 0
        var omissions = Set<String>()
        var lastPage = warmPage
        for _ in 0..<sampleCount {
            let started = DispatchTime.now().uptimeNanoseconds
            let measurement = try await retrieveForDiagnostics(workload, from: store)
            let page = measurement.page
            samples.append(elapsedMilliseconds(since: started))
            hydratedFrameCounts.append(measurement.hydratedCanonicalFrameCount)
            returnedFrameCounts.append(returnedFrameCount(page))
            minimumReturnedSegments = min(minimumReturnedSegments, page.segments.count)
            maximumReturnedSegments = max(maximumReturnedSegments, page.segments.count)
            omissions.formUnion(omissionReasons(page))
            lastPage = page
        }
        return (
            BenchmarkWorkloadReport(
                name: workload.name,
                accessBoundary: lastPage.accessBoundary.rawValue,
                requestShape: workload.requestShape,
                sampleCount: sampleCount,
                expectedFirstPageSegmentCount: workload.expectedFirstPageSegmentCount,
                expectedTotalSegmentCount: workload.expectedTotalSegmentCount,
                latency: BenchmarkLatencySummary(samples: samples),
                minimumReturnedSegments: minimumReturnedSegments,
                maximumReturnedSegments: maximumReturnedSegments,
                firstPageHydration: try firstPageHydrationReport(
                    hydratedFrameCounts: hydratedFrameCounts,
                    returnedFrameCounts: returnedFrameCounts,
                    pageLimit: workload.request.limit
                ),
                omissionReasons: omissions.sorted()
            ),
            lastPage
        )
    }

    private static func cursorWalk(
        _ workload: WorkloadDefinition,
        pageLimit: Int,
        store: SQLiteFrameStore
    ) async throws -> BenchmarkCursorWalkReport {
        var cursor: MemorySegmentCursor?
        var firstRevision: MemorySegmentIndexRevision?
        var previous: (endedAt: Date, id: String)?
        var segmentIDs = Set<MemorySegmentID>()
        var frameIDs = Set<FrameID>()
        var returnedSegmentCount = 0
        var pageCount = 0
        var accessBoundaryStable = true
        var revisionStable = true
        var strictOrder = true
        var noDuplicateSegments = true
        var noDuplicateFrames = true
        var agentSafeSegments = true
        var policyOmissionCountHidden = true
        var omissions = Set<String>()
        var terminated = false
        let maximumPages = max(2, (workload.expectedTotalSegmentCount / pageLimit) + 3)

        while pageCount < maximumPages {
            let page = try await retrieve(
                workload,
                from: store,
                after: cursor,
                limit: pageLimit
            )
            pageCount += 1
            accessBoundaryStable = accessBoundaryStable && page.accessBoundary == workload.boundary
            if let firstRevision {
                revisionStable = revisionStable && page.revision == firstRevision
            } else {
                firstRevision = page.revision
            }
            omissions.formUnion(omissionReasons(page))
            for omission in page.omissions where omission.reason == .policyFiltered {
                policyOmissionCountHidden = policyOmissionCountHidden && omission.count == nil
            }
            for segment in page.segments {
                returnedSegmentCount += 1
                if !segmentIDs.insert(segment.id).inserted {
                    noDuplicateSegments = false
                }
                for frameID in segment.frameIDs where !frameIDs.insert(frameID).inserted {
                    noDuplicateFrames = false
                }
                if workload.boundary == .agentSafe, segment.containsSensitive {
                    agentSafeSegments = false
                }
                let current = (segment.scope.endDate!, segment.id.rawValue)
                if let previous {
                    strictOrder = strictOrder && (
                        previous.endedAt > current.0
                            || (previous.endedAt == current.0 && previous.id > current.1)
                    )
                }
                previous = (current.0, current.1)
            }
            guard let nextCursor = page.nextCursor else {
                terminated = !page.hasMore
                break
            }
            cursor = nextCursor
        }

        return BenchmarkCursorWalkReport(
            name: workload.name,
            accessBoundary: workload.boundary.rawValue,
            pageLimit: pageLimit,
            expectedSegmentCount: workload.expectedTotalSegmentCount,
            returnedSegmentCount: returnedSegmentCount,
            expectedFrameCount: workload.expectedFrameCount,
            returnedUniqueFrameCount: frameIDs.count,
            pageCount: pageCount,
            accessBoundaryStable: accessBoundaryStable,
            revisionStable: revisionStable,
            strictOrder: strictOrder,
            noDuplicateSegments: noDuplicateSegments,
            noDuplicateFrames: noDuplicateFrames,
            agentSafeSegments: agentSafeSegments,
            policyOmissionCountHidden: policyOmissionCountHidden,
            terminated: terminated,
            omissionReasons: omissions.sorted()
        )
    }

    private static func measureFreshConnections(
        workload: WorkloadDefinition,
        sampleCount: Int,
        paths: PassagePaths,
        key: VaultKey
    ) async throws -> BenchmarkFreshConnectionReport {
        var openSamples = [Double]()
        var firstQuerySamples = [Double]()
        var combinedSamples = [Double]()
        var hydratedFrameCounts = [Int]()
        var returnedFrameCounts = [Int]()
        var minimumReturnedSegments = Int.max
        var maximumReturnedSegments = 0
        var retrievalAvailable = true
        var omissions = Set<String>()

        for _ in 0..<sampleCount {
            let combinedStarted = DispatchTime.now().uptimeNanoseconds
            let openStarted = DispatchTime.now().uptimeNanoseconds
            let freshStore = try SQLiteFrameStore(paths: paths, vaultKey: key, readOnly: true)
            openSamples.append(elapsedMilliseconds(since: openStarted))
            let queryStarted = DispatchTime.now().uptimeNanoseconds
            let measurement = try await retrieveForDiagnostics(
                workload,
                from: freshStore
            )
            let page = measurement.page
            firstQuerySamples.append(elapsedMilliseconds(since: queryStarted))
            combinedSamples.append(elapsedMilliseconds(since: combinedStarted))
            hydratedFrameCounts.append(measurement.hydratedCanonicalFrameCount)
            returnedFrameCounts.append(returnedFrameCount(page))
            minimumReturnedSegments = min(minimumReturnedSegments, page.segments.count)
            maximumReturnedSegments = max(maximumReturnedSegments, page.segments.count)
            omissions.formUnion(omissionReasons(page))
            retrievalAvailable = retrievalAvailable
                && page.accessBoundary == workload.boundary
                && page.segments.count == workload.expectedFirstPageSegmentCount
                && !page.omissions.contains { $0.reason == .incompleteIndex }
            freshStore.revoke()
        }

        return BenchmarkFreshConnectionReport(
            name: workload.name,
            accessBoundary: workload.boundary.rawValue,
            cacheState: "new-sqlcipher-connection-warm-os-cache",
            sampleCount: sampleCount,
            expectedFirstPageSegmentCount: workload.expectedFirstPageSegmentCount,
            openLatency: BenchmarkLatencySummary(samples: openSamples),
            firstQueryLatency: BenchmarkLatencySummary(samples: firstQuerySamples),
            openAndFirstLatency: BenchmarkLatencySummary(samples: combinedSamples),
            minimumReturnedSegments: minimumReturnedSegments,
            maximumReturnedSegments: maximumReturnedSegments,
            firstPageHydration: try firstPageHydrationReport(
                hydratedFrameCounts: hydratedFrameCounts,
                returnedFrameCounts: returnedFrameCounts,
                pageLimit: workload.request.limit
            ),
            retrievalAvailable: retrievalAvailable,
            omissionReasons: omissions.sorted()
        )
    }

    private static func returnedFrameCount(_ page: MemorySegmentPage) -> Int {
        page.segments.reduce(into: 0) { count, segment in
            count += segment.frameIDs.count
        }
    }

    private static func firstPageHydrationReport(
        hydratedFrameCounts: [Int],
        returnedFrameCounts: [Int],
        pageLimit: Int
    ) throws -> BenchmarkFirstPageHydrationReport {
        guard !hydratedFrameCounts.isEmpty,
              hydratedFrameCounts.count == returnedFrameCounts.count,
              hydratedFrameCounts.allSatisfy({ $0 >= 0 }),
              returnedFrameCounts.allSatisfy({ $0 >= 0 }),
              let minimumHydrated = hydratedFrameCounts.min(),
              let maximumHydrated = hydratedFrameCounts.max(),
              let minimumReturned = returnedFrameCounts.min(),
              let maximumReturned = returnedFrameCounts.max(),
              let minimumSurplus = zip(hydratedFrameCounts, returnedFrameCounts)
                .map({ $0.0 - $0.1 }).min() else {
            throw BenchmarkRunError.invalidHydrationMeasurements
        }
        let canonicalFrameLimit = pageLimit * maximumFramesPerSegment
        return BenchmarkFirstPageHydrationReport(
            measurement: "canonical-frame-decode-loop-rows",
            measurementCount: hydratedFrameCounts.count,
            canonicalFrameLimit: canonicalFrameLimit,
            minimumHydratedCanonicalFrameCount: minimumHydrated,
            maximumHydratedCanonicalFrameCount: maximumHydrated,
            minimumReturnedFrameCount: minimumReturned,
            maximumReturnedFrameCount: maximumReturned,
            minimumHydrationSurplus: minimumSurplus,
            withinLimit: maximumHydrated <= canonicalFrameLimit
                && minimumSurplus >= 0
        )
    }

    private static func validateCorpusProtocol(_ corpus: DeterministicSegmentCorpus) -> Bool {
        let representativeIndices = [0, 70, 90, 98, DeterministicSegmentCorpus.needleFrameIndex]
        let frames = representativeIndices.map(corpus.frame)
        let topicInEveryFrame = frames.allSatisfy { frame in
            let session = Int(frame.id.rawValue.suffix(12))! / corpus.framesPerSession
            return frame.ocrText.contains("topic\(session % DeterministicSegmentCorpus.topicCount)")
                && frame.ocrRegions.count == 6
        }
        let contexts = [0, 1, 2, 3].map {
            DeterministicSegmentCorpus.context(sessionIndex: 42, key: $0)
        }
        let exactMapping = contexts[0] == (2, 12)
            && contexts[1] == (3, 19)
            && contexts[2] == (4, 25)
            && contexts[3].application == 5
            && contexts[3].site == nil
        let markerIsUniqueByConstruction = corpus.frame(4_241).ocrText.contains("needle4242") == false
            && corpus.frame(4_242).ocrText.contains("needle4242")
            && corpus.frame(4_243).ocrText.contains("needle4242") == false
        return topicInEveryFrame
            && exactMapping
            && markerIsUniqueByConstruction
            && DeterministicSegmentCorpus.keyDistribution == [70, 20, 8, 2]
            && DeterministicSegmentCorpus.segmentsPerSession == 5
    }

    private static func cursorWalkPassed(_ walk: BenchmarkCursorWalkReport) -> Bool {
        walk.returnedSegmentCount == walk.expectedSegmentCount
            && walk.returnedUniqueFrameCount == walk.expectedFrameCount
            && walk.accessBoundaryStable
            && walk.revisionStable
            && walk.strictOrder
            && walk.noDuplicateSegments
            && walk.noDuplicateFrames
            && walk.agentSafeSegments
            && walk.policyOmissionCountHidden
            && walk.terminated
    }

    private static func requireWorkload(
        named name: String,
        in workloads: [WorkloadDefinition]
    ) throws -> WorkloadDefinition {
        guard let workload = workloads.first(where: { $0.name == name }) else {
            throw BenchmarkRunError.missingWorkload(name)
        }
        return workload
    }

    private static func requirePage(
        named name: String,
        in pages: [String: MemorySegmentPage]
    ) throws -> MemorySegmentPage {
        guard let page = pages[name] else {
            throw BenchmarkRunError.missingWorkload(name)
        }
        return page
    }

    private static func omissionReasons(_ page: MemorySegmentPage) -> [String] {
        Array(Set(page.omissions.map { $0.reason.rawValue })).sorted()
    }

    private static func walURL(for paths: PassagePaths) -> URL {
        URL(fileURLWithPath: paths.database.path + "-wal")
    }

    private static func storageSnapshot(
        _ diagnostics: MemorySegmentStorageDiagnostics
    ) -> BenchmarkStorageSnapshotReport {
        BenchmarkStorageSnapshotReport(
            logicalMainFileBytes: diagnostics.pageCount * diagnostics.pageSizeBytes,
            pageSizeBytes: diagnostics.pageSizeBytes,
            pageCount: diagnostics.pageCount,
            freelistPageCount: diagnostics.freelistPageCount,
            liveDatabaseBytes: diagnostics.liveDatabaseBytes,
            memorySegmentShadowBytes: diagnostics.memorySegmentShadowBytes,
            canonicalLiveBytes: diagnostics.canonicalLiveBytes,
            memorySegmentObjectLiveBytes: diagnostics.memorySegmentObjectLiveBytes.map {
                BenchmarkStorageObjectReport(name: $0.name, liveBytes: $0.liveBytes)
            }
        )
    }

    private static func fileBytes(at url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return 0
        }
        return size.int64Value
    }

    private static var architectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }
}

private struct WorkloadDefinition {
    var name: String
    var boundary: MemorySegmentAccessBoundary
    var requestShape: String
    var request: MemorySegmentRequest
    var expectedTotalSegmentCount: Int
    var expectedFrameCount: Int

    var expectedFirstPageSegmentCount: Int {
        min(request.limit, expectedTotalSegmentCount)
    }
}

private enum BenchmarkRunError: Error, LocalizedError {
    case invalidHydrationMeasurements
    case missingIndexStatistics
    case missingWorkload(String)

    var errorDescription: String? {
        switch self {
        case .invalidHydrationMeasurements:
            "First-page hydration diagnostics were incomplete."
        case .missingIndexStatistics:
            "The memory-segment index did not expose aggregate statistics."
        case let .missingWorkload(name):
            "The benchmark workload \(name) was not configured."
        }
    }
}
