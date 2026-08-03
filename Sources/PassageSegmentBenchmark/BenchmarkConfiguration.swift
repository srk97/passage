import Foundation

enum BenchmarkProfile: String, Codable, Sendable {
    case smoke
    case million
}

struct BenchmarkConfiguration: Codable, Sendable {
    static let millionFrameCount = 1_000_000
    static let smokeFrameCount = 20_000
    static let millionSampleCount = 50
    static let smokeSampleCount = 5
    static let batchSize = 5_000
    static let framesPerSession = 100
    static let contextKeyCount = 4
    static let pageLimit = 50
    static let captureProbeCount = 50
    static let millionRunCount = 3
    static let smokeRunCount = 1

    var profile: BenchmarkProfile
    var runOrdinal: Int
    var frameCount: Int
    var sampleCount: Int
    var batchSize: Int
    var framesPerSession: Int
    var contextKeyCount: Int
    var pageLimit: Int
    var captureProbeCount: Int
    var outputPath: String?

    var requiredRunCount: Int {
        profile == .million ? Self.millionRunCount : Self.smokeRunCount
    }

    var freshConnectionSampleCount: Int { sampleCount }

    static func parse(_ arguments: [String]) throws -> Self {
        var values = [String: String]()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--help" || argument == "-h" {
                throw BenchmarkArgumentError.helpRequested
            }
            guard argument.hasPrefix("--") else {
                throw BenchmarkArgumentError.unknownArgument(argument)
            }
            guard index + 1 < arguments.count else {
                throw BenchmarkArgumentError.missingValue(argument)
            }
            let value = arguments[index + 1]
            guard !value.hasPrefix("--") else {
                throw BenchmarkArgumentError.missingValue(argument)
            }
            guard values.updateValue(value, forKey: argument) == nil else {
                throw BenchmarkArgumentError.duplicateArgument(argument)
            }
            index += 2
        }

        let rawProfile = values.removeValue(forKey: "--profile") ?? BenchmarkProfile.smoke.rawValue
        guard let profile = BenchmarkProfile(rawValue: rawProfile) else {
            throw BenchmarkArgumentError.invalidValue("--profile", rawProfile)
        }
        let defaultFrameCount = profile == .million ? millionFrameCount : smokeFrameCount
        let defaultSampleCount = profile == .million ? millionSampleCount : smokeSampleCount
        let configuration = Self(
            profile: profile,
            runOrdinal: try integer(
                values.removeValue(forKey: "--run"),
                option: "--run",
                default: 1
            ),
            frameCount: try integer(
                values.removeValue(forKey: "--frames"),
                option: "--frames",
                default: defaultFrameCount
            ),
            sampleCount: try integer(
                values.removeValue(forKey: "--samples"),
                option: "--samples",
                default: defaultSampleCount
            ),
            batchSize: try integer(
                values.removeValue(forKey: "--batch-size"),
                option: "--batch-size",
                default: batchSize
            ),
            framesPerSession: framesPerSession,
            contextKeyCount: contextKeyCount,
            pageLimit: try integer(
                values.removeValue(forKey: "--page-limit"),
                option: "--page-limit",
                default: pageLimit
            ),
            captureProbeCount: try integer(
                values.removeValue(forKey: "--capture-probe-count"),
                option: "--capture-probe-count",
                default: captureProbeCount
            ),
            outputPath: values.removeValue(forKey: "--output")
        )

        if let unknown = values.keys.sorted().first {
            throw BenchmarkArgumentError.unknownArgument(unknown)
        }
        try configuration.validateFrozenProtocol()
        return configuration
    }

    static let usage = """
    Usage: passage-segment-benchmark [options]

      --profile smoke|million       Frozen preset (default: smoke)
      --run N                       One-based run ordinal
      --frames N                    Must equal the selected preset
      --samples N                   Must equal the selected preset
      --batch-size N                Frozen at 5,000
      --page-limit N                Frozen at 50
      --capture-probe-count N       Frozen at 50
      --output PATH                 Also write the JSON report to PATH
      --help                        Show this help

    The million acceptance protocol is exactly three independent runs over one
    million deterministic frames, with 50 samples per workload. Both profiles
    freeze 100 frames/session, four context keys, 5,000-frame seed batches,
    50-result pages, and 50 capture probes. Smoke uses 20,000 frames and five
    samples to exercise the complete protocol without supporting scale claims.
    """

    private func validateFrozenProtocol() throws {
        let expectedFrameCount = profile == .million
            ? Self.millionFrameCount : Self.smokeFrameCount
        let expectedSampleCount = profile == .million
            ? Self.millionSampleCount : Self.smokeSampleCount
        guard frameCount == expectedFrameCount,
              sampleCount == expectedSampleCount,
              batchSize == Self.batchSize,
              framesPerSession == Self.framesPerSession,
              contextKeyCount == Self.contextKeyCount,
              pageLimit == Self.pageLimit,
              captureProbeCount == Self.captureProbeCount,
              runOrdinal >= 1,
              runOrdinal <= requiredRunCount else {
            throw BenchmarkArgumentError.protocolMismatch(profile)
        }
    }

    private static func integer(
        _ rawValue: String?,
        option: String,
        default defaultValue: Int
    ) throws -> Int {
        guard let rawValue else { return defaultValue }
        guard let value = Int(rawValue), value > 0 else {
            throw BenchmarkArgumentError.invalidValue(option, rawValue)
        }
        return value
    }
}

enum BenchmarkArgumentError: Error, LocalizedError {
    case helpRequested
    case unknownArgument(String)
    case missingValue(String)
    case duplicateArgument(String)
    case invalidValue(String, String)
    case protocolMismatch(BenchmarkProfile)

    var errorDescription: String? {
        switch self {
        case .helpRequested:
            return nil
        case let .unknownArgument(argument):
            return "Unknown argument: \(argument)"
        case let .missingValue(argument):
            return "Missing value for \(argument)"
        case let .duplicateArgument(argument):
            return "Duplicate argument: \(argument)"
        case let .invalidValue(argument, value):
            return "Invalid value for \(argument): \(value)"
        case let .protocolMismatch(profile):
            return "Arguments do not match the frozen \(profile.rawValue) benchmark protocol."
        }
    }
}
