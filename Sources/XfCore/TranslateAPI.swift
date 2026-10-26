import Foundation

/// 文本翻译，对应 /trans/v1/device/text 与 /trans/v1/device/mutual-translate。
public final class TranslateAPI {
    private let transport: RestTransport
    private let deviceId: String?

    init(transport: RestTransport, deviceId: String?) {
        self.transport = transport
        self.deviceId = deviceId
    }

    /// - Parameter provider: 翻译厂商，不传由服务端决定（当前默认 azure）
    public func text(
        _ text: String,
        from sourceLanguage: String,
        to targetLanguage: String,
        provider: String? = nil
    ) async throws -> TranslateResult {
        // 设备签名时服务端要求 body 里的 deviceId 与签名头一致；API Key 模式不带
        var body: [String: Any] = [
            "text": text,
            "sourceLanguage": sourceLanguage,
            "targetLanguage": targetLanguage,
        ]
        body["deviceId"] = deviceId
        body["provider"] = provider
        let data = try await transport.object(transport.jsonRequest("trans/v1/device/text", body: body))
        return TranslateResult(text: data["text"] as? String ?? "", used: data.int64("used") ?? 0)
    }

    /// 互译：自动识别 text 属于 languageA 还是 languageB，翻成另一种。
    public func mutual(
        _ text: String,
        languageA: String,
        languageB: String,
        provider: String? = nil
    ) async throws -> MutualTranslateResult {
        var body: [String: Any] = [
            "text": text,
            "languageA": languageA,
            "languageB": languageB,
        ]
        body["deviceId"] = deviceId
        body["provider"] = provider
        let data = try await transport.object(transport.jsonRequest("trans/v1/device/mutual-translate", body: body))
        return MutualTranslateResult(
            text: data["text"] as? String ?? "",
            detectedLanguage: data.str("detectedLanguage"),
            targetLanguage: data.str("targetLanguage"),
            used: data.int64("used") ?? 0
        )
    }
}

public struct TranslateResult: Equatable {
    public let text: String
    /// 本次计费字符数
    public let used: Int64
}

public struct MutualTranslateResult: Equatable {
    public let text: String
    public let detectedLanguage: String?
    public let targetLanguage: String?
    public let used: Int64
}
