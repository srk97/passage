import PassageCore
import Foundation

/// Compact, self-identifying storage for OCR regions.
///
/// Region text is represented as a UTF-8 byte range into the frame's canonical
/// `ocrText`. Confidence and normalized geometry use 16-bit fixed-point values.
/// Blobs that do not start with the binary magic are decoded as the legacy JSON
/// representation so existing encrypted stores remain readable.
///
/// Version 1 layout: `CRGN`, version, flags, canonical UTF-8 byte count (varint),
/// region count (varint), then per-region offset/length varints followed by five
/// little-endian UInt16 values: confidence, x, y, width, and height.
package enum OCRRegionCodec {
    private static let magic: [UInt8] = [0x43, 0x52, 0x47, 0x4E] // "CRGN"
    private static let version: UInt8 = 1
    private static let flags: UInt8 = 0
    private static let fixedFieldBytesPerRegion = 10
    private static let maximumCanonicalTextBytes = 64 * 1_024 * 1_024
    private static let maximumRegionCount = 65_535
    private static let maximumBlobBytes = 16 * 1_024 * 1_024
    private static let normalizedScale = Double(UInt16.max)

    package static func encode(
        _ regions: [OCRRegion],
        canonicalText: String
    ) throws -> Data {
        let textBytes = Data(canonicalText.utf8)
        guard textBytes.count <= maximumCanonicalTextBytes else {
            throw OCRRegionCodecError.canonicalTextTooLarge(textBytes.count)
        }
        guard regions.count <= maximumRegionCount else {
            throw OCRRegionCodecError.tooManyRegions(regions.count)
        }

        let ranges = try textRanges(for: regions, in: canonicalText)
        var encoded = Data()
        encoded.reserveCapacity(
            magic.count + 2 + 10 + regions.count * (fixedFieldBytesPerRegion + 4)
        )
        encoded.append(contentsOf: magic)
        encoded.append(version)
        encoded.append(flags)
        appendVarUInt(UInt64(textBytes.count), to: &encoded)
        appendVarUInt(UInt64(regions.count), to: &encoded)

        for (index, region) in regions.enumerated() {
            let confidence = try normalizedUInt16(
                Double(region.confidence),
                field: "confidence",
                regionIndex: index
            )
            let x = try normalizedUInt16(region.x, field: "x", regionIndex: index)
            let y = try normalizedUInt16(region.y, field: "y", regionIndex: index)
            var width = try normalizedUInt16(region.width, field: "width", regionIndex: index)
            var height = try normalizedUInt16(region.height, field: "height", regionIndex: index)
            guard region.x + region.width <= 1.000_001,
                  region.y + region.height <= 1.000_001 else {
                throw OCRRegionCodecError.geometryOutOfBounds(regionIndex: index)
            }

            // Independent rounding can put an otherwise valid normalized edge
            // one quantization step beyond 1.0. Keep the stored rectangle valid.
            if UInt32(x) + UInt32(width) > UInt32(UInt16.max) {
                width = UInt16.max - x
            }
            if UInt32(y) + UInt32(height) > UInt32(UInt16.max) {
                height = UInt16.max - y
            }

            appendVarUInt(UInt64(ranges[index].offset), to: &encoded)
            appendVarUInt(UInt64(ranges[index].length), to: &encoded)
            appendLittleEndian(confidence, to: &encoded)
            appendLittleEndian(x, to: &encoded)
            appendLittleEndian(y, to: &encoded)
            appendLittleEndian(width, to: &encoded)
            appendLittleEndian(height, to: &encoded)
        }

        guard encoded.count <= maximumBlobBytes else {
            throw OCRRegionCodecError.blobTooLarge(encoded.count)
        }
        return encoded
    }

    package static func decode(
        _ data: Data,
        canonicalText: String
    ) throws -> [OCRRegion] {
        if data.isEmpty {
            return []
        }
        guard data.count <= maximumBlobBytes else {
            throw OCRRegionCodecError.blobTooLarge(data.count)
        }
        if data.starts(with: magic) {
            return try decodeBinary(data, canonicalText: canonicalText)
        }
        return try decodeLegacyJSON(data)
    }

    private static func decodeBinary(
        _ data: Data,
        canonicalText: String
    ) throws -> [OCRRegion] {
        var reader = BinaryReader(data: data)
        for expectedByte in magic {
            guard try reader.readByte() == expectedByte else {
                throw OCRRegionCodecError.invalidHeader
            }
        }
        let storedVersion = try reader.readByte()
        guard storedVersion == version else {
            throw OCRRegionCodecError.unsupportedVersion(storedVersion)
        }
        let storedFlags = try reader.readByte()
        guard storedFlags == flags else {
            throw OCRRegionCodecError.unsupportedFlags(storedFlags)
        }

        let expectedTextByteCount = try reader.readIntVarUInt()
        let canonicalBytes = Data(canonicalText.utf8)
        guard expectedTextByteCount == canonicalBytes.count else {
            throw OCRRegionCodecError.canonicalTextLengthMismatch(
                expected: expectedTextByteCount,
                actual: canonicalBytes.count
            )
        }
        guard canonicalBytes.count <= maximumCanonicalTextBytes else {
            throw OCRRegionCodecError.canonicalTextTooLarge(canonicalBytes.count)
        }

        let regionCount = try reader.readIntVarUInt()
        guard regionCount <= maximumRegionCount else {
            throw OCRRegionCodecError.tooManyRegions(regionCount)
        }
        guard regionCount <= reader.remainingBytes / (fixedFieldBytesPerRegion + 2) else {
            throw OCRRegionCodecError.truncated
        }

        var regions: [OCRRegion] = []
        regions.reserveCapacity(regionCount)
        for index in 0..<regionCount {
            let textOffset = try reader.readIntVarUInt()
            let textLength = try reader.readIntVarUInt()
            guard textOffset <= canonicalBytes.count,
                  textLength <= canonicalBytes.count - textOffset else {
                throw OCRRegionCodecError.textRangeOutOfBounds(
                    regionIndex: index,
                    offset: textOffset,
                    length: textLength
                )
            }

            let confidence = try reader.readUInt16()
            let x = try reader.readUInt16()
            let y = try reader.readUInt16()
            let width = try reader.readUInt16()
            let height = try reader.readUInt16()
            guard UInt32(x) + UInt32(width) <= UInt32(UInt16.max),
                  UInt32(y) + UInt32(height) <= UInt32(UInt16.max) else {
                throw OCRRegionCodecError.geometryOutOfBounds(regionIndex: index)
            }

            let textData = canonicalBytes.subdata(in: textOffset..<(textOffset + textLength))
            guard let text = String(data: textData, encoding: .utf8) else {
                throw OCRRegionCodecError.invalidUTF8Range(regionIndex: index)
            }
            regions.append(OCRRegion(
                text: text,
                confidence: Float(Double(confidence) / normalizedScale),
                x: Double(x) / normalizedScale,
                y: Double(y) / normalizedScale,
                width: Double(width) / normalizedScale,
                height: Double(height) / normalizedScale
            ))
        }
        guard reader.remainingBytes == 0 else {
            throw OCRRegionCodecError.trailingBytes(reader.remainingBytes)
        }
        return regions
    }

    private static func decodeLegacyJSON(_ data: Data) throws -> [OCRRegion] {
        let regions: [OCRRegion]
        do {
            regions = try JSONDecoder().decode([OCRRegion].self, from: data)
        } catch {
            throw OCRRegionCodecError.invalidLegacyJSON
        }
        guard regions.count <= maximumRegionCount else {
            throw OCRRegionCodecError.tooManyRegions(regions.count)
        }
        for (index, region) in regions.enumerated() {
            _ = try normalizedUInt16(
                Double(region.confidence),
                field: "confidence",
                regionIndex: index
            )
            _ = try normalizedUInt16(region.x, field: "x", regionIndex: index)
            _ = try normalizedUInt16(region.y, field: "y", regionIndex: index)
            _ = try normalizedUInt16(region.width, field: "width", regionIndex: index)
            _ = try normalizedUInt16(region.height, field: "height", regionIndex: index)
            guard region.x + region.width <= 1.000_001,
                  region.y + region.height <= 1.000_001 else {
                throw OCRRegionCodecError.geometryOutOfBounds(regionIndex: index)
            }
        }
        return regions
    }

    private static func textRanges(
        for regions: [OCRRegion],
        in canonicalText: String
    ) throws -> [(offset: Int, length: Int)] {
        var searchStart = canonicalText.startIndex
        let utf8 = canonicalText.utf8
        var ranges: [(offset: Int, length: Int)] = []
        ranges.reserveCapacity(regions.count)

        for (index, region) in regions.enumerated() {
            guard let range = canonicalText.range(
                of: region.text,
                options: [.literal],
                range: searchStart..<canonicalText.endIndex
            ),
            let utf8Start = range.lowerBound.samePosition(in: utf8),
            let utf8End = range.upperBound.samePosition(in: utf8) else {
                throw OCRRegionCodecError.regionTextNotFound(regionIndex: index)
            }
            ranges.append((
                offset: utf8.distance(from: utf8.startIndex, to: utf8Start),
                length: utf8.distance(from: utf8Start, to: utf8End)
            ))
            searchStart = range.upperBound
        }
        return ranges
    }

    private static func normalizedUInt16(
        _ value: Double,
        field: String,
        regionIndex: Int
    ) throws -> UInt16 {
        guard value.isFinite else {
            throw OCRRegionCodecError.nonFiniteValue(regionIndex: regionIndex, field: field)
        }
        guard (0.0...1.0).contains(value) else {
            throw OCRRegionCodecError.valueOutOfRange(regionIndex: regionIndex, field: field)
        }
        return UInt16((value * normalizedScale).rounded())
    }

    private static func appendVarUInt(_ value: UInt64, to data: inout Data) {
        var remainder = value
        repeat {
            var byte = UInt8(remainder & 0x7F)
            remainder >>= 7
            if remainder != 0 {
                byte |= 0x80
            }
            data.append(byte)
        } while remainder != 0
    }

    private static func appendLittleEndian(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

package enum OCRRegionCodecError: Error, Equatable, Sendable {
    case invalidHeader
    case unsupportedVersion(UInt8)
    case unsupportedFlags(UInt8)
    case truncated
    case invalidVarUInt
    case integerOverflow
    case blobTooLarge(Int)
    case canonicalTextTooLarge(Int)
    case tooManyRegions(Int)
    case canonicalTextLengthMismatch(expected: Int, actual: Int)
    case regionTextNotFound(regionIndex: Int)
    case textRangeOutOfBounds(regionIndex: Int, offset: Int, length: Int)
    case invalidUTF8Range(regionIndex: Int)
    case nonFiniteValue(regionIndex: Int, field: String)
    case valueOutOfRange(regionIndex: Int, field: String)
    case geometryOutOfBounds(regionIndex: Int)
    case trailingBytes(Int)
    case invalidLegacyJSON
}

private struct BinaryReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(data: Data) {
        bytes = Array(data)
    }

    var remainingBytes: Int {
        bytes.count - offset
    }

    mutating func readByte() throws -> UInt8 {
        guard offset < bytes.count else {
            throw OCRRegionCodecError.truncated
        }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let low = UInt16(try readByte())
        let high = UInt16(try readByte())
        return low | (high << 8)
    }

    mutating func readIntVarUInt() throws -> Int {
        let value = try readVarUInt()
        guard value <= UInt64(Int.max) else {
            throw OCRRegionCodecError.integerOverflow
        }
        return Int(value)
    }

    private mutating func readVarUInt() throws -> UInt64 {
        var value: UInt64 = 0
        for byteIndex in 0..<10 {
            let byte = try readByte()
            let payload = UInt64(byte & 0x7F)
            if byteIndex == 9, payload > 1 {
                throw OCRRegionCodecError.integerOverflow
            }
            value |= payload << UInt64(byteIndex * 7)
            if byte & 0x80 == 0 {
                return value
            }
        }
        throw OCRRegionCodecError.invalidVarUInt
    }
}
