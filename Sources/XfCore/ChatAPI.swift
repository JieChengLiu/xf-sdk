import Foundation

/// 大模型对话，对应 /trans/v1/chat/completions，请求/响应格式兼容 OpenAI Chat Completions。
///
/// 请求体直接用 OpenAI 格式的字典（model、messages、tools、temperature……），SDK 原样转发，
/// 服务端新支持的字段不用等 SDK 升级。`ChatAPI.request(model:messages:)` 是拼最常见请求的快捷方法。
public final class ChatAPI {
    private let transport: RestTransport

    init(transport: RestTransport) {
        self.transport = transport
    }

    /// 非流式：返回 OpenAI 格式的完整响应，取文本用 `ChatAPI.content(of:)`
    public func completions(_ request: [String: Any]) async throws -> [String: Any] {
        var body = request
        body["stream"] = false
        let urlRequest = try transport.jsonRequest("trans/v1/chat/completions", body: body)
        do {
            return try Self.checkCompletion(try await transport.jsonObject(transport.signed(urlRequest)))
        } catch let error as XfError where error.kind == .clockSkew {
            return try Self.checkCompletion(try await transport.jsonObject(transport.signed(urlRequest)))
        }
    }

    /// 流式（SSE）。每个元素是一个 chunk；鉴权失败、配额不足在建连阶段就会抛错。
    ///
    ///     for try await chunk in client.chat.stream(request) {
    ///         if let delta = chunk.delta { text += delta }
    ///     }
    public func stream(_ request: [String: Any]) -> AsyncThrowingStream<ChatChunk, Error> {
        var body = request
        body["stream"] = true
        return AsyncThrowingStream { continuation in
            do {
                let urlRequest = try transport.signed(transport.jsonRequest("trans/v1/chat/completions", body: body))
                let reader = SSEReader(continuation: continuation, expectedChoices: (body["n"] as? NSNumber)?.intValue ?? 1)
                let session = URLSession(configuration: transport.session.configuration, delegate: reader, delegateQueue: nil)
                let task = session.dataTask(with: urlRequest)
                continuation.onTermination = { @Sendable _ in
                    task.cancel()
                    session.invalidateAndCancel()
                }
                task.resume()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    static func checkCompletion(_ json: [String: Any]) throws -> [String: Any] {
        if let error = json["error"] as? [String: Any] {
            throw XfError(kind: .serverError, message: error.str("message") ?? "\(error)")
        }
        // 设备鉴权 / 配额失败时服务端回的是 Result 信封而不是 OpenAI 格式
        if json["code"] != nil && json["choices"] == nil {
            throw XfError.fromServer(code: json.int("code"), message: json.str("message") ?? "unknown error")
        }
        return json
    }

    /// 拼一个最常见的请求
    public static func request(model: String, messages: [ChatMessage], temperature: Double? = nil) -> [String: Any] {
        var request: [String: Any] = ["model": model, "messages": messages.map { $0.json }]
        request["temperature"] = temperature
        return request
    }

    /// 非流式响应里第一条 choice 的文本
    public static func content(of completion: [String: Any]) -> String? {
        let choices = completion["choices"] as? [[String: Any]]
        return (choices?.first?["message"] as? [String: Any])?.str("content")
    }
}

public struct ChatMessage: Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatMessage { ChatMessage(role: "system", content: content) }
    public static func user(_ content: String) -> ChatMessage { ChatMessage(role: "user", content: content) }
    public static func assistant(_ content: String) -> ChatMessage { ChatMessage(role: "assistant", content: content) }

    var json: [String: Any] { ["role": role, "content": content] }
}

/// 流式响应的一个 chunk
public struct ChatChunk {
    /// 原始 chunk（含 tool_calls、usage 等）
    public let raw: [String: Any]

    /// 增量文本，按顺序拼接即为完整回复
    public var delta: String? {
        let choices = raw["choices"] as? [[String: Any]]
        return (choices?.first?["delta"] as? [String: Any])?.str("content")
    }
}

/// URLSession.bytes 要 iOS 15，这里用 delegate 逐块读 SSE
final class SSEReader: NSObject, URLSessionDataDelegate {
    private let continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation
    private var buffer = Data()
    private var isEventStream = false
    private var event: String?
    private var finished = false
    private let expectedChoices: Int
    private var completedChoices: Set<Int> = []

    init(continuation: AsyncThrowingStream<ChatChunk, Error>.Continuation, expectedChoices: Int = 1) {
        self.continuation = continuation
        self.expectedChoices = max(1, expectedChoices)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        isEventStream = contentType.contains("text/event-stream")
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        guard isEventStream else { return }  // 非 SSE：攒完整个 body 在结束时按错误解析
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            handle(line: line, session: session)
            if finished { return }
        }
    }

    private func handle(line: String, session: URLSession) {
        if line.isEmpty {
            event = nil
        } else if line.hasPrefix("event:") {
            event = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
        } else if line.hasPrefix("data:") {
            let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if event == "error" {
                finish(session, error: XfError(kind: .serverError, message: data))
            } else if data == "[DONE]" {
                finish(session, error: nil)
            } else if let json = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] {
                for (offset, choice) in json.objects("choices").enumerated() where choice.str("finish_reason") != nil {
                    let index = choice.int("index") ?? offset
                    if index >= 0 && index < expectedChoices { completedChoices.insert(index) }
                }
                continuation.yield(ChatChunk(raw: json))
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error = error {
            finish(session, error: XfError.network(error))
            return
        }
        if !isEventStream {
            // 建连阶段就失败了，body 是 Result 或 OpenAI 错误 JSON
            let json = (try? JSONSerialization.jsonObject(with: buffer)) as? [String: Any] ?? [:]
            do {
                _ = try ChatAPI.checkCompletion(json)
                finish(session, error: XfError(kind: .protocol, message: "expected text/event-stream"))
            } catch {
                finish(session, error: error)
            }
            return
        }
        // A final data line need not be followed by a newline before EOF.
        if !buffer.isEmpty {
            var line = String(decoding: buffer, as: UTF8.self)
            buffer.removeAll()
            if line.hasSuffix("\r") { line.removeLast() }
            handle(line: line, session: session)
            if finished { return }
        }
        guard completedChoices.count >= expectedChoices else {
            finish(session, error: XfError(kind: .protocol, message: "SSE ended before [DONE] or finish_reason for every choice"))
            return
        }
        finish(session, error: nil)
    }

    private func finish(_ session: URLSession, error: Error?) {
        guard !finished else { return }
        finished = true
        if let error = error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        session.invalidateAndCancel()
    }
}
