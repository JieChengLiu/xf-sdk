import Foundation

/// 设备身份：注册拿凭证。
///
/// 典型流程：App 首次启动 → `register` 拿到 deviceId + deviceSecret → 存进 Keychain →
/// 用它们构建 `XfClient`。注册是幂等的：同一个 macId（或传回旧 deviceId）再注册会返回原来的凭证，
/// 所以凭证丢了重新注册即可。
public final class DeviceRegistrar {
    private let transport: RestTransport

    public init(restBaseURL: URL, urlSession: URLSession = .shared) {
        // 注册接口不需要设备签名
        transport = RestTransport(session: urlSession, baseURL: restBaseURL, credentials: nil, clock: ServerClock())
    }

    /// - Parameters:
    ///   - productApiKey: 产品 key（控制台创建产品时生成）
    ///   - deviceId: 之前注册过就传回来，比只靠 macId 识别"同一台设备"更准
    public func register(productApiKey: String, macId: String, deviceId: String? = nil) async throws -> DeviceRegistration {
        var body: [String: Any] = ["productApiKey": productApiKey, "macId": macId]
        body["deviceId"] = deviceId
        return try DeviceRegistration(try await transport.object(transport.jsonRequest("trans/v1/device/register", body: body)))
    }
}

/// 已注册设备的自助操作，需要设备签名。
public final class DeviceAPI {
    private let transport: RestTransport

    init(transport: RestTransport) {
        self.transport = transport
    }

    /// 恢复出厂：作废当前 deviceId + secret，换一套新的。成功后旧凭证立刻失效，
    /// 必须把返回的新凭证落盘并用它重建 `XfClient`——secret 只在这次响应里出现。
    /// - Parameter newMacId: 重置后的新 macId（不换就不传）
    public func reset(newMacId: String? = nil, reason: String? = nil) async throws -> DeviceRegistration {
        var body: [String: Any] = [:]
        body["macId"] = newMacId
        body["reason"] = reason
        return try DeviceRegistration(try await transport.object(transport.jsonRequest("trans/v1/device/reset", body: body)))
    }
}

public struct DeviceRegistration: CustomStringConvertible {
    public let deviceId: String
    public let deviceSecret: String
    public let macId: String?
    public let deviceProductId: Int64?
    public let deviceProductName: String?
    public let isActive: Bool?
    /// ISO-8601 本地时间，nil 表示不限期
    public let expiredAt: String?
    /// 仅 reset 返回：被作废的旧 deviceId
    public let oldDeviceId: String?
    public let message: String?

    init(_ data: [String: Any]) throws {
        guard let deviceId = data.str("deviceId"), let secret = data.str("deviceSecret") else {
            throw XfError(kind: .protocol, message: "deviceId / deviceSecret missing in response")
        }
        self.deviceId = deviceId
        self.deviceSecret = secret
        macId = data.str("macId")
        deviceProductId = data.int64("deviceProductId")
        deviceProductName = data.str("deviceProductName")
        // Lombok 的 boolean isActive 经 Jackson 序列化成 "active"，文档写的是 "isActive"，两个都认
        isActive = data.bool("isActive") ?? data.bool("active")
        expiredAt = data.str("expiredAt")
        oldDeviceId = data.str("oldDeviceId")
        message = data.str("message")
    }

    /// 不打印 secret
    public var description: String {
        "DeviceRegistration(deviceId: \(deviceId), macId: \(macId ?? "nil"), product: \(deviceProductName ?? "nil"))"
    }
}
