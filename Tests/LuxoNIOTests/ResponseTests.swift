import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import XCTest
@testable import LuxoNIO

final class ResponseTests: XCTestCase {
    func testDeclaredEmptyResponse() throws {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: NIOResponse.self)
        try channel.pipeline.syncOperations.addHandler(BoundedResponse(maximum: 0, promise: promise))
        let headers = HTTPHeaders([("content-length", "0")])
        try channel.writeInbound(HTTPClientResponsePart.head(.init(version: .http2, status: .ok, headers: headers)))
        try channel.writeInbound(HTTPClientResponsePart.end(nil))
        XCTAssertEqual(try promise.futureResult.wait().body, Data())
        _ = try channel.finish()
    }

    func testDuplicateLengthAndUnexpectedBody() throws {
        for duplicate in [true, false] {
            let channel = EmbeddedChannel()
            let promise = channel.eventLoop.makePromise(of: NIOResponse.self)
            try channel.pipeline.syncOperations.addHandler(BoundedResponse(maximum: 4, promise: promise))
            if duplicate {
                let headers = HTTPHeaders([("content-length", "0"), ("content-length", "0")])
                try channel.writeInbound(
                    HTTPClientResponsePart.head(.init(version: .http2, status: .ok, headers: headers)))
            } else {
                try channel.writeInbound(HTTPClientResponsePart.body(ByteBuffer(bytes: [1])))
            }
            XCTAssertThrowsError(try promise.futureResult.wait())
            _ = try channel.finish(acceptAlreadyClosed: true)
        }
    }

    func testChunksAndInformationalHeaders() throws {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: NIOResponse.self)
        try channel.pipeline.syncOperations.addHandler(BoundedResponse(maximum: 4, promise: promise))
        try channel.writeInbound(HTTPClientResponsePart.head(.init(version: .http2, status: .init(statusCode: 103))))
        try channel.writeInbound(HTTPClientResponsePart.head(.init(version: .http2, status: .ok)))
        try channel.writeInbound(HTTPClientResponsePart.body(ByteBuffer(bytes: [1, 2])))
        try channel.writeInbound(HTTPClientResponsePart.body(ByteBuffer(bytes: [3, 4])))
        try channel.writeInbound(HTTPClientResponsePart.end(nil))
        let result = try promise.futureResult.wait()
        XCTAssertEqual(result.status, 200)
        XCTAssertEqual(result.body, Data([1, 2, 3, 4]))
        _ = try channel.finish()
    }

    func testOverflowFailsBeforeEnd() throws {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: NIOResponse.self)
        try channel.pipeline.syncOperations.addHandler(BoundedResponse(maximum: 2, promise: promise))
        try channel.writeInbound(HTTPClientResponsePart.head(.init(version: .http2, status: .ok)))
        try channel.writeInbound(HTTPClientResponsePart.body(ByteBuffer(bytes: [1, 2, 3])))
        XCTAssertThrowsError(try promise.futureResult.wait())
        XCTAssertFalse(channel.isActive)
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    func testDisconnectRejectsPartialBody() throws {
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: NIOResponse.self)
        try channel.pipeline.syncOperations.addHandler(BoundedResponse(maximum: 4, promise: promise))
        try channel.writeInbound(HTTPClientResponsePart.head(.init(version: .http2, status: .ok)))
        try channel.writeInbound(HTTPClientResponsePart.body(ByteBuffer(bytes: [1])))
        try channel.close().wait()
        XCTAssertThrowsError(try promise.futureResult.wait())
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    func testInvalidLengthAndMissingHead() throws {
        for length in ["5", "-1", "garbage", "1"] {
            let channel = EmbeddedChannel()
            let promise = channel.eventLoop.makePromise(of: NIOResponse.self)
            try channel.pipeline.syncOperations.addHandler(BoundedResponse(maximum: 4, promise: promise))
            let headers = HTTPHeaders([("content-length", length)])
            try channel.writeInbound(HTTPClientResponsePart.head(.init(version: .http2, status: .ok, headers: headers)))
            if length == "1" { try channel.writeInbound(HTTPClientResponsePart.end(nil)) }
            XCTAssertThrowsError(try promise.futureResult.wait())
            _ = try channel.finish(acceptAlreadyClosed: true)
        }
        let channel = EmbeddedChannel()
        let promise = channel.eventLoop.makePromise(of: NIOResponse.self)
        try channel.pipeline.syncOperations.addHandler(BoundedResponse(maximum: 4, promise: promise))
        try channel.writeInbound(HTTPClientResponsePart.end(nil))
        XCTAssertThrowsError(try promise.futureResult.wait())
        _ = try channel.finish(acceptAlreadyClosed: true)
    }
}
