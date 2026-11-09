import Foundation

/// 长音频转写（录音文件转文字，可选翻译、摘要），对应 /api/transcriptions/*。
///
/// 任务是异步的：创建后拿 taskId，轮询 `status` 到完成，再取 `result` / `summary`。
/// 完成后还可以 `regenerateSummary` 换类型/模板/模型重出总结，或用 `chat` 针对录音内容多轮问答。
///
/// 上传方式三选一：
/// - `create(_:audio:fileName:)`：文件随请求上传（multipart），简单，适合几十 MB 以内
/// - `uploadAndCreate(_:fileURL:)`：先拿预签名地址直传对象存储，再建任务，大文件更稳
/// - `createFromURL(_:audioURL:)`：音频已经在公网可访问的地址上
public final class TranscriptionAPI {
    private let transport: RestTransport
    /// 转写对话复用它的 SSE 解析
    private let chatAPI: ChatAPI

    init(transport: RestTransport, chat: ChatAPI) {
        self.transport = transport
        self.chatAPI = chat
    }

    public func create(_ request: TranscriptionRequest, audio: Data, fileName: String? = nil) async throws -> TranscriptionTask {
        var form = MultipartForm()
        for (key, value) in request.formFields() { form.add(key, value) }
        form.add("audioFile", fileName: fileName ?? "audio.\(request.audioFormat)",
                 contentType: "application/octet-stream", data: audio)
        return try TranscriptionTask(try await transport.object(transport.multipartRequest("api/transcriptions", form: form)))
    }

    /// 音频已在 audioURL（公网可访问）
    public func createFromURL(_ request: TranscriptionRequest, audioURL: String) async throws -> TranscriptionTask {
        var body = request.json()
        body["audioUrl"] = audioURL
        return try TranscriptionTask(try await transport.object(transport.jsonRequest("api/transcriptions/v1/audio/task-by-url", body: body)))
    }

    /// 申请一个 30 分钟有效的上传地址。一般直接用 `uploadAndCreate`
    public func presignedUpload(fileName: String) async throws -> PresignedUpload {
        let data = try await transport.object(transport.getRequest("api/transcriptions/v1/audio/presigned-url",
                                                                    query: ["fileName": fileName]))
        guard let upload = data.str("uploadUrl").flatMap(URL.init(string:)), let audio = data.str("audioUrl") else {
            throw XfError(kind: .protocol, message: "uploadUrl / audioUrl missing")
        }
        return PresignedUpload(uploadURL: upload, audioURL: audio)
    }

    /// PUT 文件到预签名地址（不带设备签名头）
    public func upload(_ target: PresignedUpload, fileURL: URL) async throws {
        try await put(target) { session, request, completion in
            session.uploadTask(with: request, fromFile: fileURL, completionHandler: completion)
        }
    }

    public func upload(_ target: PresignedUpload, data: Data) async throws {
        try await put(target) { session, request, completion in
            session.uploadTask(with: request, from: data, completionHandler: completion)
        }
    }

    /// 预签名直传 + 建任务，一步完成
    public func uploadAndCreate(_ request: TranscriptionRequest, fileURL: URL) async throws -> TranscriptionTask {
        let target = try await presignedUpload(fileName: fileURL.lastPathComponent)
        try await upload(target, fileURL: fileURL)
        return try await createFromURL(request, audioURL: target.audioURL)
    }

