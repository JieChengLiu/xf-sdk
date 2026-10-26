import Foundation

/// SDK 统一错误。接入方按 `kind` 分支处理，`serverCode` / `message` 保留服务端原文便于排查。
public struct XfError: Error, CustomStringConvertible {

    public enum Kind: String {
        /// 设备时间与服务器相差过大（SDK 已自动校准重试一次仍失败）
        case clockSkew
        /// nonce 重复，一般是重放或重试逻辑有误
        case nonceReplay
        case signatureInvalid
        case deviceNotFound
        case deviceInactive
        case deviceExpired
        case macMismatch
        case productDisabled
        /// API Key 不存在、已禁用或已过期（message 里有具体原因）
        case apiKeyInvalid
        case quotaExceeded
        /// 参数校验失败
        case invalidRequest
        /// 服务端业务失败（上游厂商出错等）
        case serverError
        /// 网络不可达、超时、连接被断开
        case network
        /// 响应格式不符合预期
        case `protocol`
        case canceled
    }

    public let kind: Kind
    public let message: String
    public let serverCode: Int?
    public let underlying: Error?

    public init(kind: Kind, message: String, serverCode: Int? = nil, underlying: Error? = nil) {
        self.kind = kind
        self.message = message
        self.serverCode = serverCode
        self.underlying = underlying
    }

    public var description: String { "XfError(kind: \(kind), serverCode: \(serverCode.map(String.init) ?? "nil"), message: \(message))" }

    /// 服务端目前只回中文 message、没有细分错误码，只能按文案归类，与 Android 的 XfException.fromServer 保持一致。
    /// 服务端补上结构化错误码之后改成按码映射。
    static func fromServer(code: Int?, message: String) -> XfError {
        let kind: Kind
        if message.contains("请求已过期") {
            kind = .clockSkew
        } else if message.contains("请求重复") {
            kind = .nonceReplay
        } else if message.contains("设备授权已到期") {
            kind = .deviceExpired
        } else if message.contains("设备不存在") {
            kind = .deviceNotFound
        } else if message.contains("设备未激活") {
            kind = .deviceInactive
        } else if message.contains("MacId不匹配") {
            kind = .macMismatch
        } else if message.contains("设备产品") {
            kind = .productDisabled
        } else if isApiKeyRejection(code: code, message: message) {
            kind = .apiKeyInvalid
        } else if message.contains("签名") || message.contains("设备密钥未配置") {
            kind = .signatureInvalid
        } else if message.contains("Quota exceeded") {
            kind = .quotaExceeded
        } else if code == 400 {
            kind = .invalidRequest
        } else if code == 401 {
            kind = .signatureInvalid
        } else {
            kind = .serverError
        }
        return XfError(kind: kind, message: message, serverCode: code)
    }

    // ApiKeyAuthServiceImpl 的几种失败文案："invalid api key"、"api key disabled"、
    // "api key expired"、"empty api key"、"missing Authorization header"
    // 大多数接口回 401；长音频转写回 500 + "鉴权失败: <原因>"。不能只看文案：上游厂商的报错
    // （如 "Incorrect API key provided"）也可能被原样包进 500
    private static func isApiKeyRejection(code: Int?, message: String) -> Bool {
        guard code == 401 || message.hasPrefix("鉴权失败") else { return false }
        return message.range(of: "api key", options: .caseInsensitive) != nil
            || message.contains("Authorization header")
    }

    static func network(_ error: Error) -> XfError {
        if (error as? URLError)?.code == .cancelled {
            return XfError(kind: .canceled, message: "canceled", underlying: error)
        }
        return XfError(kind: .network, message: error.localizedDescription, underlying: error)
    }
}
