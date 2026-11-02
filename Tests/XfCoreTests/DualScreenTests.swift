import XCTest
@testable import XfCore

/// 双屏互译：config 结构、side 前缀、事件归属、交错配对。与 Android 的 DualScreenSessionTest 对应。
final class DualScreenTests: XCTestCase {

    private func session() -> DualScreenSession {
        DualScreenSession(urlSession: .shared, url: URL(string: "ws://localhost/ws/v1/dual-screen-translation")!,
                          configJSON: [:], auth: XfAuth.apiKey { "OAK-TEST" }, clock: ServerClock())
    }

    func testConfigNestsBothSidesUnderParams() throws {
        var config = DualScreenConfig(languageA: "zh-CN", languageB: "en-US")
        config.tts(voiceA: "zh-CN-XiaoxiaoNeural", voiceB: "en-US-JennyNeural")
        config.ext["noSpeechTimeoutSeconds"] = 120

        XCTAssertEqual(config.json["command"] as? String, "config")
        let params = try XCTUnwrap(config.json["params"] as? [String: Any])
        XCTAssertEqual(params["speechProvider"] as? String, "microsoft")
        XCTAssertEqual(params["ttsProvider"] as? String, "microsoft")
        XCTAssertEqual(params["audioFormat"] as? String, "pcm")
        XCTAssertEqual((params["ext"] as? [String: Any])?["noSpeechTimeoutSeconds"] as? Int, 120)
        let sides = try XCTUnwrap(params["sides"] as? [String: [String: Any]])
        XCTAssertEqual(sides["A"]?["language"] as? String, "zh-CN")
        XCTAssertEqual(sides["A"]?["voiceName"] as? String, "zh-CN-XiaoxiaoNeural")
        XCTAssertEqual(sides["B"]?["language"] as? String, "en-US")
        XCTAssertEqual(sides["B"]?["voiceName"] as? String, "en-US-JennyNeural")
    }

    func testConfigWithoutTtsLeavesFieldsOut() throws {
        let params = try XCTUnwrap(DualScreenConfig(languageA: "zh-CN", languageB: "en-US").json["params"] as? [String: Any])
        XCTAssertNil(params["ttsProvider"])
        XCTAssertNil(params["ext"])
    }

    func testAudioFrameCarriesSidePrefix() {
        XCTAssertEqual(DualScreenSession.prefixed(.a, Data([1, 2])), Data([0x41, 1, 2]))
        XCTAssertEqual(DualScreenSession.prefixed(.b, Data([3])), Data([0x42, 3]))
    }

    func testCommandCarriesSideOnlyWhenGiven() {
        XCTAssertEqual(DualScreenSession.command("stop", .a)["side"] as? String, "A")
        XCTAssertNil(DualScreenSession.command("stop", nil)["side"])
    }

    func testTaggedEventIsWrappedWithItsSide() {
        let json: [String: Any] = ["type": "started", "side": "A", "targetSide": "B"]
        guard case .dualScreen(let side, let target, let utteranceId, let event) =
                session().decorate(.started, json: json), case .started = event else {
            return XCTFail("expected wrapped started")
        }
        XCTAssertEqual(side, .a)
        XCTAssertEqual(target, .b)
        XCTAssertNil(utteranceId)
    }

    func testConnectionLevelEventIsNotWrapped() {
        let event = StreamEvent.serverError(message: "bad", code: nil)
        guard case .serverError = session().decorate(event, json: ["type": "error", "message": "bad"]) else {
            return XCTFail("connection level error should stay unwrapped")
        }
    }

    /// 两侧同时播报：tts_chunk 和音频帧交错到达，必须按目标侧配对，不能按相邻关系。
    func testInterleavedTtsChunksPairByTargetSide() {
        let dual = session()
        dual.recordTTSMeta(["messageIndex": 1, "indexId": 1, "side": "A", "targetSide": "B", "utteranceId": "A-1"])
        dual.recordTTSMeta(["messageIndex": 7, "indexId": 3, "side": "B", "targetSide": "A", "utteranceId": "B-4"])

        guard case .dualScreen(let side, let target, let utteranceId, let inner) = dual.audioEvent(Data([0x41, 70])),
              case .ttsAudio(let messageIndex, let chunkIndex, let audio) = inner else {
            return XCTFail("expected wrapped audio")
        }
        XCTAssertEqual(side, .b)
        XCTAssertEqual(target, .a)
        XCTAssertEqual(utteranceId, "B-4")
        XCTAssertEqual(messageIndex, 7)
        XCTAssertEqual(chunkIndex, 3)
        XCTAssertEqual(audio, Data([70]))

        guard case .dualScreen(_, _, let otherUtterance, _) = dual.audioEvent(Data([0x42, 66])) else {
            return XCTFail("expected wrapped audio")
        }
        XCTAssertEqual(otherUtterance, "A-1")
    }

    func testAudioWithInvalidSideByteIsReported() {
        guard case .serverError = session().audioEvent(Data([0x58, 1])) else {
            return XCTFail("invalid side byte should be reported")
        }
    }
}
