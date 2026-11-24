import Foundation

// Zero is always within Foundation's valid offset range; .gmt requires iOS 16.
private let timestampTimeZone = TimeZone(secondsFromGMT: 0)!
private let timestampFormat = Date.ISO8601FormatStyle(timeZone: timestampTimeZone)

struct DateTimeParts {
    let seconds: Int64
    let nanoseconds: UInt64
}

func validDateTimeSeconds(_ seconds: Int64) -> Bool {
    seconds >= -62_167_219_200 && seconds <= 253_402_300_799
}

/// Validate typed JSON responses without converting a document or rounding.
public func validateDateTime(_ value: String) throws {
    do { _ = try dateTimeParts(value) } catch {
        throw LuxoError(code: 0, message: "invalid DateTime response", name: "DecodeError")
    }
}
public func validateDateTime(_ value: String?) throws { if let value { try validateDateTime(value) } }
public func validateDateTime(_ value: [String]) throws { for item in value { try validateDateTime(item) } }
public func validateDateTime(_ value: [String]?) throws { if let value { try validateDateTime(value) } }

// Parse whole seconds before constructing Date: its floating representation can
// round .999999999 into the next second, especially near the calendar limits.
func dateTimeUnixSeconds(_ value: String) throws -> Int64 {
    try dateTimeParts(value).seconds
}

func dateTimeParts(_ value: String) throws -> DateTimeParts {
    var source = value
    let offset = try source.withUTF8 { try validateTimestampLayout($0) }
    if source.contains("t") || source.hasSuffix("z") {
        source = source.replacingOccurrences(of: "t", with: "T").replacingOccurrences(of: "z", with: "Z")
    }
    let (whole, nanos) = try wholeSecondTimestamp(source)
    let localUTC = whole.hasSuffix("Z") ? whole : String(whole.prefix(19)) + "Z"
    let date =
        localUTC < "1583"
        ? prolepticTimestampFormatter.date(from: localUTC)
        : try? timestampFormat.parse(localUTC)
    guard let date else {
        throw invalidTimestamp()
    }
    let seconds = try dateTimeUnixSeconds(date) - offset
    guard validDateTimeSeconds(seconds) else { throw invalidTimestamp() }
    return DateTimeParts(seconds: seconds, nanoseconds: nanos)
}

// A native Date can only preserve the precision already present in its Double.
// String inputs never take this floating-point conversion path.
func dateTimeParts(_ value: Date) throws -> DateTimeParts {
    let seconds = try dateTimeUnixSeconds(value)
    let fraction = value.timeIntervalSince1970 - Double(seconds)
    let nanos = UInt64((fraction * 1_000_000_000).rounded(.toNearestOrEven))
    if nanos < 1_000_000_000 { return DateTimeParts(seconds: seconds, nanoseconds: nanos) }
    let (next, overflow) = seconds.addingReportingOverflow(1)
    guard !overflow, validDateTimeSeconds(next) else { throw invalidTimestamp() }
    return DateTimeParts(seconds: next, nanoseconds: 0)
}

func dateTimeString(_ parts: DateTimeParts) -> String {
    let whole = dateTimeStringFromUnixSeconds(parts.seconds)
    guard parts.nanoseconds != 0 else { return whole }
    let digits = String(parts.nanoseconds)
    var fraction = String(repeating: "0", count: 9 - digits.count) + digits
    while fraction.last == "0" { fraction.removeLast() }
    return String(whole.dropLast()) + "." + fraction + "Z"
}

// Foundation's ISO style applies a historical Gregorian cutover. The protocol
// uses the proleptic Gregorian calendar, like Go, including years 0000 and 0001.
// Keep the existing value-style fast path for dates after the reform year.
func dateTimeStringFromUnixSeconds(_ seconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(seconds))
    if seconds < -12_219_292_800 {
        return prolepticTimestampFormatter.string(from: date)
    }
    return date.formatted(timestampFormat)
}

