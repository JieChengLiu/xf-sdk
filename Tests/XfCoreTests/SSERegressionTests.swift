import Foundation
import XCTest
@testable import XfCore

final class SSERegressionTests: XCTestCase {
    private func read(_ body: String, expectedChoices: Int = 1) async throws -> [ChatChunk] {
        var continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation!
        let stream = AsyncThrowingStream<ChatChunk, Error> { continuation = $0 }
        let reader = SSEReader(continuation: continuation, expectedChoices: expectedChoices)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "http://127.0.0.1:9")!
        // The task is never resumed: drive the real delegate/parser without any network calls.
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        reader.urlSession(session, dataTask: task, didReceive: response) { _ in }
        // Split inside UTF-8 sequences and SSE markers to exercise incremental parsing.
        for byte in body.utf8 { reader.urlSession(session, dataTask: task, didReceive: Data([byte])) }
        reader.urlSession(session, task: task, didCompleteWithError: nil)
        var chunks: [ChatChunk] = []
        for try await chunk in stream { chunks.append(chunk) }
        return chunks
    }

    func testPartialAnswerWithoutTerminalMarkerFails() async {
        do {
            _ = try await read("data: {\"choices\":[{\"delta\":{\"content\":\"半句\"}}]}\n\n")
            XCTFail("truncated answer accepted")
        } catch { XCTAssertEqual((error as? XfError)?.kind, .protocol) }
    }

    func testEmptyStreamFails() async {
        do { _ = try await read(""); XCTFail("empty stream accepted") }
        catch { XCTAssertEqual((error as? XfError)?.kind, .protocol) }
    }

    func testFinishReasonWithoutDoneOrTrailingNewlineSucceeds() async throws {
        let chunks = try await read("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"完整答案\"},\"finish_reason\":\"stop\"}]}")
        XCTAssertEqual(chunks.first?.delta, "完整答案")
    }

    func testEveryRequestedChoiceMustFinish() async throws {
        let first = "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        do { _ = try await read(first, expectedChoices: 2); XCTFail("incomplete choices accepted") }
        catch { XCTAssertEqual((error as? XfError)?.kind, .protocol) }
        let second = "data: {\"choices\":[{\"index\":1,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n"
        let chunks = try await read(first + second, expectedChoices: 2)
        XCTAssertEqual(chunks.count, 2)
    }

    func testDoneSucceedsAndExplicitErrorFails() async throws {
        let chunks = try await read("data: [DONE]\n\n")
        XCTAssertTrue(chunks.isEmpty)
        do { _ = try await read("event: error\ndata: upstream failed\n\n"); XCTFail("upstream error accepted") }
        catch { XCTAssertEqual((error as? XfError)?.kind, .serverError) }
    }
}
