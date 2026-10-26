import Foundation

/// WebSocket 会话的 config 消息，所有 /ws/v1/* 口子共用（服务端都解析成同一个 RequestParam）。
/// 用对应口子的预设创建，再按需改字段；协议新增字段可先用 `extra` / `ext` 透传。字段与 Android 的 StreamConfig 一一对应。
///
/// | 预设 | 口子 | 用于 |
/// |---|---|---|
/// | `voiceTranslation` | /ws/v1/voice | 语音翻译（识别 → 翻译 → 可选播报） |
/// | `voiceChat` | /ws/v1/voice | 语音对话（识别 → 大模型 → 可选播报），支持客户端工具 |
/// | `pushToTalk` | /ws/v1/push-to-talk | 按住说话 |
/// | `asrOnly` | /ws/v1/asr | 只做识别 |
/// | `ttsOnly` | /ws/v1/tts | 只做流式合成 |
/// | `llmOnly` | /ws/v1/llm | 只做文本补全（无记忆） |
/// | `multimodal` | /ws/v1/multimodal | Realtime 多模态 |
/// | `voiceLive` | /ws/v1/voicelive、/ws/v1/gpt-live | 实时语音大模型 |
public struct StreamConfig {

    /// 上行音频格式
    public enum AudioFormat: String {
        /// 16kHz / 16bit / 单声道 PCM，小端
        case pcm = "pcm"
        /// Opus 包，SDK 用 XOP1 封装发送，见 `AudioSession.sendOpus`
        case opus = "raw-opus"
    }

    public var sourceLanguage: String?
    public var targetLanguage: String?
    public var asrProvider: String?
    public var speechProvider: String?
    public var chatProvider: String?
    public var multimodalProvider: String?
    public var aiModel: String?
    public var systemPrompt: String?
    /// 非空即开启 TTS 播报
    public var ttsProvider: String?
    public var voiceName: String?
    public var voiceSpeed: Double?
    /// 个人声音档案 ID，见 PersonalVoiceAPI；暂不公开
    var speakerProfileId: String?
    public var outputFormat: String?
    public var audioFormat: AudioFormat?
    public var sampleRate: Int?
    /// ASR 候选语言，用于自动识别语种
    public var candidateLanguages: [String]?
    public var vadAutoStop: Bool?
    public var vadSilenceMs: Int?
    public var vadSensitivity: Double?
    /// 说话人分离：final 识别结果带 speakerId
    public var speakerDiarization: Bool?
    /// final 识别结果带逐词时间戳
    public var wordTimestamps: Bool?
    /// 客户端工具（仅 voiceChat），见 `ClientTool`
    public var tools: [ClientTool] = []
    /// 客户端工具执行超时，服务端默认 2 秒，超时会断开连接
    public var toolTimeoutMs: Int?
    public var ext: [String: Any] = [:]
    public var extra: [String: Any] = [:]

    private init() {}

    /// 开启 TTS 播报
    public mutating func tts(voiceName: String, provider: String = "microsoft") {
        ttsProvider = provider
        self.voiceName = voiceName
    }

    /// deviceId / macId 为 nil 是 API Key 模式：不带，服务端按 key 主体记账
    func json(deviceId: String?, macId: String?) -> [String: Any] {
        var json: [String: Any] = ["command": "config"]
        json["deviceId"] = deviceId
        json["macId"] = macId
        json["sourceLanguage"] = sourceLanguage
        json["targetLanguage"] = targetLanguage
        json["asrProvider"] = asrProvider
        json["speechProvider"] = speechProvider
        json["chatProvider"] = chatProvider
        json["multimodalProvider"] = multimodalProvider
        json["aiModel"] = aiModel
        json["systemPrompt"] = systemPrompt
        json["ttsProvider"] = ttsProvider
        json["voiceName"] = voiceName
        json["voiceSpeed"] = voiceSpeed
        json["speakerProfileId"] = speakerProfileId
        json["outputFormat"] = outputFormat
        json["audioFormat"] = audioFormat?.rawValue
        json["sampleRate"] = sampleRate

        var extJSON: [String: Any] = [:]
        extJSON["candidateLangs"] = candidateLanguages
        extJSON["vadAutoStop"] = vadAutoStop
        extJSON["vadSilenceMs"] = vadSilenceMs
        extJSON["vadSensitivity"] = vadSensitivity
        extJSON["enableSpeakerDiarization"] = speakerDiarization
        extJSON["wordTimestamps"] = wordTimestamps
        extJSON["pluginToolWaitTimeoutMs"] = toolTimeoutMs
        extJSON.merge(ext) { _, new in new }
        if !extJSON.isEmpty { json["ext"] = extJSON }

        json.merge(extra) { _, new in new }
        return json
    }

    // MARK: 预设

    /// 语音翻译：说 sourceLanguage，返回 targetLanguage 的译文
    public static func voiceTranslation(from sourceLanguage: String, to targetLanguage: String) -> StreamConfig {
        var c = StreamConfig()
        c.sourceLanguage = sourceLanguage
        c.targetLanguage = targetLanguage
        c.asrProvider = "microsoft"
        c.speechProvider = "microsoft"
        c.audioFormat = .pcm
        return c
    }

    /// 语音对话：识别 → 大模型 → 可选播报（调用 `tts(voiceName:)` 开启）
    public static func voiceChat(language sourceLanguage: String, chatProvider: String = "openai") -> StreamConfig {
        var c = StreamConfig()
        c.sourceLanguage = sourceLanguage
        c.chatProvider = chatProvider
        c.asrProvider = "microsoft"
        c.audioFormat = .pcm
        return c
    }

    /// 按住说话：start 开始录、stop 松手，松手后走识别 → 大模型 → 播报
    public static func pushToTalk(language sourceLanguage: String, chatProvider: String = "openai") -> StreamConfig {
        var c = StreamConfig()
        c.sourceLanguage = sourceLanguage
        c.chatProvider = chatProvider
        c.asrProvider = "microsoft"
        c.audioFormat = .pcm
        c.ext["pushToTalkMode"] = true
        return c
    }

    /// 只做识别
    public static func asrOnly(language sourceLanguage: String) -> StreamConfig {
        var c = StreamConfig()
        c.sourceLanguage = sourceLanguage
        c.audioFormat = .pcm
        c.sampleRate = 16000
        return c
    }

    /// 只做流式合成；voiceName 不传时按 targetLanguage 选默认音色
    public static func ttsOnly(voiceName: String? = nil, targetLanguage: String? = nil) -> StreamConfig {
        var c = StreamConfig()
        c.voiceName = voiceName
        c.targetLanguage = targetLanguage
        c.ttsProvider = "microsoft"
        return c
    }

    /// 只做文本补全，服务端不记上下文，多轮要自己带全 messages
    public static func llmOnly(chatProvider: String = "openai") -> StreamConfig {
        var c = StreamConfig()
        c.chatProvider = chatProvider
        return c
    }

    public static func multimodal(aiModel: String, provider: String = "microsoft") -> StreamConfig {
        var c = StreamConfig()
        c.aiModel = aiModel
        c.multimodalProvider = provider
        c.audioFormat = .pcm
        c.sampleRate = 16000
        return c
    }

    public static func voiceLive(aiModel: String? = nil) -> StreamConfig {
        var c = StreamConfig()
        c.aiModel = aiModel
        c.audioFormat = .pcm
        return c
    }
}
