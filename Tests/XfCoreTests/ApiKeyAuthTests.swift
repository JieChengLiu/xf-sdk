import XCTest
@testable import XfCore

/// API Key 模式：只带 Authorization，不带任何设备头 / deviceId——服务端只要看到 deviceId 或
/// signature 就会落到 HMAC 校验，混带等于必然 401。与 Android 的 ApiKeyAuthTest 对应。
final class ApiKeyAuthTests: XCTestCase {

    private let deviceHeaders = [Signer.headerDeviceId, Signer.headerMacId, Signer.headerTimestamp,
                                 Signer.headerNonce, Signer.headerSignature]

    func testApiKeySendsBearerOnlyAndIsFetchedEveryTime() throws {
        var current = "OAK-OLD"
        let auth = XfAuth.apiKey { current }
        XCTAssertEqual(try auth.headers(clock: ServerClock()), ["Authorization": "Bearer OAK-OLD"])
        current = " OAK-NEW \n"
        XCTAssertEqual(try auth.headers(clock: ServerClock()), ["Authorization": "Bearer OAK-NEW"])
    }

    func testEmptyKeyFailsBeforeSending() {
        XCTAssertThrowsError(try XfAuth.apiKey { "  " }.headers(clock: ServerClock())) { error in
            XCTAssertEqual((error as? XfError)?.kind, .apiKeyInvalid)
        }
    }

    func testSignedRequestCarriesNoDeviceHeaders() throws {
        let transport = RestTransport(session: .shared, baseURL: URL(string: "https://example.com")!,
                                      auth: .apiKey { "OAK-TEST" }, clock: ServerClock())
        let request = try transport.signed(transport.jsonRequest("trans/v1/device/text", body: ["text": "a"]))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer OAK-TEST")
        for header in deviceHeaders {
            XCTAssertNil(request.value(forHTTPHeaderField: header), header)
        }
        // key 不能出现在 URL 上，否则会进网关 / 代理的访问日志
        XCTAssertFalse(request.url!.absoluteString.contains("OAK-"))
    }

    func testClientInApiKeyModeHasNoDeviceIdentity() {
        let client = XfClient(config: .init(restBaseURL: URL(string: "https://example.com")!,
                                            wsBaseURL: URL(string: "wss://example.com")!,
                                            apiKey: { "OAK-TEST" }))
        XCTAssertNil(client.credentials)
        let json = StreamConfig.asrOnly(language: "zh-CN").json(deviceId: client.credentials?.deviceId,
                                                                 macId: client.credentials?.macId)
        XCTAssertEqual(json["command"] as? String, "config")
        XCTAssertNil(json["deviceId"])
        XCTAssertNil(json["macId"])
    }

    func testDeviceResetIsRejectedLocally() async {
        let client = XfClient(config: .init(restBaseURL: URL(string: "https://127.0.0.1:9")!,
                                            wsBaseURL: URL(string: "wss://127.0.0.1:9")!,
                                            apiKey: { "OAK-TEST" }))
        do {
            _ = try await client.device.reset()
            XCTFail("reset must not be sent with an API key")
        } catch {
            XCTAssertEqual((error as? XfError)?.kind, .invalidRequest)
        }
    }

    func testServerKeyRejectionMapping() {
        XCTAssertEqual(XfError.fromServer(code: 401, message: "api key disabled").kind, .apiKeyInvalid)
        XCTAssertEqual(XfError.fromServer(code: 401, message: "missing Authorization header").kind, .apiKeyInvalid)
        // 长音频转写的鉴权失败是 500 + "鉴权失败: <原因>"
        XCTAssertEqual(XfError.fromServer(code: 500, message: "鉴权失败: invalid api key").kind, .apiKeyInvalid)
        // 上游厂商的 key 报错不能误判成接入方的 key 失效
        XCTAssertEqual(XfError.fromServer(code: 500, message: "Chat failed: Incorrect API key provided").kind, .serverError)
    }
}
