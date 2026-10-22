import Foundation
import Dispatch

/// 一条 /ws/v1/* WebSocket 会话，各口子的具体会话类（VoiceSession、AsrSession……）都继承它。
///
/// - `connect()` 握手（自动签名）后自动发送 config；收到 configOk 之前调用的任何 send 都会排队，
///   configOk 后按序发出，所以 connect() 之后可以立刻 start() / 发音频
/// - 一条连接可以多轮使用；断开后需要新建会话
/// - `events` 正常关闭时结束，握手失败或异常断开时抛出 `XfError`
/// - 所有方法线程安全
public class StreamSession {

    public enum State { case idle, connecting, ready, closing, closed }

    public let events: AsyncThrowingStream<StreamEvent, Error>

    private let urlSession: URLSession
    private let url: URL
    private let configJSON: [String: Any]
    private let credentials: DeviceCredentials
    private let clock: ServerClock
    private let tools: [ClientTool]
    private let continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation

    private let lock = NSLock()
    private var state = State.idle
    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private var readyDeadline: DispatchWorkItem?
    private let readyTimeout: TimeInterval
    private let makeWebSocketTask: (URLRequest) -> URLSessionWebSocketTask
    /// configOk 之前排队的消息，configOk 后按序发出
    private var pending: [URLSessionWebSocketTask.Message] = []
    private var pendingBytes = 0
    /// 等待与下一个二进制帧配对的 tts_chunk 元信息
    private var ttsMeta: [[String: Any]] = []
    private var opusSeq: UInt32 = 0
    private var opusStreamStart: Date?

    private static let maxPendingBytes = 2 * 1024 * 1024
    // 服务端 Netty 读空闲 120 秒断开，20 秒一次 ping 保活
    private static let pingIntervalNanos: UInt64 = 20_000_000_000

    init(urlSession: URLSession, url: URL, configJSON: [String: Any],
         credentials: DeviceCredentials, clock: ServerClock, tools: [ClientTool] = [], readyTimeout: TimeInterval = 30,
         makeWebSocketTask: ((URLRequest) -> URLSessionWebSocketTask)? = nil) {
        self.urlSession = urlSession
        self.url = url
        self.configJSON = configJSON
        self.credentials = credentials
        self.clock = clock
        self.tools = tools
        self.readyTimeout = readyTimeout
        self.makeWebSocketTask = makeWebSocketTask ?? { urlSession.webSocketTask(with: $0) }
        var continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation!
        self.events = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    deinit {
        readyDeadline?.cancel()
        pingTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
    }

    public var currentState: State {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func connect() {
        lock.lock()
        guard state == .idle else {
            lock.unlock()
            preconditionFailure("connect() can only be called once, state=\(state)")
        }
        state = .connecting
        let deadline = DispatchWorkItem { [weak self] in
            self?.finish(XfError(kind: .protocol, message: "session did not receive configOk before readiness timeout"), onlyConnecting: true)
        }
        readyDeadline = deadline
        DispatchQueue.global().asyncAfter(deadline: .now() + readyTimeout, execute: deadline)
        lock.unlock()

        var request = URLRequest(url: url)
        do {
            for (name, value) in try Signer.headers(credentials: credentials, clock: clock) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        } catch {
            finish(error as? XfError ?? XfError(kind: .signatureInvalid, message: "\(error)", underlying: error))
            return
        }

        guard let configText = Self.encode(configJSON) else {
            finish(XfError(kind: .protocol, message: "invalid session configuration JSON"))
            return
        }
        lock.lock()
        // close/timeout may have won while the credentials callback was running.
        guard state == .connecting else { lock.unlock(); return }
        let task = makeWebSocketTask(request)
        self.task = task
        // Publish the heartbeat together with the task so close() cannot miss either.
        pingTask = Task { [weak task] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: StreamSession.pingIntervalNanos)
                guard !Task.isCancelled, let task = task else { return }
                task.sendPing { _ in }
            }
        }
        lock.unlock()
        task.resume()
        // A task canceled by a racing close() cannot be restarted by resume().
        task.send(.string(configText)) { _ in }
        receive(on: task)
    }

    /// 结束当前这一轮（停止识别 / 中断合成 / 中断生成，视口子而定）
    public func stop() { sendCommand(["command": "stop"]) }

    /// 协议里有、SDK 还没封装的指令用这个发
    public func sendCommand(_ command: [String: Any]) {
        guard let text = Self.encode(command) else { return }
        send(.string(text))
    }

    public func close() { finish() }

    // MARK: 子类共用

    func sendAudio(_ data: Data) {
        guard !data.isEmpty else { return }
        send(.data(data))
    }

    func nextOpusFrame(_ packet: Data, frameMs: UInt8, endOfTurn: Bool) -> Data {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if opusStreamStart == nil { opusStreamStart = now }
        let elapsed = UInt64(max(0, now.timeIntervalSince(opusStreamStart!) * 1000))
        let frame = Xop1Frame.wrap(packet, seq: opusSeq, timestampMs: elapsed, frameMs: frameMs, endOfTurn: endOfTurn)
        opusSeq &+= 1
        return frame
    }

