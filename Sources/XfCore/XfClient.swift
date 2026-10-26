import Foundation

/// SDK 唯一入口。初始化一次、全局复用；所有请求自动带鉴权。
/// 鉴权二选一：设备签名（还没有设备凭证时先用 `DeviceRegistrar` 注册），
/// 或开放 API Key（后付费，接入前先看 README「API Key 接入」的风险说明）。
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
///
///     // API Key：key 从接入方自己的服务端取，不要写死在 App 里
///     XfClient(config: .init(restBaseURL: rest, wsBaseURL: ws, apiKey: { try myBackend.xfApiKey() }))
public final class XfClient {

    public struct Config {
        /// REST 服务地址，如 https://transcribe.azopenai.com
        public var restBaseURL: URL
        /// WebSocket 服务地址，如 wss://transcribe.azopenai.com
        public var wsBaseURL: URL
        public var auth: XfAuth
        /// 复用接入方已有的 URLSession（代理 / 超时配置）
        public var urlSession: URLSession

        public init(restBaseURL: URL, wsBaseURL: URL, auth: XfAuth, urlSession: URLSession = .shared) {
            self.restBaseURL = restBaseURL
            self.wsBaseURL = wsBaseURL
            self.auth = auth
            self.urlSession = urlSession
        }

        /// 设备签名
        public init(restBaseURL: URL, wsBaseURL: URL, credentials: DeviceCredentials,
                    urlSession: URLSession = .shared) {
            self.init(restBaseURL: restBaseURL, wsBaseURL: wsBaseURL, auth: .device(credentials), urlSession: urlSession)
        }

        /// 开放 API Key。闭包每个请求 / 每次握手都会调一次，可以在里面做缓存和轮换
        public init(restBaseURL: URL, wsBaseURL: URL, apiKey: @escaping () throws -> String,
                    urlSession: URLSession = .shared) {
            self.init(restBaseURL: restBaseURL, wsBaseURL: wsBaseURL, auth: .apiKey(apiKey), urlSession: urlSession)
        }
    }

    public enum LiveBackend: String {
        /// Azure Voice Live
        case azure = "ws/v1/voicelive"
        /// OpenAI GPT-Live
        case openai = "ws/v1/gpt-live"
    }

    public let auth: XfAuth
    /// 设备凭证；用 API Key 构建时为 nil
    public var credentials: DeviceCredentials? { auth.deviceCredentials }
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
        self.auth = config.auth
        self.clock = clock
        let transport = RestTransport(session: config.urlSession, baseURL: config.restBaseURL,
                                      auth: config.auth, clock: clock)
        // API Key 模式 body 里不带 deviceId，服务端按 key 主体（apikey:{id}）记账
        let deviceId = config.auth.deviceCredentials?.deviceId
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
                     auth: auth, clock: clock, tools: config.tools)
    }

    /// /ws/v1/push-to-talk。config 用 `.pushToTalk`
    public func pushToTalkSession(_ config: StreamConfig) -> PushToTalkSession {
        PushToTalkSession(urlSession: self.config.urlSession, url: wsURL("ws/v1/push-to-talk"), configJSON: json(config),
                          auth: auth, clock: clock)
    }

    /// /ws/v1/asr。config 用 `.asrOnly`
    public func asrSession(_ config: StreamConfig) -> AsrSession {
        AsrSession(urlSession: self.config.urlSession, url: wsURL("ws/v1/asr"), configJSON: json(config),
                   auth: auth, clock: clock)
    }

    /// /ws/v1/tts。config 用 `.ttsOnly`
    public func ttsSession(_ config: StreamConfig) -> TTSSession {
        TTSSession(urlSession: self.config.urlSession, url: wsURL("ws/v1/tts"), configJSON: json(config),
                   auth: auth, clock: clock)
    }

    /// /ws/v1/llm。config 用 `.llmOnly`
    public func llmSession(_ config: StreamConfig) -> LLMSession {
        LLMSession(urlSession: self.config.urlSession, url: wsURL("ws/v1/llm"), configJSON: json(config),
                   auth: auth, clock: clock)
    }

    /// /ws/v1/multimodal。config 用 `.multimodal`
    public func multimodalSession(_ config: StreamConfig) -> MultimodalSession {
        MultimodalSession(urlSession: self.config.urlSession, url: wsURL("ws/v1/multimodal"), configJSON: json(config),
                          auth: auth, clock: clock)
    }

    /// /ws/v1/voicelive（Azure）或 /ws/v1/gpt-live（OpenAI），两者协议一致。config 用 `.voiceLive`
    public func voiceLiveSession(_ config: StreamConfig, backend: LiveBackend = .azure) -> VoiceLiveSession {
        VoiceLiveSession(urlSession: self.config.urlSession, url: wsURL(backend.rawValue), configJSON: json(config),
                         auth: auth, clock: clock)
    }

    private func wsURL(_ path: String) -> URL { config.wsBaseURL.appendingPathComponent(path) }

    private func json(_ streamConfig: StreamConfig) -> [String: Any] {
        streamConfig.json(deviceId: credentials?.deviceId, macId: credentials?.macId)
    }
}
