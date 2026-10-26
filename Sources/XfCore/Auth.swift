import Foundation

/// 鉴权方式，二选一。
///
/// - `device`：设备签名（X-Device-* 头），见 `Signer`
/// - `apiKey`：开放 API Key（公司级、后付费，形如 OAK-xxx），带 `Authorization: Bearer <key>`，
///   不带任何设备头——服务端只有在请求里没有 deviceId / signature 时才走 key 分支
///
/// key 没有额度闸，泄露等于公司账户敞开用。闭包每个请求 / 每次握手都会调一次，SDK 不缓存、不打印；
/// 不要把 key 写死在 App 里，见 README「API Key 接入」。
public enum XfAuth {
    case device(DeviceCredentials)
    case apiKey(() throws -> String)

    static let headerAuthorization = "Authorization"

    var deviceCredentials: DeviceCredentials? {
        if case .device(let credentials) = self { return credentials }
        return nil
    }

    func headers(clock: ServerClock) throws -> [String: String] {
        switch self {
        case .device(let credentials):
            return try Signer.headers(credentials: credentials, clock: clock)
        case .apiKey(let provider):
            let key = try provider().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw XfError(kind: .apiKeyInvalid, message: "api key is empty")
            }
            return [Self.headerAuthorization: "Bearer \(key)"]
        }
    }
}