    static func encode(_ json: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: 内部

    // URLSessionWebSocketTask.send 是异步入队、按调用顺序发出，放在锁里调用保证排队消息和后续消息的顺序
    private func send(_ message: URLSessionWebSocketTask.Message) {
        lock.lock()
        switch state {
        case .idle, .connecting:
            let size: Int
            switch message {
            case .string(let text): size = text.utf8.count
            case .data(let data): size = data.count
            @unknown default: size = 0
            }
            guard pendingBytes + size <= Self.maxPendingBytes else {
                lock.unlock()
                finish(XfError(kind: .protocol, message: "too much data queued before session is ready"))
                return
            }
            pending.append(message)
            pendingBytes += size
        case .ready:
            task?.send(message) { _ in }
        case .closing, .closed:
            break
        }
        lock.unlock()
    }

    private func receive(on task: URLSessionWebSocketTask) {
        guard currentState != .closed else { return }
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.handle(message, on: task)
                self.receive(on: task)
            case .failure(let error):
                self.handleReceiveFailure(error, task: task)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) {
        guard currentState != .closed else { return }
        switch message {
        case .string(let text):
            guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                continuation.yield(.serverError(message: "unparseable message: \(text.prefix(200))", code: nil))
                return
            }
            switch json["type"] as? String {
            case "configOk": onReady(task)
            case "tts_chunk":
                lock.lock(); ttsMeta.append(json); lock.unlock()
            case "error" where currentState == .connecting:
                finish(XfError(kind: .protocol, message: json.str("message") ?? "session configuration failed"))
                return
            default: break
            }
            guard let event = StreamEvent.parse(json) else { return }
            continuation.yield(event)
            if case .toolCalls(let calls) = event, !tools.isEmpty {
                handleToolCalls(calls)
            }
        case .data(let data):
            lock.lock()
            let meta = ttsMeta.isEmpty ? nil : ttsMeta.removeFirst()
            lock.unlock()
            continuation.yield(.ttsAudio(messageIndex: meta?.int64("messageIndex") ?? -1,
                                         chunkIndex: meta?.int64("indexId") ?? -1,
                                         audio: data))
        @unknown default:
            break
        }
    }

    private func onReady(_ task: URLSessionWebSocketTask) {
        lock.lock(); defer { lock.unlock() }
        guard state == .connecting else { return }
        state = .ready
        readyDeadline?.cancel()
        readyDeadline = nil
        if !tools.isEmpty, let text = Self.encode(["command": "tools_list", "tools_list": tools.map { $0.definition }]) {
            task.send(.string(text)) { _ in }
        }
        for message in pending {
            task.send(message) { _ in }
        }
        pending.removeAll()
        pendingBytes = 0
    }

    private func handleToolCalls(_ calls: [ToolCall]) {
        for call in calls {
            guard let tool = tools.first(where: { $0.name == call.functionName }) else {
                replyTool(call, .failure(error: "tool '\(call.functionName)' is not registered on this client"))
                continue
            }
            Task { [weak self] in
                let result = await tool.handler(call)
                self?.replyTool(call, result)
            }
        }
    }

    private func replyTool(_ call: ToolCall, _ result: ToolResult) {
        var event: [String: Any] = [
            "command": "tool_event",
            "type": "tool_event",
            "toolCallId": call.toolCallId,
            "functionName": call.functionName,
            "needLlm": true,
            "needTts": false,
        ]
        switch result {
        case .success(let content):
            event["status"] = "success"
            event["content"] = content
        case .failure(let error, let content):
            event["status"] = "error"
            event["error"] = error
            event["content"] = content
        }
        sendCommand(event)
    }

    private func handleReceiveFailure(_ error: Error, task: URLSessionWebSocketTask) {
        if currentState == .closed { return }
        if task.closeCode != .invalid {
            // 主动关闭，或服务端正常关闭连接
            finish()
            return
        }
        // 握手被拒：服务端回 401，具体原因只在服务端日志里
        if let http = task.response as? HTTPURLResponse, http.statusCode == 401 {
            finish(XfError(kind: .signatureInvalid, message: "handshake rejected", serverCode: 401, underlying: error))
            return
        }
        finish(XfError.network(error))
    }

    private func finish(_ error: Error? = nil, onlyConnecting: Bool = false) {
        lock.lock()
        guard state != .closed, !onlyConnecting || state == .connecting else { lock.unlock(); return }
        state = .closed
        pending.removeAll()
        pendingBytes = 0
        ttsMeta.removeAll()
        readyDeadline?.cancel()
        readyDeadline = nil
        let ping = pingTask
        pingTask = nil
        let socket = task
        task = nil
        lock.unlock()
        ping?.cancel()
        socket?.cancel(with: error == nil ? .normalClosure : .goingAway, reason: nil)
        if let error = error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }
}

