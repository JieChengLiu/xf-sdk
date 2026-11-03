import Foundation
import XCTest
@testable import XfCore

/// 服务端 HTTP 429 + Retry-After：自动等待重发、超限后交给接入方
final class RateLimitRetryTests: XCTestCase {

    /// 按顺序返回预设响应，并记下收到的请求数
    typealias Stub = (status: Int, headers: [String: String], body: String)

    final class StubProtocol: URLProtocol {
        static var responses: [Stub] = []
        static var requestCount = 0
        private static let lock = NSLock()

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.lock()
            Self.requestCount += 1
            let next: Stub = Self.responses.isEmpty ? (status: 500, headers: [:], body: "{}") : Self.responses.removeFirst()
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1",
                                           headerFields: next.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(next.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private var transport: RestTransport!

    override func setUp() {
        super.setUp()
        StubProtocol.responses = []
        StubProtocol.requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        transport = RestTransport(session: URLSession(configuration: configuration),
                                  baseURL: URL(string: "https://example.test/")!, auth: nil, clock: ServerClock())
    }

    private func limited(_ retryAfter: String?) -> Stub {
        (status: 429, headers: retryAfter.map { ["Retry-After": $0] } ?? [:],
         body: #"{"code":429,"message":"Azure Batch 请求受限，请等待后重试"}"#)
    }

    private let ok: Stub = (status: 200, headers: [:],
                            body: #"{"code":200,"message":"ok","data":{"taskId":"t1","status":"processing"}}"#)

    func testShortRetryAfterIsWaitedAndResent() async throws {
        StubProtocol.responses = [limited("1"), ok]
        let started = Date()
        let data = try await transport.object(transport.getRequest("api/transcriptions/t1"))
        XCTAssertEqual(data["status"] as? String, "processing")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.9)
        XCTAssertEqual(StubProtocol.requestCount, 2)
    }

    func testRetriesAreBoundedAndErrorCarriesRetryAfter() async {
        StubProtocol.responses = [limited("1"), limited("1"), limited("1")]
        do {
            _ = try await transport.object(transport.getRequest("api/transcriptions/t1"))
            XCTFail("rate limit should surface after retries")
        } catch {
            let error = error as? XfError
            XCTAssertEqual(error?.kind, .rateLimited)
            XCTAssertEqual(error?.serverCode, 429)
            XCTAssertEqual(error?.retryAfterSeconds, 1)
        }
        XCTAssertEqual(StubProtocol.requestCount, 1 + RestTransport.maxRateLimitRetries)
    }

    func testLongRetryAfterIsHandedToTheCallerWithoutWaiting() async {
        StubProtocol.responses = [limited("120")]
        let started = Date()
        do {
            _ = try await transport.object(transport.getRequest("api/transcriptions/t1"))
            XCTFail("long Retry-After should not be waited")
        } catch {
            XCTAssertEqual((error as? XfError)?.kind, .rateLimited)
            XCTAssertEqual((error as? XfError)?.retryAfterSeconds, 120)
        }
        XCTAssertEqual(StubProtocol.requestCount, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testBusinessFailureIsNotRetried() async {
        StubProtocol.responses = [(status: 200, headers: [:], body: #"{"code":500,"message":"任务失败"}"#)]
        do {
            _ = try await transport.object(transport.getRequest("api/transcriptions/t1"))
            XCTFail("business failure accepted")
        } catch {
            XCTAssertEqual((error as? XfError)?.kind, .serverError)
        }
        XCTAssertEqual(StubProtocol.requestCount, 1)
    }
}
