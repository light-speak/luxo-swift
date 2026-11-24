import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL

/// One TLS connection with bounded concurrent HTTP/2 streams.
final class NIOHTTPClient: Sendable {
    private let channel: any Channel
    private let state: NIOLoopBound<ClientState>

    private init(channel: any Channel, maximum: Int, concurrent: Int) throws {
        self.channel = channel
        let multiplexer = try channel.pipeline.syncOperations.handler(type: HTTP2StreamMultiplexer.self)
        state = NIOLoopBound(
            ClientState(multiplexer: multiplexer, maximum: maximum, concurrent: concurrent),
            eventLoop: channel.eventLoop)
    }

    public static func connect(
        group: any EventLoopGroup, host: String, port: Int, trustRootsFile: String?,
        maximumResponseBytes: Int = 2 * 1024 * 1024, maximumConcurrent: Int = 16, allowHTTP1: Bool = false
    ) async throws -> NIOHTTPClient {
        guard maximumResponseBytes >= 0, maximumConcurrent > 0 else { throw ConnectionFailure.invalidConfiguration }
        var tls = TLSConfiguration.makeClientConfiguration()
        if let trustRootsFile { tls.trustRoots = .file(trustRootsFile) }
        tls.applicationProtocols = allowHTTP1 ? ["h2", "http/1.1"] : ["h2"]
        let ssl = try NIOSSLContext(configuration: tls)
        // TLS forbids IP literals in SNI; NIOSSL verifies the peer IP when SNI is absent.
        let serverName = (try? SocketAddress(ipAddress: host, port: port)) == nil ? host : nil
        // Flow credit does not allocate body storage or weaken the response limit.
        let receiveWindow = max(65535, min(2 * 1024 * 1024, maximumResponseBytes))
        let loop = group.next()
        let ready = loop.makePromise(of: Void.self)
        let gate = NIOLoopBoundBox<TLSReadiness?>.makeEmptyBox(eventLoop: loop)
        let bootstrap = ClientBootstrap(group: loop)
            .connectTimeout(.seconds(10))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = TLSReadiness(promise: ready) {
                        channel.configureHTTP2Pipeline(
                            mode: .client,
                            initialLocalSettings: nioDefaultSettings.filter { $0.parameter != .initialWindowSize }
                                + [HTTP2Setting(parameter: .initialWindowSize, value: receiveWindow)],
                            targetWindowSize: receiveWindow,
                            inboundStreamInitializer: { $0.close() }
                        ).map { _ in () }
                    }
                    gate.value = handler
                    try channel.pipeline.syncOperations.addHandler(
                        NIOSSLClientHandler(context: ssl, serverHostname: serverName))
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }

        do {
            let channel = try await bootstrap.connect(host: host, port: port).get()
            return try await finishConnection(
                channel, ready: ready, gate: gate, maximum: maximumResponseBytes, concurrent: maximumConcurrent)
        } catch {
            try await loop.submit {
                if let gate = gate.value { gate.fail(error) } else { ready.fail(error) }
            }.get()
            throw error
        }
    }

    private static func finishConnection(
        _ channel: any Channel, ready: EventLoopPromise<Void>, gate: NIOLoopBoundBox<TLSReadiness?>,
        maximum: Int, concurrent: Int
    ) async throws -> NIOHTTPClient {
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(10)) {
            gate.value?.fail(ConnectionFailure.deadline)
            channel.close(promise: nil)
        }
        defer { timeout.cancel() }
        do {
            try await ready.futureResult.get()
            return try await channel.eventLoop.submit {
                try NIOHTTPClient(channel: channel, maximum: maximum, concurrent: concurrent)
            }.get()
        } catch {
            try? await channel.close().get()
            throw error
        }
    }

    public func post(
        path: String, authority: String, body: Data, headers: HTTPHeaders, timeout: TimeAmount = .seconds(30)
    ) async throws
        -> NIOResponse
    {
        try Task.checkCancellation()
        guard path.hasPrefix("/"), !path.contains("\r"), !path.contains("\n"),
            !authority.isEmpty, !authority.contains("\r"), !authority.contains("\n"), timeout.nanoseconds > 0
        else {
            throw ConnectionFailure.invalidConfiguration
        }
        let loop = channel.eventLoop
        let promise = loop.makePromise(of: NIOResponse.self)
        let operation = NIOLoopBoundBox<RequestOperation?>.makeEmptyBox(eventLoop: loop)
        loop.execute { [state, channel] in
            guard channel.isActive else { return promise.fail(ResponseFailure.disconnected) }
            operation.value = state.value.start(
                path: path, authority: authority, body: body, headers: headers, timeout: timeout, promise: promise)
        }
        return try await withTaskCancellationHandler {
            try await promise.futureResult.get()
        } onCancel: {
            loop.execute { operation.value?.cancel(CancellationError()) }
        }
    }

    var isActive: Bool { channel.isActive }

    public func close() async throws { try await channel.close().get() }
}

/// All mutable state below is confined to the parent connection's event loop.
private final class ClientState {
    let multiplexer: HTTP2StreamMultiplexer
    let maximum: Int
    let concurrent: Int
    var active = 0

    init(multiplexer: HTTP2StreamMultiplexer, maximum: Int, concurrent: Int) {
        self.multiplexer = multiplexer
        self.maximum = maximum
        self.concurrent = concurrent
    }

    func start(
        path: String, authority: String, body: Data, headers: HTTPHeaders, timeout: TimeAmount,
        promise: EventLoopPromise<NIOResponse>
    )
        -> RequestOperation?
    {
        guard active < concurrent else {
            promise.fail(ConnectionFailure.overloaded)
            return nil
        }
        active += 1
        let operation = RequestOperation(promise: promise, maximum: maximum, release: { self.active -= 1 })
        let bound = NIOLoopBound(operation, eventLoop: promise.futureResult.eventLoop)
        operation.arm(timeout: timeout)
        multiplexer.createStreamChannel { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(
                    HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https))
                try channel.pipeline.syncOperations.addHandler(bound.value.collector)
            }
        }.whenComplete { result in
            switch result {
            case let .success(channel):
                bound.value.attach(channel, path: path, authority: authority, body: body, headers: headers)
            case let .failure(error): bound.value.creationFailed(error)
            }
        }
        return operation
    }
}
