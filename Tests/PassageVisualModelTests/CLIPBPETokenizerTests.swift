@testable import PassageVisualModel
import Foundation
import Testing

struct CLIPBPETokenizerTests {
    @Test("Swift byte BPE matches authoritative OpenCLIP token vectors")
    func openCLIPParity() async throws {
        let mergesURL = Bundle.module.url(
            forResource: "bpe_simple_vocab_16e6",
            withExtension: "txt",
            subdirectory: "Fixtures"
        )
        let tokenizer = try CLIPBPETokenizer(
            uncompressedMergesURL: try #require(mergesURL)
        )

        let cases: [(String, [Int32])] = [
            ("a man", [49_406, 320, 786, 49_407]),
            ("a man with glasses", [49_406, 320, 786, 593, 6_116, 49_407]),
            ("Harry Potter", [49_406, 3_600, 9_026, 49_407]),
            (
                "Café — 東京 👓",
                [49_406, 15_304, 2_005, 48_338, 21_078, 361, 964, 497, 49_407]
            ),
            ("Fish &amp;amp; Chips", [49_406, 2_759, 261, 8_855, 49_407]),
            ("  multiple\n\tspaces  ", [49_406, 6_470, 9_006, 49_407]),
            ("Ｆｕｌｌｗｉｄｔｈ", [49_406, 9_407, 23_571, 49_407]),
            (
                "Punctuation!? ... [brackets] {braces} /slash\\backslash — “quotes”",
                [
                    49_406, 47_051, 6_004, 678, 314, 36_183, 316, 346,
                    19_249, 348, 270, 19_749, 315, 1_663, 19_749, 2_005,
                    257, 5_808, 257, 49_407,
                ]
            ),
            ("‘Quoted’", [49_406, 262, 27_706, 262, 49_407]),
        ]

        for (text, prefix) in cases {
            let tokens = try await tokenizer.tokenize(text)
            #expect(tokens.count == 32)
            #expect(Array(tokens.prefix(prefix.count)) == prefix)
            #expect(tokens.dropFirst(prefix.count).allSatisfy { $0 == 0 })
        }
    }

    @Test("Long prompts truncate deterministically and retain end of text")
    func truncation() async throws {
        let mergesURL = Bundle.module.url(
            forResource: "bpe_simple_vocab_16e6",
            withExtension: "txt",
            subdirectory: "Fixtures"
        )
        let tokenizer = try CLIPBPETokenizer(
            uncompressedMergesURL: try #require(mergesURL)
        )
        let text = Array(repeating: "glasses", count: 50).joined(separator: " ")
        let expected = [Int32(49_406)]
            + Array(repeating: Int32(6_116), count: 30)
            + [Int32(49_407)]
        #expect(try await tokenizer.tokenize(text) == expected)
    }

    @Test("Empty and unbounded input fails before model inference")
    func inputBounds() async throws {
        let mergesURL = Bundle.module.url(
            forResource: "bpe_simple_vocab_16e6",
            withExtension: "txt",
            subdirectory: "Fixtures"
        )
        let tokenizer = try CLIPBPETokenizer(
            uncompressedMergesURL: try #require(mergesURL)
        )
        await #expect(throws: CLIPBPETokenizerError.self) {
            try await tokenizer.tokenize(" \n\t ")
        }
        await #expect(throws: CLIPBPETokenizerError.self) {
            try await tokenizer.tokenize(String(repeating: "x", count: 8_193))
        }
    }
}
