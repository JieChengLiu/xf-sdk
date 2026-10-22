import XCTest
@testable import XfCore

final class SignerTests: XCTestCase {

    /// 向量由服务端 HmacSignatureUtil 生成，Android 跑同一份
    func testMatchesServerVectors() throws {
        // 本仓库里在 sdk/test-vectors；导出成独立 Swift Package 仓库后在仓库根目录的 test-vectors
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // XfCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ios（或独立仓库根目录）
        let candidates = [
            packageRoot.appendingPathComponent("test-vectors/signature.json"),
            packageRoot.deletingLastPathComponent().appendingPathComponent("test-vectors/signature.json"),
        ]
        let url = try XCTUnwrap(candidates.first { FileManager.default.fileExists(atPath: $0.path) },
                                "signature.json not found")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let cases = try XCTUnwrap(root["cases"] as? [[String: String]])
        XCTAssertFalse(cases.isEmpty)
        for c in cases {
            let signString = Signer.signString(deviceId: c["deviceId"]!, macId: c["macId"]!,
                                               timestamp: c["timestamp"]!, nonce: c["nonce"]!)
            XCTAssertEqual(signString, c["signString"], c["name"]!)
            XCTAssertEqual(Signer.sign(signString, secret: c["secret"]!), c["signature"], c["name"]!)
        }
    }

    func testEveryCallGetsFreshNonce() throws {
        let credentials = DeviceCredentials(deviceId: "d", macId: "m") { "s" }
        let clock = ServerClock()
        let a = try Signer.headers(credentials: credentials, clock: clock)
        let b = try Signer.headers(credentials: credentials, clock: clock)
        XCTAssertNotEqual(a[Signer.headerNonce], b[Signer.headerNonce])
        XCTAssertEqual(a[Signer.headerNonce]?.count, 32)
    }

    func testClockOffsetIsAppliedToTimestamp() {
        var local: Int64 = 1_000_000
        let clock = ServerClock { local }
        clock.observeServerTime(1_000_000 + 600_000)
        XCTAssertEqual(clock.nowMillis(), 1_600_000)
        local += 10
        XCTAssertEqual(clock.nowMillis(), 1_600_010)
        // Date 头只精确到秒，小于阈值的抖动不更新
        clock.observeServerTime(local + 600_000 + 900)
        XCTAssertEqual(clock.offsetMillis, 600_000)
    }

    func testServerErrorMapping() {
        XCTAssertEqual(XfError.fromServer(code: 500, message: "签名认证失败: 请求已过期，请检查设备时间").kind, .clockSkew)
        XCTAssertEqual(XfError.fromServer(code: 500, message: "签名认证失败: 设备授权已到期").kind, .deviceExpired)
        XCTAssertEqual(XfError.fromServer(code: 500, message: "鉴权失败: 设备未激活").kind, .deviceInactive)
        XCTAssertEqual(XfError.fromServer(code: 500, message: "Quota exceeded: daily").kind, .quotaExceeded)
        XCTAssertEqual(XfError.fromServer(code: 500, message: "翻译失败: timeout").kind, .serverError)
    }
}

final class Xop1FrameTests: XCTestCase {

    func testHeaderLayoutMatchesServer() {
        let frame = Xop1Frame.wrap(Data([1, 2, 3]), seq: 5, timestampMs: 40, frameMs: 20, endOfTurn: true)
        let bytes = [UInt8](frame)
        XCTAssertEqual(String(bytes: bytes[0..<4], encoding: .ascii), "XOP1")
        XCTAssertEqual(bytes[4], 1)
        XCTAssertEqual(bytes[5], 1)
        XCTAssertEqual(bytes[6], 20)
        XCTAssertEqual(bytes[7], 20)
        XCTAssertEqual(Array(bytes[8..<12]), [0, 0, 0, 5])
        XCTAssertEqual(Array(bytes[12..<20]), [0, 0, 0, 0, 0, 0, 0, 40])
        XCTAssertEqual(Array(bytes[20...]), [1, 2, 3])
    }
}

final class StreamProtocolTests: XCTestCase {

    func testVoiceTranslationConfigJSON() {
        var config = StreamConfig.voiceTranslation(from: "zh-CN", to: "en-US")
        config.tts(voiceName: "en-US-JennyNeural")
        config.candidateLanguages = ["zh-CN", "en-US"]
        let json = config.json(deviceId: "device-001", macId: "00:11:22:33:44:55")

        XCTAssertEqual(json["command"] as? String, "config")
        XCTAssertEqual(json["speechProvider"] as? String, "microsoft")
        XCTAssertEqual(json["targetLanguage"] as? String, "en-US")
        XCTAssertEqual(json["audioFormat"] as? String, "pcm")
        XCTAssertEqual(json["voiceName"] as? String, "en-US-JennyNeural")
        XCTAssertNil(json["chatProvider"])
        let ext = json["ext"] as? [String: Any]
        XCTAssertEqual(ext?["candidateLangs"] as? [String], ["zh-CN", "en-US"])
    }

