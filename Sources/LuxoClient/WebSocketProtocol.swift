import Foundation

enum LuxoWebSocketProtocol {
    struct SubscriptionAcknowledgement {
        let id: UInt64
        let error: LuxoError?
    }

    struct BinaryFrame {
        let type: UInt64
        let id: UInt64
        let payload: Data
    }

    static func jsonCallFrame(
        sequence: UInt64, api: String, params: [String: LuxoValue]?, plan: JSONParameterPlan? = nil
    ) throws -> Data {
        // Protocol metadata is uint64; schema Int/Duration values remain signed int64.
        return try LuxoJSONRequest.encode(api: api, params: params, plan: plan, sequence: sequence)
    }

    static func jsonRequestID(value: LuxoValue?) -> UInt64? {
        switch value {
        case .int(let number) where number >= 0: return UInt64(number)
        case .jsonNumber(let number) where number.isInteger && !number.literal.hasPrefix("-"):
            return UInt64(number.literal)
        default: return nil
        }
    }

    static func decodeJSONSubscriptionAcknowledgement(values: [String: LuxoValue]) -> SubscriptionAcknowledgement? {
        guard let id = jsonRequestID(value: values["$sub"]) else { return nil }
        if values["error"] != nil {
            return SubscriptionAcknowledgement(id: id, error: LuxoError.fromResponse(values: values, statusCode: 0))
        }
        guard case .bool(true) = values["ok"] else { return nil }
        return SubscriptionAcknowledgement(id: id, error: nil)
    }

    static func decodeBinaryFrame(_ data: Data) -> BinaryFrame? {
        // Frame type is one byte, unlike the following request/subscription ID varint.
        guard let byte = data.first else { return nil }
        switch UInt64(byte) {
        case LuxoBinaryProtocol.callSuccess, LuxoBinaryProtocol.callError, LuxoBinaryProtocol.stream,
            LuxoBinaryProtocol.subscribeSuccess, LuxoBinaryProtocol.subscribeError,
            LuxoBinaryProtocol.streamComplete, LuxoBinaryProtocol.streamError:
            break
        default:
            return nil
        }
        var decoder = Decoder(data)
        let type = decoder.readVarint()
        let id = decoder.readVarint()
        guard decoder.error == nil else { return nil }
        return BinaryFrame(type: type, id: id, payload: decoder.readRemainingData())
    }

    static func subscriptionAcknowledgement(_ frame: BinaryFrame) -> SubscriptionAcknowledgement? {
        guard frame.type == LuxoBinaryProtocol.subscribeSuccess || frame.type == LuxoBinaryProtocol.subscribeError
        else {
            return nil
        }
        let error: LuxoError? =
            frame.type == LuxoBinaryProtocol.subscribeError
            ? LuxoBinaryProtocol.decodeError(frame.payload, statusCode: 0)
            : frame.payload.isEmpty
                ? nil
                : LuxoError(code: 0, message: "trailing subscription acknowledgement bytes", name: "ParseError")
        return SubscriptionAcknowledgement(id: frame.id, error: error)
    }

    static func jsonTerminal(_ envelope: JSONEnvelope) -> SubscriptionAcknowledgement? {
        let fields = envelope.fields
        guard fields["$sub"] == nil, fields["$stream"] == nil, fields["$id"] == nil,
            let id = jsonRequestID(value: fields["$end"])
        else { return nil }
        let error: LuxoError?
        if fields["error"] != nil {
            error =
                fields["ok"] == nil
                ? JSONEnvelope.decodeError(envelope, statusCode: 0)
                : LuxoError(code: 0, message: "ambiguous stream terminal status", name: "ParseError")
        } else if case .bool(true) = fields["ok"], !envelope.hasData {
            error = nil
        } else {
            error = LuxoError(code: 0, message: "invalid stream completion", name: "ParseError")
        }
        return SubscriptionAcknowledgement(id: id, error: error)
    }
}
