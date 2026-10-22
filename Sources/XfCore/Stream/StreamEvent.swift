import Foundation

/// 服务端下行事件，所有口子共用，与 Android 的 StreamEvent 一一对应。
/// 协议里还没建模的事件以 `.other` 透传，不会丢。
public enum StreamEvent {
    /// configOk：配置已生效
    case ready
    /// started：开始收音
    case started
    case asrPartial(text: String, language: String?)
    /// speakerId：开启说话人分离时有值；wordTimings：开启逐词时间戳时有值
    case asrFinal(text: String, language: String?, speakerId: String?, wordTimings: [WordTiming])
    case translation(original: String, translated: String, sourceLanguage: String?, targetLanguage: String?)
    /// 大模型流式增量，客户端拼接显示
    case llmDelta(String)
    /// 本轮大模型输出结束（voice 里是 llm_result=[DONE]，llm 口子是 llm_end）
    case llmDone(reason: String?)
    /// 实时模型（multimodal / voicelive）的助手语音转写文本
    case assistantTranscript(text: String, isFinal: Bool)
    /// TTS 音频分片。messageIndex 标识一段回复，chunkIndex 从 1 递增；
    /// 不带 tts_chunk 元信息的裸音频帧（multimodal / voicelive）两者都是 -1。
    case ttsAudio(messageIndex: Int64, chunkIndex: Int64, audio: Data)
    /// 某段回复的音频下发完毕
    case ttsComplete(messageIndex: Int64)
    /// 本轮全部音频下发完毕
    case ttsEnd
    /// 服务端要求立即停止播放、清空播放队列（用户打断等）
    case audioInterrupt
    /// 实时模型检测到用户开始 / 停止说话
    case userSpeech(speaking: Bool)
    /// 服务端判定一句话结束（VAD 静音），正在收尾
    case captureStopping
    case captureStopped
    case stopped(reason: String?)
    case languageSwitched(sourceLanguage: String?, targetLanguage: String?, voiceName: String?)
    /// 模型调用客户端工具。注册了 `ClientTool` 的工具 SDK 会自动执行并回包，这个事件仅供展示 / 记录。
    case toolCalls([ToolCall])
    /// 服务端在会话内报错，连接不一定断开
    case serverError(message: String, code: String?)
    case other(type: String, payload: [String: Any])

    public struct WordTiming: Equatable {
        public let word: String
        public let startMs: Int64
        public let endMs: Int64
    }

    static func parse(_ json: [String: Any]) -> StreamEvent? {
        let type = json["type"] as? String ?? ""
        // 同一个语义在不同口子里字段名不一样（content / text），都认
        let text = json.str("content") ?? json.str("text") ?? ""
        switch type {
        case "configOk": return .ready
        case "started": return .started
        case "asr_partial_result": return .asrPartial(text: text, language: json.str("language"))
        case "asr_result":
            return .asrFinal(
                text: text,
                language: json.str("language") ?? json.str("detectedLanguage"),
                speakerId: json.str("speakerId") ?? json.str("speakerTag"),
                wordTimings: json.objects("wordTimings").map {
                    WordTiming(word: $0["word"] as? String ?? "", startMs: $0.int64("startMs") ?? 0, endMs: $0.int64("endMs") ?? 0)
                }
            )
        case "translation_result":
            return .translation(original: json["original"] as? String ?? "", translated: json["translated"] as? String ?? "",
                                sourceLanguage: json.str("sourceLanguage"), targetLanguage: json.str("targetLanguage"))
        case "llm_result": return text == "[DONE]" ? .llmDone(reason: nil) : .llmDelta(text)
        case "llm_end": return .llmDone(reason: json.str("reason"))
        case "assistant_transcript_partial_result", "tts_transcript_partial_result":
            return .assistantTranscript(text: text, isFinal: false)
        case "assistant_transcript_result", "tts_transcript_result":
            return .assistantTranscript(text: text, isFinal: true)
        case "tts_complete": return .ttsComplete(messageIndex: json.int64("messageIndex") ?? -1)
        case "tts_end": return .ttsEnd
        case "audio_interrupt": return .audioInterrupt
        case "voice_speech_started": return .userSpeech(speaking: true)
        case "voice_speech_stopped": return .userSpeech(speaking: false)
        case "capture_stopping": return .captureStopping
        case "capture_stopped": return .captureStopped
        case "stopped": return .stopped(reason: json.str("reason"))
        case "language_switched":
            return .languageSwitched(sourceLanguage: json.str("sourceLanguage"), targetLanguage: json.str("targetLanguage"),
                                     voiceName: json.str("voiceName"))
        case "tool_call": return .toolCalls(ToolCall.parseAll(json))
        case "error": return .serverError(message: json.str("message") ?? "unknown error", code: json.str("code"))
        // pong 是心跳回包；tts_chunk 是二进制帧的元信息，由会话与后续二进制帧配对
        case "pong", "tts_chunk": return nil
        default: return .other(type: type, payload: json)
        }
    }
}