/// 有上行音频的会话
public class AudioSession: StreamSession {

    /// 开始收音
    public func start() { sendCommand(["command": "start"]) }

    /// 16kHz / 16bit / 单声道小端 PCM，建议每次 20~100ms 的数据（20ms = 640 字节）
    public func sendPCM(_ pcm: Data) { sendAudio(pcm) }

    /// 发送一个 Opus 包（config 需设置 `.opus`），SDK 自动做 XOP1 封装。
    /// - Parameter endOfTurn: 本句最后一个包
    public func sendOpus(_ opusPacket: Data, frameMs: UInt8 = 20, endOfTurn: Bool = false) {
        sendAudio(nextOpusFrame(opusPacket, frameMs: frameMs, endOfTurn: endOfTurn))
    }

    func sendImageCommand(_ image: Data, question: String?, imageType: String) {
        var command: [String: Any] = [
            "command": "image",
            "base64Images": [image.base64EncodedString()],
            "imageType": imageType,
        ]
        command["question"] = question
        sendCommand(command)
    }

    func sendMemoriesCommand(_ memories: [UserMemory]) {
        sendCommand(["command": "user_memory", "memories": memories.map { ["key": $0.key, "content": $0.content] }])
    }
}

/// 用户记忆条目，模型回答时会参考
public struct UserMemory: Equatable {
    public let key: String
    public let content: String

    public init(key: String, content: String) {
        self.key = key
        self.content = content
    }
}

/// /ws/v1/voice：语音翻译 / 语音对话
public final class VoiceSession: AudioSession {
    /// 打断当前播报（用户插话时调用）
    public func interrupt() { sendCommand(["command": "audio_interrupt"]) }

    /// 对话模式下直接输入文字（代替说话）
    public func sendText(_ text: String) { sendCommand(["command": "chat_input_text", "text": text]) }

    /// 对话模式下发图片让模型看图回答
    public func sendImage(_ image: Data, question: String? = nil, imageType: String = "image/jpeg") {
        sendImageCommand(image, question: question, imageType: imageType)
    }

    /// 会话中切换语种，成功后收到 `.languageSwitched`
    public func switchLanguage(from sourceLanguage: String, to targetLanguage: String) {
        sendCommand(["command": "switch_language", "sourceLanguage": sourceLanguage, "targetLanguage": targetLanguage])
    }

    public func syncMemories(_ memories: [UserMemory]) { sendMemoriesCommand(memories) }
}

/// /ws/v1/push-to-talk：按住说话，start 按下、stop 松开
public final class PushToTalkSession: AudioSession {
    public func interrupt() { sendCommand(["command": "audio_interrupt"]) }

    public func sendText(_ text: String) { sendCommand(["command": "chat_input_text", "text": text]) }

    public func sendImage(_ image: Data, question: String? = nil, imageType: String = "image/jpeg") {
        sendImageCommand(image, question: question, imageType: imageType)
    }
}

/// /ws/v1/asr：只做识别，stop 后下发终句
public final class AsrSession: AudioSession {}

/// /ws/v1/multimodal：Realtime 多模态会话
public final class MultimodalSession: AudioSession {
    public func interrupt() { sendCommand(["command": "audio_interrupt"]) }

    public func sendImage(_ image: Data, question: String? = nil, imageType: String = "image/jpeg") {
        sendImageCommand(image, question: question, imageType: imageType)
    }
}

/// /ws/v1/voicelive、/ws/v1/gpt-live：实时语音大模型
public final class VoiceLiveSession: AudioSession {
    public func interrupt() { sendCommand(["command": "audio_interrupt"]) }

    public func syncMemories(_ memories: [UserMemory]) { sendMemoriesCommand(memories) }
}

/// /ws/v1/tts：流式合成。每次 synthesize 对应一个 messageIndex，
/// 音频以 `.ttsAudio` 下发，完成时 `.ttsComplete`；stop() 中断当前合成。
public final class TTSSession: StreamSession {
    /// 后三个参数只覆盖本次合成，不影响 config
    public func synthesize(_ text: String, voiceName: String? = nil, voiceSpeed: Double? = nil, outputFormat: String? = nil) {
        var command: [String: Any] = ["command": "synthesize", "text": text]
        command["voiceName"] = voiceName
        command["voiceSpeed"] = voiceSpeed
        command["outputFormat"] = outputFormat
        sendCommand(command)
    }
}

/// /ws/v1/llm：流式文本补全。服务端不记上下文，多轮对话每次都要带全 messages。
/// 输出以 `.llmDelta` 下发，结束时 `.llmDone`。
public final class LLMSession: StreamSession {
    public func chat(_ messages: [ChatMessage], systemPrompt: String? = nil) {
        var command: [String: Any] = ["command": "chat", "messages": messages.map { $0.json }]
        command["systemPrompt"] = systemPrompt
        sendCommand(command)
    }

    /// 单轮问答的简写
    public func chat(_ text: String) { sendCommand(["command": "chat", "text": text]) }
}
