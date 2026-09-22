import Foundation

/// Frozen pre-fix parsing is only a benchmark baseline for valid input.
@main
enum TransportMetadataBenchmark {
    static func main() async throws {
        if CommandLine.arguments.contains("--schema-registration") {
            try SchemaRegistrationBenchmark.run()
            return
        }
        if CommandLine.arguments.contains("--field-masks") {
            try FieldMaskBenchmark.run()
            return
        }
        #if LUXO_PROJECTION_BENCHMARK
            if CommandLine.arguments.contains("--projection") {
                try JSONProjectionBenchmark.run()
                return
            }
        #endif
        #if LUXO_JSON_FAILURE_BENCHMARK
            if CommandLine.arguments.contains("--json-failure") {
                try await WebSocketJSONFailureBenchmark.run()
                return
            }
        #endif
        #if LUXO_DECODING_BENCHMARK
            if CommandLine.arguments.contains("--decoding") {
                try await WebSocketDecodingBenchmark.run()
                return
            }
        #endif
        #if LUXO_PAYLOAD_BENCHMARK
            if CommandLine.arguments.contains("--payload-mode") {
                try await TransportPayloadBenchmark.run()
                return
            }
        #endif
        #if LUXO_DISCONNECT_BENCHMARK
            if CommandLine.arguments.contains("--disconnect") {
                try await WebSocketDisconnectBenchmark.run()
                return
            }
        #endif
        if CommandLine.arguments.contains("--stream-terminals") {
            try await WebSocketSubscriptionBenchmark.runTerminals()
            return
        }
        if CommandLine.arguments.contains("--json-envelopes") {
            try JSONEnvelopeBenchmark.run()
            return
        }
        if CommandLine.arguments.contains("--subscriptions") {
            try await WebSocketSubscriptionBenchmark.run()
            return
        }
        if CommandLine.arguments.contains("--date-time") {
            try DateTimeBenchmark.run()
            return
        }
        if CommandLine.arguments.contains("--json-typed-responses") {
            try JSONParameterBenchmark.runTypedResponses()
            return
        }
        #if LUXO_METADATA_BENCHMARK
            if CommandLine.arguments.contains("--codec-metadata") {
                try CodecMetadataBenchmark.run()
                return
            }
        #endif
        if CommandLine.arguments.contains("--json-params") {
            try JSONParameterBenchmark.run()
            return
        }
        if CommandLine.arguments.contains("--json-values") {
            try JSONParameterBenchmark.runValues()
            return
        }
        if CommandLine.arguments.contains("--errors") {
            try ErrorResponseBenchmark.run()
            return
        }
        if CommandLine.arguments.contains("--inputs") {
            try TypedInputBenchmark.run()
            return
        }
        if CommandLine.arguments.contains("--frames") {
            try WebSocketFrameBenchmark.run()
            return
        }
        let ids: [UInt64] = [1, 253, 65_535, 9_007_199_254_740_993, UInt64(Int64.max), UInt64.max]
        let numbers = try ids.map { value -> Any in
            let json = try JSONSerialization.jsonObject(with: Data("[\(value)]".utf8)) as! [Any]
            return json[0]
        }
        let values = try ids.map { try LuxoValue.decodeJSONData(Data(String($0).utf8)) }
        for (index, value) in values.enumerated() {
            precondition(LuxoWebSocketProtocol.jsonRequestID(value: value) == ids[index])
        }
        compareJSON(numbers, values: values)
        compareBinary(ids)
    }

    private static func compareJSON(_ numbers: [Any], values: [LuxoValue]) {
        for (index, number) in numbers.enumerated() {
            precondition(LuxoWebSocketProtocol.jsonRequestID(value: values[index]) == previousCheckedRequestID(number))
        }
        compare(
            "JSON request ID vs unchecked baseline",
            before: { index in
                (numbers[index % numbers.count] as? NSNumber)?.uint64Value ?? 0
            },
            after: { index in
                LuxoWebSocketProtocol.jsonRequestID(value: values[index % values.count]) ?? 0
            })
        compare(
            "JSON request ID vs previous strict check",
            before: { index in
                previousCheckedRequestID(numbers[index % numbers.count]) ?? 0
            },
            after: { index in
                LuxoWebSocketProtocol.jsonRequestID(value: values[index % values.count]) ?? 0
            })
    }

