import Foundation
import NIOCore
import NIOHTTP1

public struct NIOResponse: Sendable {
    public let status: Int
    public let body: Data
}

enum ResponseFailure: Error {
    case malformed, tooLarge, disconnected
}

/// Event-loop confined; closing this handler's channel cancels only its HTTP/2 stream.
final class BoundedResponse: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart
    private let maximum: Int
    private let promise: EventLoopPromise<NIOResponse>
    private var status: Int?
    private var expected: Int?
    private var body = Data()
    private var completed = false

    init(maximum: Int, promise: EventLoopPromise<NIOResponse>) {
        self.maximum = maximum
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !completed else { return }
        switch unwrapInboundIn(data) {
        case let .head(head):
            accept(head, context: context)
        case let .body(bytes):
            guard status != nil else { return fail(.malformed, context: context) }
            guard bytes.readableBytes <= maximum - body.count else {
                return fail(.tooLarge, context: context)
            }
            bytes.withUnsafeReadableBytes { body.append(contentsOf: $0) }
        case .end:
            guard let status, expected == nil || expected == body.count else {
                return fail(.malformed, context: context)
            }
            completed = true
            promise.succeed(NIOResponse(status: status, body: body))
        }
    }

    private func accept(_ head: HTTPResponseHead, context: ChannelHandlerContext) {
        guard status == nil else { return fail(.malformed, context: context) }
        if (100..<200).contains(head.status.code) {
            if head.status.code == 101 { fail(.malformed, context: context) }
            return
        }
        let lengths = head.headers["content-length"]
        if !lengths.isEmpty {
            guard lengths.count == 1, !lengths[0].isEmpty,
                lengths[0].utf8.allSatisfy({ (48...57).contains($0) }),
                let length = Int(lengths[0]), length <= maximum
            else {
                return fail(.malformed, context: context)
            }
            expected = length
        }
        status = Int(head.status.code)
    }

    private func fail(_ error: ResponseFailure, context: ChannelHandlerContext) {
        abort(error)
        context.close(promise: nil)
    }

    func abort(_ error: any Error) {
        guard !completed else { return }
        completed = true
        promise.fail(error)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        abort(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !completed {
            completed = true
            promise.fail(ResponseFailure.disconnected)
        }
        context.fireChannelInactive()
    }
}
