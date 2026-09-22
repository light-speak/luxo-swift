import Foundation

/// Valid-input comparison against the pre-limit helpers, not a complete request benchmark.
enum FieldMaskBenchmark {
    static func run() throws {
        for id in [1, 128, 65535] {
            var mask: [UInt8] = []
            try fieldMaskSet(&mask, fieldID: id)
            let selected = try fieldMaskHas(mask, fieldID: id)
            precondition(selected)
            try TransportMetadataBenchmark.compare("mask has id=\(id)") { _ in
                previousHas(mask, fieldID: id) ? 1 : 0
            } after: { _ in
                try fieldMaskHas(mask, fieldID: id) ? 1 : 0
            }
            try compareSet(id, mask: mask, fresh: false)
            try compareSet(id, mask: mask, fresh: true)
        }
        print("Helpers only; allocation counts, failure paths, network and device gates remain open.")
    }

    private static func compareSet(_ id: Int, mask: [UInt8], fresh: Bool) throws {
        var previous = mask
        var current = mask
        try TransportMetadataBenchmark.compare(
            "mask set id=\(id) fresh=\(fresh)", iterations: fresh ? 1000 : 100_000,
            warmup: fresh ? 500 : 20_000
        ) { _ in
            if fresh { previous = [] }
            previousSet(&previous, fieldID: id)
            return UInt64(previous.count) ^ UInt64(previous.last ?? 0)
        } after: { _ in
            if fresh { current = [] }
            try fieldMaskSet(&current, fieldID: id)
            return UInt64(current.count) ^ UInt64(current.last ?? 0)
        }
        precondition(previous == current)
    }

    // Frozen implementation: only use with known-valid benchmark IDs.
    private static func previousSet(_ mask: inout [UInt8], fieldID: Int) {
        guard fieldID > 0 else { return }
        let bit = fieldID - 1
        let byteIndex = bit / 8
        let bitIndex = bit % 8
        while mask.count <= byteIndex { mask.append(0) }
        mask[byteIndex] |= (1 << bitIndex)
    }

    private static func previousHas(_ mask: [UInt8], fieldID: Int) -> Bool {
        guard fieldID > 0 else { return false }
        let bit = fieldID - 1
        let byteIndex = bit / 8
        let bitIndex = bit % 8
        guard byteIndex < mask.count else { return false }
        return mask[byteIndex] & (1 << bitIndex) != 0
    }
}