    private func put(_ target: PresignedUpload,
                     makeTask: (URLSession, URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionUploadTask) async throws {
        var request = URLRequest(url: target.uploadURL)
        request.httpMethod = "PUT"
        // 预签名时服务端固定了 Content-Type: application/octet-stream，这里必须一致，否则签名不匹配
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let session = transport.session
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = makeTask(session, request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: XfError.network(error))
                } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    let text = data.flatMap { String(data: $0.prefix(200), encoding: .utf8) } ?? ""
                    continuation.resume(throwing: XfError(kind: .serverError, message: "upload failed: HTTP \(http.statusCode) \(text)",
                                                          serverCode: http.statusCode))
                } else {
                    continuation.resume()
                }
            }
            task.resume()
        }
    }

    public func status(_ taskId: String) async throws -> TranscriptionStatus {
        TranscriptionStatus(try await transport.object(transport.getRequest("api/transcriptions/\(taskId)")))
    }

    public func result(_ taskId: String) async throws -> TranscriptionResult {
        TranscriptionResult(try await transport.object(transport.getRequest("api/transcriptions/\(taskId)/result")))
    }

    public func summary(_ taskId: String) async throws -> TranscriptionSummary {
        TranscriptionSummary(try await transport.object(transport.getRequest("api/transcriptions/\(taskId)/summary")))
    }

    /// 对已完成的转写重新生成总结（可换类型、模板、模型、语种），不重新转写；不传的参数沿用创建任务时的设置。
    /// 异步执行：返回时 status 一般是 processing，之后继续轮询 `summary`。按 token 计费，与首次生成相同。
    public func regenerateSummary(_ taskId: String,
                                  _ request: SummaryRegenerateRequest = SummaryRegenerateRequest()) async throws -> TranscriptionSummary {
        TranscriptionSummary(try await transport.object(
            transport.jsonRequest("api/transcriptions/\(taskId)/summary/regenerate", body: request.json())))
    }

    /// 针对录音内容对话：服务端取该任务的转写原文作为上下文，以 SSE 流式返回回答，最后一个 chunk 带 usage。
    ///
    /// 无状态：服务端不保存对话历史，多轮时把之前的 user / assistant 消息按顺序全部带上，最后一条必须是 user。
    /// 只接受 user / assistant 两种 role（最多 40 条）；回答风格、角色等要求放 `prompt`（可选，4000 字以内）。
    /// 任务需已转写完成。
    ///
    ///     for try await chunk in client.transcription.chat(taskId, messages: [.user("会议几点开？")]) {
    ///         if let delta = chunk.delta { answer += delta }
    ///     }
    public func chat(_ taskId: String, messages: [ChatMessage], prompt: String? = nil) -> AsyncThrowingStream<ChatChunk, Error> {
        var body: [String: Any] = ["messages": messages.map { $0.json }]
        body["prompt"] = prompt
        return chatAPI.stream(path: "api/transcriptions/\(taskId)/chat", body: body, expectedChoices: 1)
    }
}

/// 重新生成总结的参数，全部可选，不传的沿用创建任务时的设置
public struct SummaryRegenerateRequest {
    /// brief / meeting / todo 或后台启用的模板类型；拼错会直接报错（不会悄悄退回 brief 照样计费）
    public var summaryTypes: [String]?
    /// 由模型重新从后台模板里选一个
    public var autoSelectTemplate: Bool?
    /// 自定义总结模板（JSON 对象），传了就替换原模板；只传模板不传 summaryTypes 时只出这一份
    public var summaryTemplate: [String: Any]?
    /// gpt-5.4-nano / gpt-6-luna
    public var summaryModel: String?
    /// 总结语种，语言代码如 zh-CN、en-US
    public var summaryLanguage: String?

    public init(summaryTypes: [String]? = nil, autoSelectTemplate: Bool? = nil, summaryTemplate: [String: Any]? = nil,
                summaryModel: String? = nil, summaryLanguage: String? = nil) {
        self.summaryTypes = summaryTypes
        self.autoSelectTemplate = autoSelectTemplate
        self.summaryTemplate = summaryTemplate
        self.summaryModel = summaryModel
        self.summaryLanguage = summaryLanguage
    }

    func json() -> [String: Any] {
        var json: [String: Any] = [:]
        json["summaryTypes"] = summaryTypes
        json["autoSelectTemplate"] = autoSelectTemplate
        json["summaryTemplate"] = summaryTemplate
        json["summaryModel"] = summaryModel
        json["summaryLanguage"] = summaryLanguage
        return json
    }
}

public struct TranscriptionRequest {
    public var taskName: String
    public var sourceLanguage: String
    /// 音频格式，如 wav / mp3 / m4a
    public var audioFormat: String
    /// 多语种自动识别候选
    public var candidateLanguages: [String]?
    public var enableSpeakerDiarization: Bool?
    public var maxSpeakerCount: Int?
    public var sampleRate: Int?
    public var needSummary: Bool?
    public var summaryTypes: [String]?
    public var summaryLanguage: String?
    /// 需要译文时填目标语言
    public var translateLanguage: String?
    /// 每个分段也附带译文（segments[].translatedText），需同时设置 translateLanguage，默认不开
    public var translateSegments: Bool?
    /// 自定义总结模板（JSON 对象），传入后额外生成 type=custom 的总结，结构见接口文档 summaryTemplate
    public var summaryTemplate: [String: Any]?
    /// 总结模型：gpt-5.4-nano / gpt-6-luna，不传使用默认（gpt-6-luna）
    public var summaryModel: String?
    /// 完成后服务端回调你自己的服务端
    public var callbackUrl: String?
    /// 要转录的声道，0 左、1 右。不传默认只转左声道（单声道文件不受影响），避免左右内容相同的立体声同一段话出现两遍；
    /// 人声只在右声道时传 [1]；左右各录一人的通话录音传 [0, 1]，此时不能开说话人分离
    /// （说话人分离只支持单声道，同时传会被拒绝），按声道区分说话人
    public var channels: [Int]?
    /// 返回逐词时间戳（segments[].words），用于逐词高亮、点词跳播，默认不开。
    /// 只能建任务时决定；长录音词数多、结果体会变大，不需要就别开
    public var wordTimestamps: Bool?
    /// 转写完成后用大模型按上下文整理断句、重复和明显错字，结果在 `TranscriptionResult.refinement`，
    /// 原始 text / segments 保留不变；异步执行，额外产生模型用量，默认不开
    public var refineTranscript: Bool?
    /// 由模型从后台启用的总结模板里自动选一个最匹配的（选中结果见 `TranscriptionSummary.templateSelection`），
    /// 需同时 needSummary；显式指定的模板类型或 summaryTemplate 优先
    public var autoSelectTemplate: Bool?

