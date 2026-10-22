import Foundation

/// SDK 唯一入口。初始化一次、全局复用；所有请求自动带设备签名。
/// 还没有设备凭证时先用 `DeviceRegistrar` 注册。
///
///     let client = XfClient(config: .init(
///         restBaseURL: URL(string: "https://api.example.com")!,
///         wsBaseURL: URL(string: "wss://ws.example.com")!,
///         credentials: DeviceCredentials(deviceId: "D123", macId: "AA:BB:CC:DD:EE:FF") {
///             try Keychain.read("device_secret")
///         }
///     ))
///
///     let result = try await client.translate.text("你好", from: "zh-Hans", to: "en")
///     let session = client.voiceSession(.voiceTranslation(from: "zh-CN", to: "en-US"))
public final class XfClient {

    public struct Config {
        /// REST 服务地址，如 https://transcribe.azopenai.com
        public var restBaseURL: URL
        /// WebSocket 服务地址，如 wss://transcribe.azopenai.com
        public var wsBaseURL: URL
        public var credentials: DeviceCredentials
        /// 复用接入方已有的 URLSession（代理 / 超时配置）
        public var urlSession: URLSession

        public init(restBaseURL: URL, wsBaseURL: URL, credentials: DeviceCredentials,
                    urlSession: URLSession = .shared) {
            self.restBaseURL = restBaseURL
            self.wsBaseURL = wsBaseURL
            self.credentials = credentials
            self.urlSession = urlSession
        }
    }

    public enum LiveBackend: String {
        /// Azure Voice Live
        case azure = "ws/v1/voicelive"
        /// OpenAI GPT-Live
        case openai = "ws/v1/gpt-live"
    }

    public let credentials: DeviceCredentials
    public let clock: ServerClock

    public let translate: TranslateAPI
    public let tts: TTSAPI
    public let chat: ChatAPI
    public let image: ImageTranslateAPI
    let personalVoice: PersonalVoiceAPI
    public let transcription: TranscriptionAPI
    public let device: DeviceAPI

    private let config: Config

    public init(config: Config, clock: ServerClock = ServerClock()) {
        self.config = config
        self.credentials = config.credentials
        self.clock = clock
        let transport = RestTransport(session: config.urlSession, baseURL: config.restBaseURL,
                                      credentials: config.credentials, clock: clock)
        let deviceId = config.credentials.deviceId
        translate = TranslateAPI(transport: transport, deviceId: deviceId)
        tts = TTSAPI(transport: transport, deviceId: deviceId)
        chat = ChatAPI(transport: transport)
        image = ImageTranslateAPI(transport: transport)
        personalVoice = PersonalVoiceAPI(transport: transport)
        transcription = TranscriptionAPI(transport: transport)
        device = DeviceAPI(transport: transport)
    }

    // MARK: WebSocket 会话：创建后调 connect() 才建连

    /// /ws/v1/voice。config 用 `.voiceTranslation` 或 `.voiceChat`
    public func voiceSession(_ config: StreamConfig) -> VoiceSession {
        VoiceSession(urlSession: self.config.urlSession, url: wsURL("ws/v1/voice"), configJSON: json(config),
                     credentials: credentials, clock: clock, tools: config.tools)
    }

    /// /ws/v1/push-to-talk。config 用 `.pushToTalk`
    public func pushToTalkSession(_ config: StreamConfig) -> PushToTalkSession {
        PushToTalkSession(urlSession: self.config.urlSession, url: wsURL("ws/v1/push-to-talk"), configJSON: json(config),
                          credentials: credentials, clock: clock)
    }

    /// /ws/v1/asr。config 用 `.asrOnly`
    public func asrSession(_ config: StreamConfig) -> AsrSession {
        AsrSession(urlSession: self.config.urlSession, url: wsURL("ws/v1/asr"), configJSON: json(config),
                   credentials: credentials, clock: clock)
    }

    /// /ws/v1/tts。config 用 `.ttsOnly`
    public func ttsSession(_ config: StreamConfig) -> TTSSession {
        TTSSession(urlSession: self.config.urlSession, url: wsURL("ws/v1/tts"), configJSON: json(config),
                   credentials: credentials, clock: clock)
    }

    /// /ws/v1/llm。config 用 `.llmOnly`
    public func llmSession(_ config: StreamConfig) -> LLMSession {
        LLMSession(urlSession: self.config.urlSession, url: wsURL("ws/v1/llm"), configJSON: json(config),
                   credentials: credentials, clock: clock)
    }

    /// /ws/v1/multimodal。config 用 `.multimodal`
    public func multimodalSession(_ config: StreamConfig) -> MultimodalSession {
        MultimodalSession(urlSession: self.config.urlSession, url: wsURL("ws/v1/multimodal"), configJSON: json(config),
                          credentials: credentials, clock: clock)
    }

    /// /ws/v1/voicelive（Azure）或 /ws/v1/gpt-live（OpenAI），两者协议一致。config 用 `.voiceLive`
    public func voiceLiveSession(_ config: StreamConfig, backend: LiveBackend = .azure) -> VoiceLiveSession {
        VoiceLiveSession(urlSession: self.config.urlSession, url: wsURL(backend.rawValue), configJSON: json(config),
                         credentials: credentials, clock: clock)
    }

    private func wsURL(_ path: String) -> URL { config.wsBaseURL.appendingPathComponent(path) }

    private func json(_ streamConfig: StreamConfig) -> [String: Any] {
        streamConfig.json(deviceId: credentials.deviceId, macId: credentials.macId)
    }
}
