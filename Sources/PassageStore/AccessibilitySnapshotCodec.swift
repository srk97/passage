import PassageCore
import CryptoKit
import Foundation

package struct StoredAccessibilitySnapshot: Sendable {
    package var snapshot: AccessibilitySnapshot
    package var payload: Data
    package var contentHash: Data
    package var searchableText: String
}

/// Canonical, bounded encoding for focused-window Accessibility evidence.
///
/// The canonical bytes are both the SQLCipher payload and the content-addressed
/// identity. Keeping byte limiting here means every writer, including imports
/// and tests, crosses the same 16 KiB storage boundary.
package enum AccessibilitySnapshotCodec {
    package static let maximumVisitedNodeCount = 192
    package static let maximumDepth = 7
    package static let maximumEncodedBytes = 16 * 1_024
    package static let maximumRoleBytes = 96
    package static let maximumTextBytes = 512

    package static func boundedSnapshot(
        nodes: [AccessibilityNodeEvidence],
        visitedNodeCount: Int,
        isTruncated: Bool
    ) throws -> AccessibilitySnapshot? {
        guard !nodes.isEmpty else { return nil }
        let boundedNodes = Array(nodes.prefix(maximumVisitedNodeCount))
        let initiallyTruncated = isTruncated || boundedNodes.count < nodes.count
        let boundedVisitedCount = min(
            maximumVisitedNodeCount,
            max(visitedNodeCount, boundedNodes.count)
        )

        let full = try canonicalized(
            AccessibilitySnapshot(
                nodes: boundedNodes,
                visitedNodeCount: boundedVisitedCount,
                isTruncated: initiallyTruncated,
                encodedByteCount: 0
            ),
            enforcesByteLimit: false
        )
        if full.payload.count <= maximumEncodedBytes { return full.snapshot }

        // Prefix payload size grows monotonically. Once the complete prefix is
        // over budget, every candidate is marked truncated and a binary search
        // finds the largest canonical prefix in at most eight encodes.
        var lowerBound = 1
        var upperBound = boundedNodes.count - 1
        var best: AccessibilitySnapshot?
        while lowerBound <= upperBound {
            let count = lowerBound + (upperBound - lowerBound) / 2
            let candidate = try canonicalized(
                AccessibilitySnapshot(
                    nodes: Array(boundedNodes.prefix(count)),
                    visitedNodeCount: boundedVisitedCount,
                    isTruncated: true,
                    encodedByteCount: 0
                ),
                enforcesByteLimit: false
            )
            if candidate.payload.count <= maximumEncodedBytes {
                best = candidate.snapshot
                lowerBound = count + 1
            } else {
                upperBound = count - 1
            }
        }
        return best
    }

    package static func stored(
        _ snapshot: AccessibilitySnapshot?
    ) throws -> StoredAccessibilitySnapshot? {
        guard let snapshot, !snapshot.nodes.isEmpty else { return nil }
        return try canonicalized(snapshot, enforcesByteLimit: true)
    }

    package static func decode(_ payload: Data) throws -> AccessibilitySnapshot {
        guard !payload.isEmpty, payload.count <= maximumEncodedBytes else {
            throw AccessibilitySnapshotCodecError.payloadTooLarge(payload.count)
        }
        let snapshot: AccessibilitySnapshot
        do {
            snapshot = try JSONDecoder().decode(AccessibilitySnapshot.self, from: payload)
        } catch {
            throw AccessibilitySnapshotCodecError.invalidPayload
        }
        try validate(snapshot)
        guard snapshot.encodedByteCount == payload.count else {
            throw AccessibilitySnapshotCodecError.encodedByteCountMismatch(
                expected: snapshot.encodedByteCount,
                actual: payload.count
            )
        }
        let canonical = try encode(snapshot)
        guard canonical == payload else {
            throw AccessibilitySnapshotCodecError.nonCanonicalPayload
        }
        return snapshot
    }

    package static func searchableText(
        for snapshot: AccessibilitySnapshot
    ) -> String {
        var seen = Set<String>()
        var values = [String]()
        values.reserveCapacity(snapshot.nodes.count * 2)
        for node in snapshot.nodes {
            for value in [node.label, node.value].compactMap({ $0 })
            where seen.insert(value).inserted {
                values.append(value)
            }
        }
        return values.joined(separator: "\n")
    }

    package static func normalizedText(_ rawValue: String, maximumBytes: Int) -> String? {
        guard !rawValue.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return nil }

        var normalized = ""
        normalized.reserveCapacity(min(rawValue.count, maximumBytes))
        var pendingSpace = false
        for character in rawValue {
            if character.isWhitespace {
                pendingSpace = !normalized.isEmpty
                continue
            }
            if pendingSpace {
                guard normalized.utf8.count + 1 <= maximumBytes else { break }
                normalized.append(" ")
                pendingSpace = false
            }
            let bytes = String(character).utf8.count
            guard normalized.utf8.count + bytes <= maximumBytes else { break }
            normalized.append(character)
        }
        return normalized.isEmpty ? nil : normalized
    }

    package static func isSecureRole(_ role: String?, subrole: String? = nil) -> Bool {
        [role, subrole]
            .compactMap { $0?.lowercased() }
            .contains { value in
                value.contains("securetextfield") || value.contains("passwordfield")
            }
    }

    private static func canonicalized(
        _ original: AccessibilitySnapshot,
        enforcesByteLimit: Bool
    ) throws -> StoredAccessibilitySnapshot {
        var snapshot = original
        try validate(snapshot, permitsUnresolvedByteCount: true)

        var payload = Data()
        for _ in 0..<8 {
            payload = try encode(snapshot)
            if snapshot.encodedByteCount == payload.count { break }
            snapshot.encodedByteCount = payload.count
        }
        payload = try encode(snapshot)
        guard snapshot.encodedByteCount == payload.count else {
            throw AccessibilitySnapshotCodecError.unstableEncoding
        }
        if enforcesByteLimit, payload.count > maximumEncodedBytes {
            throw AccessibilitySnapshotCodecError.payloadTooLarge(payload.count)
        }
        try validate(snapshot)
        return StoredAccessibilitySnapshot(
            snapshot: snapshot,
            payload: payload,
            contentHash: Data(SHA256.hash(data: payload)),
            searchableText: searchableText(for: snapshot)
        )
    }

    private static func encode(_ snapshot: AccessibilitySnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(snapshot)
        } catch {
            throw AccessibilitySnapshotCodecError.invalidPayload
        }
    }

    private static func validate(
        _ snapshot: AccessibilitySnapshot,
        permitsUnresolvedByteCount: Bool = false
    ) throws {
        guard !snapshot.nodes.isEmpty else {
            throw AccessibilitySnapshotCodecError.emptySnapshot
        }
        guard snapshot.nodes.count <= maximumVisitedNodeCount,
              snapshot.visitedNodeCount >= snapshot.nodes.count,
              snapshot.visitedNodeCount <= maximumVisitedNodeCount else {
            throw AccessibilitySnapshotCodecError.invalidNodeCount
        }
        guard snapshot.encodedByteCount >= 0,
              permitsUnresolvedByteCount || snapshot.encodedByteCount > 0 else {
            throw AccessibilitySnapshotCodecError.invalidEncodedByteCount
        }

        var seen = Set<AccessibilityNodeEvidence>()
        for (index, node) in snapshot.nodes.enumerated() {
            guard seen.insert(node).inserted else {
                throw AccessibilitySnapshotCodecError.duplicateNode(index)
            }
            guard node.depth >= 0, node.depth <= maximumDepth else {
                throw AccessibilitySnapshotCodecError.invalidDepth(index)
            }
            guard !isSecureRole(node.role),
                  normalizedText(node.role, maximumBytes: maximumRoleBytes) == node.role else {
                throw AccessibilitySnapshotCodecError.invalidRole(index)
            }
            guard node.label != nil || node.value != nil else {
                throw AccessibilitySnapshotCodecError.emptyNode(index)
            }
            for value in [node.label, node.value].compactMap({ $0 }) {
                guard normalizedText(value, maximumBytes: maximumTextBytes) == value else {
                    throw AccessibilitySnapshotCodecError.invalidText(index)
                }
            }
            if let bounds = node.bounds {
                let values = [bounds.x, bounds.y, bounds.width, bounds.height]
                guard values.allSatisfy(\.isFinite),
                      values.allSatisfy({ (0.0...1.0).contains($0) }),
                      bounds.width > 0,
                      bounds.height > 0,
                      bounds.x + bounds.width <= 1.000_001,
                      bounds.y + bounds.height <= 1.000_001 else {
                    throw AccessibilitySnapshotCodecError.invalidBounds(index)
                }
            }
        }
    }
}

package enum AccessibilitySnapshotCodecError: Error, Equatable, Sendable {
    case invalidPayload
    case nonCanonicalPayload
    case emptySnapshot
    case invalidNodeCount
    case invalidEncodedByteCount
    case encodedByteCountMismatch(expected: Int, actual: Int)
    case unstableEncoding
    case payloadTooLarge(Int)
    case duplicateNode(Int)
    case invalidDepth(Int)
    case invalidRole(Int)
    case emptyNode(Int)
    case invalidText(Int)
    case invalidBounds(Int)
}
