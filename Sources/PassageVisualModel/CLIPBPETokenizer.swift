import Foundation

public enum CLIPBPETokenizerError: Error, LocalizedError, Equatable, Sendable {
    case mergesUnavailable
    case mergesTooLarge
    case invalidMerges
    case incompatibleVocabulary
    case invalidText
    case tokenizationFailed

    public var errorDescription: String? {
        switch self {
        case .mergesUnavailable:
            "The visual model's tokenizer vocabulary is unavailable."
        case .mergesTooLarge:
            "The visual model's tokenizer vocabulary exceeds Passage's safety limit."
        case .invalidMerges:
            "The visual model's tokenizer vocabulary is invalid."
        case .incompatibleVocabulary:
            "The visual model's tokenizer vocabulary is incompatible."
        case .invalidText:
            "A visual search needs a short, non-empty description."
        case .tokenizationFailed:
            "Passage could not tokenize this visual search."
        }
    }
}

/// OpenAI CLIP's byte-level BPE tokenizer, implemented locally in Swift.
///
/// The model pack supplies the pinned, *uncompressed* merge text. Passage
/// never invokes Python, downloads tokenizer files, or writes query text to a
/// cache. Actor isolation keeps the bounded word-piece cache race-free.
public actor CLIPBPETokenizer {
    public static let maximumMergesBytes = 16 * 1_024 * 1_024
    public static let maximumInputCharacters = 8_192
    public static let expectedVocabularySize = 49_408

    private struct Pair: Hashable {
        var first: String
        var second: String
    }

    private let contextLength: Int
    private let startOfTextToken: Int32
    private let endOfTextToken: Int32
    private let paddingToken: Int32
    private let byteEncoder: [UInt8: String]
    private let encoder: [String: Int32]
    private let mergeRanks: [Pair: Int]
    private let tokenPattern: NSRegularExpression
    private var cache: [String: [String]] = [:]

    public init(
        uncompressedMergesURL: URL,
        contextLength: Int = 32,
        startOfTextToken: Int32 = 49_406,
        endOfTextToken: Int32 = 49_407,
        paddingToken: Int32 = 0,
        fileManager: FileManager = .default
    ) throws {
        guard contextLength >= 2, contextLength <= 4_096 else {
            throw CLIPBPETokenizerError.incompatibleVocabulary
        }
        let values = try? uncompressedMergesURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            throw CLIPBPETokenizerError.mergesUnavailable
        }
        guard let size = values?.fileSize, size <= Self.maximumMergesBytes else {
            throw CLIPBPETokenizerError.mergesTooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: uncompressedMergesURL, options: [.mappedIfSafe])
        } catch {
            throw CLIPBPETokenizerError.mergesUnavailable
        }
        guard data.count <= Self.maximumMergesBytes,
              let text = String(data: data, encoding: .utf8) else {
            throw CLIPBPETokenizerError.invalidMerges
        }
        try self.init(
            uncompressedMerges: text,
            contextLength: contextLength,
            startOfTextToken: startOfTextToken,
            endOfTextToken: endOfTextToken,
            paddingToken: paddingToken
        )
        _ = fileManager // Retains an injectable filesystem boundary for tests.
    }

    public init(
        uncompressedMerges: String,
        contextLength: Int = 32,
        startOfTextToken: Int32 = 49_406,
        endOfTextToken: Int32 = 49_407,
        paddingToken: Int32 = 0
    ) throws {
        guard contextLength >= 2, contextLength <= 4_096 else {
            throw CLIPBPETokenizerError.incompatibleVocabulary
        }
        let byteMapping = Self.makeByteEncoder()
        let parsedMerges = try Self.parseMerges(uncompressedMerges)
        let vocabulary = Self.makeVocabulary(byteMapping: byteMapping, merges: parsedMerges)
        guard vocabulary.count == Self.expectedVocabularySize,
              vocabulary.indices.contains(Int(startOfTextToken)),
              vocabulary.indices.contains(Int(endOfTextToken)),
              paddingToken >= 0,
              Int(paddingToken) < vocabulary.count else {
            throw CLIPBPETokenizerError.incompatibleVocabulary
        }
        var encoder: [String: Int32] = [:]
        encoder.reserveCapacity(vocabulary.count)
        for (index, token) in vocabulary.enumerated() {
            guard encoder.updateValue(Int32(index), forKey: token) == nil else {
                throw CLIPBPETokenizerError.incompatibleVocabulary
            }
        }
        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(parsedMerges.count)
        for (rank, merge) in parsedMerges.enumerated() {
            ranks[Pair(first: merge.0, second: merge.1)] = rank
        }
        let pattern = #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            throw CLIPBPETokenizerError.incompatibleVocabulary
        }

        self.contextLength = contextLength
        self.startOfTextToken = startOfTextToken
        self.endOfTextToken = endOfTextToken
        self.paddingToken = paddingToken
        self.byteEncoder = byteMapping.dictionary
        self.encoder = encoder
        self.mergeRanks = ranks
        self.tokenPattern = expression
    }

    public func tokenize(_ input: String) throws -> [Int32] {
        guard !input.isEmpty, input.count <= Self.maximumInputCharacters else {
            throw CLIPBPETokenizerError.invalidText
        }
        let cleaned = Self.clean(input)
        guard !cleaned.isEmpty else { throw CLIPBPETokenizerError.invalidText }
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        var tokens = [startOfTextToken]
        tokens.reserveCapacity(contextLength)

        for match in tokenPattern.matches(in: cleaned, range: range) {
            guard let tokenRange = Range(match.range, in: cleaned) else {
                throw CLIPBPETokenizerError.tokenizationFailed
            }
            let token = String(cleaned[tokenRange])
            var encodedBytes = ""
            encodedBytes.reserveCapacity(token.utf8.count)
            for byte in token.utf8 {
                guard let mapped = byteEncoder[byte] else {
                    throw CLIPBPETokenizerError.tokenizationFailed
                }
                encodedBytes += mapped
            }
            for piece in bpe(encodedBytes) {
                guard let identifier = encoder[piece] else {
                    throw CLIPBPETokenizerError.tokenizationFailed
                }
                tokens.append(identifier)
            }
        }

        tokens.append(endOfTextToken)
        if tokens.count > contextLength {
            tokens.removeSubrange(contextLength..<tokens.count)
            tokens[contextLength - 1] = endOfTextToken
        } else if tokens.count < contextLength {
            tokens.append(contentsOf: repeatElement(
                paddingToken,
                count: contextLength - tokens.count
            ))
        }
        return tokens
    }

    private func bpe(_ token: String) -> [String] {
        if let cached = cache[token] { return cached }
        var word = token.map(String.init)
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"

        while word.count > 1 {
            var bestPair: Pair?
            var bestRank = Int.max
            for index in 0..<(word.count - 1) {
                let pair = Pair(first: word[index], second: word[index + 1])
                if let rank = mergeRanks[pair], rank < bestRank {
                    bestPair = pair
                    bestRank = rank
                }
            }
            guard let bestPair else { break }

            var merged: [String] = []
            merged.reserveCapacity(word.count)
            var index = 0
            while index < word.count {
                if index + 1 < word.count,
                   word[index] == bestPair.first,
                   word[index + 1] == bestPair.second {
                    merged.append(bestPair.first + bestPair.second)
                    index += 2
                } else {
                    merged.append(word[index])
                    index += 1
                }
            }
            word = merged
        }

        if cache.count >= 4_096 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[token] = word
        return word
    }

    private static func parseMerges(_ text: String) throws -> [(String, String)] {
        let lines = text.split(whereSeparator: \Character.isNewline)
        // The official gzip payload has historically appeared both as a plain
        // `#version` line and with its source filename prefixed. OpenCLIP drops
        // the first line in either case; requiring the marker still rejects a
        // shifted or unrelated merge file.
        guard lines.first.map({ $0.contains("#version:") }) == true else {
            throw CLIPBPETokenizerError.invalidMerges
        }
        // OpenAI CLIP intentionally uses the first 48,894 merge rules.
        let mergeLines = lines.dropFirst().prefix(49_152 - 256 - 2)
        var merges: [(String, String)] = []
        merges.reserveCapacity(mergeLines.count)
        for line in mergeLines {
            let parts = line.split(whereSeparator: \Character.isWhitespace)
            guard parts.count == 2 else { throw CLIPBPETokenizerError.invalidMerges }
            merges.append((String(parts[0]), String(parts[1])))
        }
        guard merges.count == 48_894 else {
            throw CLIPBPETokenizerError.incompatibleVocabulary
        }
        return merges
    }

    private static func makeVocabulary(
        byteMapping: (ordered: [String], dictionary: [UInt8: String]),
        merges: [(String, String)]
    ) -> [String] {
        var vocabulary = byteMapping.ordered
        vocabulary.append(contentsOf: byteMapping.ordered.map { $0 + "</w>" })
        vocabulary.append(contentsOf: merges.map(+))
        vocabulary.append("<|startoftext|>")
        vocabulary.append("<|endoftext|>")
        return vocabulary
    }

    private static func makeByteEncoder() -> (
        ordered: [String],
        dictionary: [UInt8: String]
    ) {
        var bytes = Array(33...126) + Array(161...172) + Array(174...255)
        var codePoints = bytes
        var next = 0
        for byte in 0...255 where !bytes.contains(byte) {
            bytes.append(byte)
            codePoints.append(256 + next)
            next += 1
        }
        var ordered: [String] = []
        var dictionary: [UInt8: String] = [:]
        ordered.reserveCapacity(256)
        dictionary.reserveCapacity(256)
        for (byte, codePoint) in zip(bytes, codePoints) {
            let value = String(UnicodeScalar(codePoint)!)
            ordered.append(value)
            dictionary[UInt8(byte)] = value
        }
        return (ordered, dictionary)
    }

    private static func clean(_ input: String) -> String {
        // FTFY, used by OpenCLIP, folds presentation-width variants before
        // BPE. Foundation's compatibility composition gives the same stable
        // behavior for ordinary Unicode queries without a Python dependency.
        var cleaned = input.precomposedStringWithCompatibilityMapping
        cleaned = unescapeHTMLEntities(cleaned)
        cleaned = unescapeHTMLEntities(cleaned)
        // OpenCLIP's FTFY cleaning uncurls typographic quotes before byte BPE.
        // Preserve that exact model contract without importing a general text
        // rewriting dependency (dashes and other punctuation stay untouched).
        cleaned = cleaned
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
        cleaned = cleaned.lowercased()
        return cleaned
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }

    private static func unescapeHTMLEntities(_ input: String) -> String {
        let named: [Substring: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"",
            "apos": "'", "nbsp": " ", "copy": "©", "trade": "™",
        ]
        var output = ""
        output.reserveCapacity(input.count)
        var index = input.startIndex
        while index < input.endIndex {
            guard input[index] == "&",
                  let semicolon = input[index...].firstIndex(of: ";"),
                  input.distance(from: index, to: semicolon) <= 16 else {
                output.append(input[index])
                index = input.index(after: index)
                continue
            }
            let bodyStart = input.index(after: index)
            let body = input[bodyStart..<semicolon]
            let replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16)
                    .flatMap(UnicodeScalar.init)
                    .map(String.init)
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst(), radix: 10)
                    .flatMap(UnicodeScalar.init)
                    .map(String.init)
            } else {
                replacement = named[body.lowercased()[...]]
            }
            guard let replacement else {
                output.append(contentsOf: input[index...semicolon])
                index = input.index(after: semicolon)
                continue
            }
            output.append(replacement)
            index = input.index(after: semicolon)
        }
        return output
    }
}