    public init(taskName: String, sourceLanguage: String, audioFormat: String) {
        self.taskName = taskName
        self.sourceLanguage = sourceLanguage
        self.audioFormat = audioFormat
    }

    func json() -> [String: Any] {
        var json: [String: Any] = ["taskName": taskName, "sourceLanguage": sourceLanguage, "audioFormat": audioFormat]
        json["candidateLangs"] = candidateLanguages
        json["enableSpeakerDiarization"] = enableSpeakerDiarization
        json["maxSpeakerCount"] = maxSpeakerCount
        json["sampleRate"] = sampleRate
        json["needSummary"] = needSummary
        json["summaryTypes"] = summaryTypes
        json["summaryLanguage"] = summaryLanguage
        json["translateLanguage"] = translateLanguage
        json["translateSegments"] = translateSegments
        json["summaryTemplate"] = summaryTemplate
        json["summaryModel"] = summaryModel
        json["callbackUrl"] = callbackUrl
        json["channels"] = channels
        json["wordTimestamps"] = wordTimestamps
        json["refineTranscript"] = refineTranscript
        json["autoSelectTemplate"] = autoSelectTemplate
        return json
    }

    /// multipart 表单：列表字段按 Spring 绑定规则重复同名字段
    func formFields() -> [(String, String)] {
        var fields = [("taskName", taskName), ("sourceLanguage", sourceLanguage), ("audioFormat", audioFormat)]
        candidateLanguages?.forEach { fields.append(("candidateLangs", $0)) }
        if let v = enableSpeakerDiarization { fields.append(("enableSpeakerDiarization", String(v))) }
        if let v = maxSpeakerCount { fields.append(("maxSpeakerCount", String(v))) }
        if let v = sampleRate { fields.append(("sampleRate", String(v))) }
        if let v = needSummary { fields.append(("needSummary", String(v))) }
        summaryTypes?.forEach { fields.append(("summaryTypes", $0)) }
        if let v = summaryLanguage { fields.append(("summaryLanguage", v)) }
        if let v = translateLanguage { fields.append(("translateLanguage", v)) }
        if let v = translateSegments { fields.append(("translateSegments", String(v))) }
        // multipart 只能传字符串，模板序列化成 JSON 字符串
        if let v = summaryTemplate, let data = try? JSONSerialization.data(withJSONObject: v),
           let s = String(data: data, encoding: .utf8) { fields.append(("summaryTemplate", s)) }
        if let v = summaryModel { fields.append(("summaryModel", v)) }
        if let v = callbackUrl { fields.append(("callbackUrl", v)) }
        channels?.forEach { fields.append(("channels", String($0))) }
        if let v = wordTimestamps { fields.append(("wordTimestamps", String(v))) }
        if let v = refineTranscript { fields.append(("refineTranscript", String(v))) }
        if let v = autoSelectTemplate { fields.append(("autoSelectTemplate", String(v))) }
        return fields
    }
}

public struct PresignedUpload {
    public let uploadURL: URL
    public let audioURL: String
}

public struct TranscriptionTask {
    public let taskId: String
    public let status: String?
    public let message: String?

    init(_ json: [String: Any]) throws {
        guard let taskId = json.str("taskId") else { throw XfError(kind: .protocol, message: "taskId missing") }
        self.taskId = taskId
        status = json.str("status")
        message = json.str("message")
    }
}

public struct TranscriptionStatus {
    public let taskId: String?
    /// 服务端原样透传，完成时为 completed
    public let status: String?
    /// 0~100
    public let progress: Int?
    /// 秒
    public let duration: Int?
    public let speakerCount: Int?
    public let detectedLanguage: String?

    public var isCompleted: Bool { status?.lowercased() == "completed" }

    init(_ json: [String: Any]) {
        taskId = json.str("taskId")
        status = json.str("status")
        progress = json.int("progress")
        duration = json.int("duration")
        speakerCount = json.int("speakerCount")
        detectedLanguage = json.str("detectedLanguage")
    }
}