// Configure once, then never mutate or expose this Foundation formatter.
private let prolepticTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timestampTimeZone
    formatter.dateFormat = "uuuu-MM-dd'T'HH:mm:ssXXXXX"
    formatter.isLenient = false
    formatter.gregorianStartDate = Date(timeIntervalSince1970: -62_167_219_200 - 172_800)
    return formatter
}()

func dateTimeUnixSeconds(_ value: Date) throws -> Int64 {
    guard let seconds = Int64(exactly: value.timeIntervalSince1970.rounded(.down)), validDateTimeSeconds(seconds) else {
        throw invalidTimestamp()
    }
    return seconds
}

private func timestampNumber(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ count: Int) throws -> Int {
    var number = 0
    for index in start..<(start + count) {
        guard bytes[index] >= 48, bytes[index] <= 57 else { throw invalidTimestamp() }
        number = number * 10 + Int(bytes[index] - 48)
    }
    return number
}

private func validateTimestampLayout(_ bytes: UnsafeBufferPointer<UInt8>) throws -> Int64 {
    guard bytes.count >= 20, bytes.count <= 35, bytes[4] == 45, bytes[7] == 45,
        bytes[10] == 84 || bytes[10] == 116, bytes[13] == 58, bytes[16] == 58
    else { throw invalidTimestamp() }
    let year = try timestampNumber(bytes, 0, 4)
    let month = try timestampNumber(bytes, 5, 2)
    let day = try timestampNumber(bytes, 8, 2)
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let days = month == 2 ? (leap ? 29 : 28) : (month == 4 || month == 6 || month == 9 || month == 11 ? 30 : 31)
    guard month >= 1, month <= 12, day >= 1, day <= days,
        try timestampNumber(bytes, 11, 2) <= 23,
        try timestampNumber(bytes, 14, 2) <= 59,
        try timestampNumber(bytes, 17, 2) <= 59
    else { throw invalidTimestamp() }
    var zone = 19
    if bytes[zone] == 46 {
        zone += 1
        while zone < bytes.count, bytes[zone] >= 48, bytes[zone] <= 57 { zone += 1 }
        guard zone > 20, zone <= 29 else { throw invalidTimestamp() }
    }
    guard zone < bytes.count else { throw invalidTimestamp() }
    if bytes[zone] == 90 || bytes[zone] == 122 {
        guard zone + 1 == bytes.count else { throw invalidTimestamp() }
        return 0
    }
    guard bytes.count - zone == 6, bytes[zone] == 43 || bytes[zone] == 45, bytes[zone + 3] == 58,
        try timestampNumber(bytes, zone + 1, 2) <= 23,
        try timestampNumber(bytes, zone + 4, 2) <= 59
    else { throw invalidTimestamp() }
    let offset = try timestampNumber(bytes, zone + 1, 2) * 3600 + timestampNumber(bytes, zone + 4, 2) * 60
    return Int64(offset) * (bytes[zone] == 45 ? -1 : 1)
}

private func wholeSecondTimestamp(_ value: String) throws -> (String, UInt64) {
    let bytes = value.utf8
    guard let point = bytes.index(bytes.startIndex, offsetBy: 19, limitedBy: bytes.endIndex),
        point != bytes.endIndex, bytes[point] == 46
    else { return (value, 0) }
    let first = bytes.index(after: point)
    var zone = first
    var nanos: UInt64 = 0
    var digits = 0
    while zone != bytes.endIndex, bytes[zone] >= 48, bytes[zone] <= 57 {
        guard digits < 9 else { throw invalidTimestamp() }
        nanos = nanos * 10 + UInt64(bytes[zone] - 48)
        digits += 1
        bytes.formIndex(after: &zone)
    }
    guard zone != first, zone != bytes.endIndex,
        bytes[zone] == 90 || bytes[zone] == 43 || bytes[zone] == 45
    else { throw invalidTimestamp() }
    var whole = String(value[..<point])
    whole.append(contentsOf: value[zone...])
    for _ in digits..<9 { nanos *= 10 }
    return (whole, nanos)
}

private func invalidTimestamp() -> LuxoError {
    LuxoError(code: 0, message: "invalid DateTime value", name: "ConfigError")
}
