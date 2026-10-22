import Foundation

/// 长音频转写（录音文件转文字，可选翻译、摘要），对应 /api/transcriptions/*。
///
/// 任务是异步的：创建后拿 taskId，轮询 `status` 到完成，再取 `result` / `summary`。
///
/// 上传方式三选一：
/// - `create(_:audio:fileName:)`：文件随请求上传（multipart），简单，适合几十 MB 以内
/// - `uploadAndCreate(_:fileURL:)`：先拿预签名地址直传对象存储，再建任务，大文件更稳
/// - `createFromURL(_:audioURL:)`：音频已经在公网可访问的地址上
public final class TranscriptionAPI {
    private let transport: RestTransport

    init(transport: RestTransport) {
        self.transport = transport
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
    /// 完成后服务端回调你自己的服务端
    public var callbackUrl: String?

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
        json["callbackUrl"] = callbackUrl
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
        if let v = callbackUrl { fields.append(("callbackUrl", v)) }
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
                    language: $0.str("language"), text: $0["text"] as? String ?? "")
        }
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

    init(_ json: [String: Any]) {
        taskId = json.str("taskId")
        status = json.str("status")
        errorMessage = json.str("errorMessage")
        items = json.objects("items").map {
            Item(type: $0.str("type"), status: $0.str("status"), text: $0.str("text"),
                 translatedText: $0.str("translatedText"), translatedLanguage: $0.str("translatedLanguage"),
                 mindmap: $0["mindmap"] is NSNull ? nil : $0["mindmap"], errorMessage: $0.str("errorMessage"))
        }
    }
}
