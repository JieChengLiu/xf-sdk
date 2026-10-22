import CryptoKit
import Foundation

/// 设备签名，规则与服务端 HmacSignatureUtil / DeviceSignatureAuthServiceImpl 一致：
///
///     signString = deviceId + macId + timestamp + nonce     (macId 为空时拼空串)
///     signature  = Base64(HMAC-SHA256(signString, deviceSecret))   标准 Base64，带填充
///
/// - timestamp 是毫秒，与服务器相差超过 5 分钟会被拒（"请求已过期"）
/// - nonce 一次性，服务端 Redis 记 10 分钟，所以每个请求 / 每次握手都必须现签
/// - 请求体不参与签名
///
/// 跨端一致性由 sdk/test-vectors/signature.json 保证，改这里必须同步改 Android 并重跑两端测试。
public enum Signer {

    public static let headerDeviceId = "X-Device-Id"
    public static let headerMacId = "X-Mac-Id"
    public static let headerTimestamp = "X-Timestamp"
    public static let headerNonce = "X-Nonce"
    public static let headerSignature = "X-Signature"

    public static func signString(deviceId: String, macId: String, timestamp: String, nonce: String) -> String {
        deviceId + macId + timestamp + nonce
    }

    public static func sign(_ signString: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signString.utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    /// 16 字节随机数的 hex，32 个字符（SystemRandomNumberGenerator 是系统 CSPRNG）。
    public static func newNonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
    }

    /// 生成一组新的鉴权头，每次调用 timestamp / nonce 都不同。
    public static func headers(credentials: DeviceCredentials, clock: ServerClock) throws -> [String: String] {
        let timestamp = String(clock.nowMillis())
        let nonce = newNonce()
        let secret = try credentials.secretProvider()
        guard !secret.isEmpty else {
            throw XfError(kind: .signatureInvalid, message: "device secret is empty")
        }
        let signature = sign(
            signString(deviceId: credentials.deviceId, macId: credentials.macId, timestamp: timestamp, nonce: nonce),
            secret: secret
        )
        return [
            headerDeviceId: credentials.deviceId,
            headerMacId: credentials.macId,
            headerTimestamp: timestamp,
            headerNonce: nonce,
            headerSignature: signature,
        ]
    }
}

/// 设备凭证。secret 通过 secretProvider 按需获取，SDK 不缓存、不打印，
/// 接入方可以从 Keychain 读，也可以从自己的服务端下发。
public struct DeviceCredentials: CustomStringConvertible {
    public let deviceId: String
    public let macId: String
    public let secretProvider: () throws -> String

    public init(deviceId: String, macId: String = "", secretProvider: @escaping () throws -> String) {
        precondition(!deviceId.trimmingCharacters(in: .whitespaces).isEmpty, "deviceId is blank")
        self.deviceId = deviceId
        self.macId = macId
        self.secretProvider = secretProvider
    }

    public var description: String { "DeviceCredentials(deviceId: \(deviceId), macId: \(macId))" }
}

/// 签名用的时间源：本机时间 + 与服务器的偏移。
///
/// 手机时间不准时服务端会报"请求已过期"（容忍 5 分钟）。每个 REST 响应的 Date 头都会
/// 喂给 `observeServerTime`，偏移超过阈值才更新——Date 头只精确到秒，小抖动不值得跟。
public final class ServerClock {
    private let lock = NSLock()
    private var offsetMs: Int64 = 0
    private let localClock: () -> Int64

    private static let updateThresholdMs: Int64 = 2_000

    public init(localClock: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.localClock = localClock
    }

    public func nowMillis() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        return localClock() + offsetMs
    }

    public var offsetMillis: Int64 {
        lock.lock(); defer { lock.unlock() }
        return offsetMs
    }

    /// - Returns: 偏移是否被更新
    @discardableResult
    public func observeServerTime(_ serverMillis: Int64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let newOffset = serverMillis - localClock()
        guard abs(newOffset - offsetMs) >= Self.updateThresholdMs else { return false }
        offsetMs = newOffset
        return true
    }

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func observe(response: URLResponse?) {
        guard let http = response as? HTTPURLResponse,
              let value = http.value(forHTTPHeaderField: "Date"),
              let date = Self.httpDateFormatter.date(from: value) else { return }
        observeServerTime(Int64(date.timeIntervalSince1970 * 1000))
    }
}
