import Foundation

enum DateTimeBenchmark {
    private static let strings = [
        "1969-12-31T23:59:59Z", "1970-01-01T00:00:00Z",
        "2026-09-15T23:30:00Z", "2038-01-19T03:14:07Z",
    ]
    private static let format = Date.ISO8601FormatStyle(timeZone: .gmt)

    static func run() throws {
        let seconds = try strings.map { try dateTimeUnixSeconds($0) }
        let dates = seconds.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        for index in strings.indices {
            let previous = try previousSeconds(strings[index])
            precondition(previous == seconds[index])
            precondition(Int64(dates[index].timeIntervalSince1970) == seconds[index])
            precondition(dates[index].formatted(format) == dateTimeStringFromUnixSeconds(seconds[index]))
        }
        try compareStringParsing()
        try compareNativeDates(dates)
        compareFormatting(seconds)
        print("Whole-second valid values only; fractional and ancient correctness is tested separately.")
        print("No network, generated model serialization or allocation measurement included.")
    }

    private static func compareStringParsing() throws {
        try TransportMetadataBenchmark.compare(
            "DateTime string to seconds", iterations: 500, warmup: 100,
            before: { UInt64(bitPattern: try previousSeconds(strings[$0 & 3])) },
            after: { UInt64(bitPattern: try dateTimeUnixSeconds(strings[$0 & 3])) })
    }

    private static func compareNativeDates(_ dates: [Date]) throws {
        try TransportMetadataBenchmark.compare(
            "Native Date to seconds",
            before: { UInt64(bitPattern: Int64(dates[$0 & 3].timeIntervalSince1970)) },
            after: { UInt64(bitPattern: try dateTimeUnixSeconds(dates[$0 & 3])) })
    }

    private static func compareFormatting(_ seconds: [Int64]) {
        TransportMetadataBenchmark.compare(
            "Modern seconds to DateTime", iterations: 10_000, warmup: 1000,
            before: {
                let date = Date(timeIntervalSince1970: TimeInterval(seconds[$0 & 3]))
                return UInt64(date.formatted(format).utf8.count)
            },
            after: { UInt64(dateTimeStringFromUnixSeconds(seconds[$0 & 3]).utf8.count) })
    }

    // Frozen pre-fix string parser; only correct inputs may be timed against it.
    private static func previousSeconds(_ value: String) throws -> Int64 {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw LuxoError(code: 0, message: "invalid DateTime value", name: "ConfigError")
        }
        return Int64(date.timeIntervalSince1970)
    }
}
