import Foundation

/// 一次性语音合成，对应 /trans/v1/device/synthesize。流式合成用 `XfClient.ttsSession`。
public final class TTSAPI {
    private let transport: RestTransport
    private let deviceId: String?

    init(transport: RestTransport, deviceId: String?) {
        self.transport = transport
        self.deviceId = deviceId
    }

    public func synthesize(_ request: TTSRequest) async throws -> TTSResult {
        var body: [String: Any] = [
            "text": request.text,
            "type": request.ssml ? "ssml" : "text",
        ]
        body["deviceId"] = deviceId
        body["languageCode"] = request.languageCode
        body["voiceName"] = request.voiceName
        body["outputFormat"] = request.outputFormat
        let data = try await transport.object(transport.jsonRequest("trans/v1/device/synthesize", body: body))
        guard let base64 = data.str("audioData"), let audio = Data(base64Encoded: base64) else {
            throw XfError(kind: .protocol, message: "audioData is missing or not valid base64")
        }
        return TTSResult(
            audio: audio,
            audioFormat: data.str("audioFormat"),
            contentType: data.str("contentType"),
            fileExtension: data.str("fileExtension"),
            characterCount: data.int("characterCount") ?? 0
        )
    }
}

public struct TTSRequest {
    public var text: String
    /// 纯文本时必填，如 zh-CN
    public var languageCode: String?
    /// 纯文本时必填，如 zh-CN-XiaoxiaoNeural
    public var voiceName: String?
    /// Azure 输出格式，如 audio-16khz-32kbitrate-mono-mp3；不传由服务端决定
    public var outputFormat: String?
    /// true 时 text 按 SSML 处理
    public var ssml: Bool

    public init(text: String, languageCode: String? = nil, voiceName: String? = nil,
                outputFormat: String? = nil, ssml: Bool = false) {
        self.text = text
        self.languageCode = languageCode
        self.voiceName = voiceName
        self.outputFormat = outputFormat
        self.ssml = ssml
    }
}

public struct TTSResult {
    public let audio: Data
    public let audioFormat: String?
    public let contentType: String?
    public let fileExtension: String?
    public let characterCount: Int
}