public struct TranscriptionResult {
    public struct Segment {
        public let speaker: String?
        /// 秒
        public let startTime: Double?
        public let endTime: Double?
        public let language: String?
        public let text: String
        /// 该分段译文，仅 translateSegments=true 时返回
        public let translatedText: String?
        /// 逐词时间戳，仅 wordTimestamps=true 时返回；只对应原文 text，拼起来即 text
        public let words: [Word]?
    }

    /// 大模型整理后的版本，原始 text / segments 不变。说话人是按文字推断的，不带精确时间轴；
    /// `RefinedSegment.sourceSegmentIndices` 指向原始 segments 的下标（从 0 开始）
    public struct Refinement {
        /// pending / processing / completed / failed
        public let status: String?
        public let model: String?
        public let text: String?
        public let segments: [RefinedSegment]
        public let errorMessage: String?
    }

    public struct RefinedSegment: Equatable {
        public let speaker: String?
        public let text: String
        public let sourceSegmentIndices: [Int]
    }

    /// 单个词（中文为单字，标点附在前一个词上），时间单位秒，相对整段音频开头
    public struct Word {
        public let text: String
        public let startTime: Double?
        public let endTime: Double?
    }

    public let taskId: String?
    public let status: String?
    public let duration: Int?
    public let detectedLanguage: String?
    public let speakerCount: Int?
    public let text: String?
    public let translatedText: String?
    public let translatedLanguage: String?
    public let segments: [Segment]
    /// 文字整理结果，仅 refineTranscript=true 时返回；整理异步执行，刚完成转写时可能还是 pending
    public let refinement: Refinement?

    init(_ json: [String: Any]) {
        taskId = json.str("taskId")
        status = json.str("status")
        duration = json.int("duration")
        detectedLanguage = json.str("detectedLanguage")
        speakerCount = json.int("speakerCount")
        text = json.str("text")
        translatedText = json.str("translatedText")
        translatedLanguage = json.str("translatedLanguage")
        segments = json.objects("segments").map {
            Segment(speaker: $0.str("speaker"), startTime: $0.double("startTime"), endTime: $0.double("endTime"),
                    language: $0.str("language"), text: $0["text"] as? String ?? "",
                    translatedText: $0.str("translatedText"),
                    words: ($0["words"] as? [[String: Any]])?.map {
                        Word(text: $0["text"] as? String ?? "", startTime: $0.double("startTime"),
                             endTime: $0.double("endTime"))
                    })
        }
        refinement = (json["refinement"] as? [String: Any]).map { r in
            Refinement(status: r.str("status"), model: r.str("model"), text: r.str("text"),
                       segments: r.objects("segments").map {
                           RefinedSegment(speaker: $0.str("speaker"), text: $0["text"] as? String ?? "",
                                          sourceSegmentIndices: Self.intArray($0["sourceSegmentIndices"]))
                       },
                       errorMessage: r.str("errorMessage"))
        }
    }

    /// JSONSerialization 给的是 [NSNumber]，手写字典字面量是 [Int]，两种都认
    private static func intArray(_ value: Any?) -> [Int] {
        if let ints = value as? [Int] { return ints }
        return (value as? [NSNumber])?.map { $0.intValue } ?? []
    }
}

public struct TranscriptionSummary {
    public struct Item {
        public let type: String?
        public let status: String?
        public let text: String?
        public let translatedText: String?
        public let translatedLanguage: String?
        /// 思维导图类摘要的结构化数据，原样透传
        public let mindmap: Any?
        public let errorMessage: String?
    }

    public let taskId: String?
    public let status: String?
    public let errorMessage: String?
    public let items: [Item]
    /// 智能标题，语种与总结一致；未生成或生成失败时为 nil
    public let title: String?
    /// 智能标题译文，开了 translateLanguage 才有
    public let translatedTitle: String?
    /// autoSelectTemplate 的选择结果（选中的模板、置信度等），原样透传
    public let templateSelection: Any?

    init(_ json: [String: Any]) {
        taskId = json.str("taskId")
        status = json.str("status")
        errorMessage = json.str("errorMessage")
        title = json.str("title")
        translatedTitle = json.str("translatedTitle")
        templateSelection = json["templateSelection"] is NSNull ? nil : json["templateSelection"]
        items = json.objects("items").map {
            Item(type: $0.str("type"), status: $0.str("status"), text: $0.str("text"),
                 translatedText: $0.str("translatedText"), translatedLanguage: $0.str("translatedLanguage"),
                 mindmap: $0["mindmap"] is NSNull ? nil : $0["mindmap"], errorMessage: $0.str("errorMessage"))
        }
    }
}