    func testPresetsSetModeFields() {
        XCTAssertEqual(StreamConfig.voiceChat(language: "zh-CN").json(deviceId: "d", macId: "")["chatProvider"] as? String, "openai")
        let ptt = StreamConfig.pushToTalk(language: "zh-CN").json(deviceId: "d", macId: "")
        XCTAssertEqual((ptt["ext"] as? [String: Any])?["pushToTalkMode"] as? Bool, true)
        XCTAssertEqual(StreamConfig.multimodal(aiModel: "gpt-realtime-mini").json(deviceId: "d", macId: "")["multimodalProvider"] as? String,
                       "microsoft")
        XCTAssertEqual(StreamConfig.ttsOnly(voiceName: "v").json(deviceId: "d", macId: "")["ttsProvider"] as? String, "microsoft")
    }

    func testParsesEvents() {
        // push-to-talk / multimodal 文档里 asr_result 用的是 text 字段
        guard case .asrFinal(let text, let lang, let speaker, let timings)? = StreamEvent.parse([
            "type": "asr_result", "text": "你好", "language": "zh-CN", "speakerId": "Guest-1",
            "wordTimings": [["word": "你好", "startMs": NSNumber(value: 10), "endMs": NSNumber(value: 300)]],
        ]) else {
            return XCTFail("asr_result")
        }
        XCTAssertEqual(text, "你好")
        XCTAssertEqual(lang, "zh-CN")
        XCTAssertEqual(speaker, "Guest-1")
        XCTAssertEqual(timings, [StreamEvent.WordTiming(word: "你好", startMs: 10, endMs: 300)])

        guard case .translation(_, let translated, _, _)? = StreamEvent.parse(
            ["type": "translation_result", "original": "你好", "translated": "Hello"]) else {
            return XCTFail("translation_result")
        }
        XCTAssertEqual(translated, "Hello")

        guard case .llmDone(nil)? = StreamEvent.parse(["type": "llm_result", "content": "[DONE]"]) else {
            return XCTFail("llm_result [DONE]")
        }
        guard case .llmDone("llm_complete")? = StreamEvent.parse(["type": "llm_end", "reason": "llm_complete"]) else {
            return XCTFail("llm_end")
        }
        guard case .ttsComplete(3)? = StreamEvent.parse(["type": "tts_complete", "messageIndex": NSNumber(value: 3)]) else {
            return XCTFail("tts_complete")
        }
        guard case .assistantTranscript("hi", true)? = StreamEvent.parse(["type": "assistant_transcript_result", "text": "hi"]) else {
            return XCTFail("assistant_transcript_result")
        }
        XCTAssertNil(StreamEvent.parse(["type": "tts_chunk", "messageIndex": 1]))
        XCTAssertNil(StreamEvent.parse(["type": "pong"]))
        guard case .other("lid_rejected", _)? = StreamEvent.parse(["type": "lid_rejected"]) else {
            return XCTFail("unknown event")
        }
    }

    func testParsesToolCalls() {
        guard case .toolCalls(let calls)? = StreamEvent.parse([
            "type": "tool_call",
            "toolCalls": [["toolCallId": "call_1", "functionName": "volume_up", "arguments": "{\"delta\":5}"]],
        ]) else {
            return XCTFail("tool_call")
        }
        XCTAssertEqual(calls.first?.toolCallId, "call_1")
        XCTAssertEqual(calls.first?.functionName, "volume_up")
        XCTAssertEqual(calls.first?.arguments["delta"] as? Int, 5)
    }

    func testToolDefinitionShape() {
        let tool = ClientTool(name: "volume_up", description: "Increase volume",
                              parameters: ["type": "object", "required": ["delta"]]) { _ in .success(nil) }
        let function = tool.definition["function"] as? [String: Any]
        XCTAssertEqual(tool.definition["type"] as? String, "function")
        XCTAssertEqual(function?["name"] as? String, "volume_up")
    }
}

final class RestHelperTests: XCTestCase {

    func testMultipartRepeatsListFieldsAndCarriesFiles() {
        var request = TranscriptionRequest(taskName: "会议", sourceLanguage: "zh-CN", audioFormat: "wav")
        request.candidateLanguages = ["zh-CN", "en-US"]
        var form = MultipartForm()
        for (k, v) in request.formFields() { form.add(k, v) }
        form.add("audioFile", fileName: "a.wav", contentType: "application/octet-stream", data: Data([1, 2]))
        let body = String(decoding: form.body(), as: UTF8.self)

        XCTAssertEqual(body.components(separatedBy: "name=\"candidateLangs\"").count - 1, 2)
        XCTAssertTrue(body.contains("name=\"audioFile\"; filename=\"a.wav\""))
        XCTAssertTrue(body.hasSuffix("--\(form.boundary)--\r\n"))
    }

    func testChatCompletionRejectsResultEnvelope() {
        XCTAssertThrowsError(try ChatAPI.checkCompletion(["code": NSNumber(value: 500), "message": "鉴权失败: 设备未激活"])) { error in
            XCTAssertEqual((error as? XfError)?.kind, .deviceInactive)
        }
        XCTAssertNoThrow(try ChatAPI.checkCompletion(["choices": [["message": ["content": "hi"]]]]))
    }

    func testRegistrationNeverPrintsSecret() throws {
        let reg = try DeviceRegistration(["deviceId": "d1", "deviceSecret": "sec_x", "active": NSNumber(value: true)])
        XCTAssertEqual(reg.isActive, true)
        XCTAssertFalse(reg.description.contains("sec_x"))
    }
}