    private static func compareBinary(_ ids: [UInt64]) {
        let frames = ids.map { id in
            var encoder = Encoder()
            encoder.writeVarint(LuxoBinaryProtocol.callSuccess)
            encoder.writeVarint(id)
            encoder.writeRawBytes(Data([42, 43, 44]))
            return encoder.data
        }
        for index in ids.indices {
            precondition(LuxoWebSocketProtocol.decodeBinaryFrame(frames[index])?.id == ids[index])
        }
        compare(
            "Binary response header and payload",
            before: { index in
                let data = frames[index % frames.count]
                var acknowledgement = Decoder(data)
                precondition(acknowledgement.readVarint() == LuxoBinaryProtocol.callSuccess)
                var decoder = Decoder(data)
                let type = decoder.readVarint()
                let id = decoder.readVarint()
                return type ^ id ^ UInt64(decoder.readRemainingData().count)
            },
            after: { index in
                guard let frame = LuxoWebSocketProtocol.decodeBinaryFrame(frames[index % frames.count]) else {
                    preconditionFailure("valid fixture rejected")
                }
                return frame.type ^ frame.id ^ UInt64(frame.payload.count)
            })
    }

    // Frozen strict implementation isolates bridge cost without weakening validation.
    private static func previousCheckedRequestID(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        switch number.objCType.pointee {
        case 105, 108, 113, 115:
            let integer = number.int64Value
            return integer >= 0 ? UInt64(integer) : nil
        case 73, 76, 81, 83:
            return number.uint64Value
        default:
            return nil
        }
    }

    static func compare(
        _ name: String, iterations: Int = 100_000, warmup: Int = 20_000,
        before: (Int) throws -> UInt64, after: (Int) throws -> UInt64
    ) rethrows {
        var sink: UInt64 = 0
        for _ in 0..<8 {
            sink ^= try measure(before, iterations: warmup).sink
            sink ^= try measure(after, iterations: warmup).sink
        }
        var oldSamples: [Double] = []
        var newSamples: [Double] = []
        for index in 0..<16 {
            let first =
                index.isMultiple(of: 2)
                ? try measure(before, iterations: iterations) : try measure(after, iterations: iterations)
            let second =
                index.isMultiple(of: 2)
                ? try measure(after, iterations: iterations) : try measure(before, iterations: iterations)
            oldSamples.append(index.isMultiple(of: 2) ? first.ns : second.ns)
            newSamples.append(index.isMultiple(of: 2) ? second.ns : first.ns)
            sink &+= first.sink &+ second.sink
        }
        oldSamples.sort()
        newSamples.sort()
        let oldMedian = (oldSamples[7] + oldSamples[8]) / 2
        let newMedian = (newSamples[7] + newSamples[8]) / 2
        print(
            "\(name): before=\(oldMedian) ns after=\(newMedian) ns delta=\((newMedian / oldMedian - 1) * 100)% sink=\(sink)"
        )
    }

    static func compareAsync(
        _ name: String, before: () async throws -> UInt64, after: () async throws -> UInt64
    ) async throws {
        var sink: UInt64 = 0
        for _ in 0..<8 {
            sink &+= try await measureAsync(before, iterations: 200).sink
            sink &+= try await measureAsync(after, iterations: 200).sink
        }
        var old: [Double] = []
        var new: [Double] = []
        for index in 0..<16 {
            let first = try await measureAsync(index.isMultiple(of: 2) ? before : after, iterations: 1_000)
            let second = try await measureAsync(index.isMultiple(of: 2) ? after : before, iterations: 1_000)
            old.append(index.isMultiple(of: 2) ? first.ns : second.ns)
            new.append(index.isMultiple(of: 2) ? second.ns : first.ns)
            sink &+= first.sink &+ second.sink
        }
        let oldMedian = asyncMedian(old)
        let newMedian = asyncMedian(new)
        print(
            "\(name): before=\(oldMedian) ns after=\(newMedian) ns delta=\(newMedian - oldMedian) ns sink=\(sink)")
    }

    @inline(never)
    private static func measureAsync(_ operation: () async throws -> UInt64, iterations: Int) async throws -> (
        ns: Double, sink: UInt64
    ) {
        var sink: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { sink &+= try await operation() }
        return (Double(DispatchTime.now().uptimeNanoseconds - start) / Double(iterations), sink)
    }

    private static func asyncMedian(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    @inline(never)
    private static func measure(
        _ operation: (Int) throws -> UInt64,
        iterations: Int
    ) rethrows -> (ns: Double, sink: UInt64) {
        var sink: UInt64 = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for index in 0..<iterations { sink &+= try operation(index) }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        return (Double(elapsed) / Double(iterations), sink)
    }
}
