import NIOCore
import NIOTLS

enum ConnectionFailure: Error {
    case requiresHTTP2, deadline, overloaded, invalidConfiguration
}

final class TLSReadiness: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let promise: EventLoopPromise<Void>
    private var completed = false
    private let configure: (() -> EventLoopFuture<Void>)?

    init(promise: EventLoopPromise<Void>, configure: (() -> EventLoopFuture<Void>)? = nil) {
        self.promise = promise
        self.configure = configure
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case let TLSUserEvent.handshakeCompleted(negotiatedProtocol) = event {
            guard negotiatedProtocol == "h2" else {
                fail(
                    negotiatedProtocol == nil || negotiatedProtocol == "http/1.1"
                        ? ConnectionFailure.requiresHTTP2 : ConnectionFailure.invalidConfiguration)
                context.close(promise: nil)
                return
            }
            if !completed {
                completed = true
                if let configure { configure().cascade(to: promise) } else { promise.succeed(()) }
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    func fail(_ error: any Error) {
        guard !completed else { return }
        completed = true
        promise.fail(error)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        fail(ResponseFailure.disconnected)
        context.fireChannelInactive()
    }
}
