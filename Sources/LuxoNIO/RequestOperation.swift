import Foundation
import NIOCore
import NIOHTTP1

final class RequestOperation {
    let collector: BoundedResponse
    private let promise: EventLoopPromise<NIOResponse>
    private let release: () -> Void
    private var channel: (any Channel)?
    private var timer: Scheduled<Void>?
    private var completed = false
    private var released = false

    init(promise: EventLoopPromise<NIOResponse>, maximum: Int, release: @escaping () -> Void) {
        self.promise = promise
        self.release = release
        collector = BoundedResponse(maximum: maximum, promise: promise)
    }

    func arm(timeout: TimeAmount) {
        let bound = NIOLoopBound(self, eventLoop: promise.futureResult.eventLoop)
        timer = promise.futureResult.eventLoop.scheduleTask(in: timeout) {
            bound.value.cancel(ConnectionFailure.deadline)
        }
        promise.futureResult.whenComplete { result in bound.value.finish(result) }
    }

    func attach(_ channel: any Channel, path: String, authority: String, body: Data, headers: HTTPHeaders) {
        self.channel = channel
        let bound = NIOLoopBound(self, eventLoop: channel.eventLoop)
        channel.closeFuture.whenComplete { _ in bound.value.releaseOnce() }
        guard !completed else { channel.close(promise: nil); return }
        var headers = headers
        headers.replaceOrAdd(name: "host", value: authority)
        headers.replaceOrAdd(name: "content-length", value: String(body.count))
        channel.write(
            HTTPClientRequestPart.head(.init(version: .http2, method: .POST, uri: path, headers: headers)), promise: nil
        )
        var bytes = channel.allocator.buffer(capacity: body.count)
        _ = body.withUnsafeBytes { bytes.writeBytes($0) }
        channel.write(HTTPClientRequestPart.body(.byteBuffer(bytes)), promise: nil)
        channel.writeAndFlush(HTTPClientRequestPart.end(nil)).whenFailure { error in bound.value.cancel(error) }
    }

    func creationFailed(_ error: any Error) {
        collector.abort(error)
        releaseOnce()
    }

    func cancel(_ error: any Error) { collector.abort(error) }

    private func finish(_ result: Result<NIOResponse, any Error>) {
        completed = true
        timer?.cancel()
        timer = nil
        // The multiplexer closes a normally completed stream after processing END_STREAM.
        // Closing it inside the response callback can emit an unnecessary RST_STREAM.
        if case .failure = result { channel?.close(promise: nil) }
    }

    private func releaseOnce() {
        guard !released else { return }
        released = true
        release()
    }
}
