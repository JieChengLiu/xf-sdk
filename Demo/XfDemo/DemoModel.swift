import AVFoundation
import Foundation
import XfCore

/// SDK 联调用的最小 App：REST（注册、翻译、合成、Chat 流式）+ 语音翻译会话（按住说话）。
/// 凭证明文存在 UserDefaults，只用于测试，正式 App 请放 Keychain。
@MainActor
final class DemoModel: ObservableObject {

    @Published var restURL: String
    @Published var wsURL: String
    @Published var deviceId: String
    @Published var macId: String
    @Published var secret: String
    @Published var productKey: String

    @Published var inputText = "你好，今天天气怎么样？"
    @Published var fromLang = "zh-CN"
    @Published var toLang = "en-US"
    @Published var voiceName = "en-US-JennyNeural"

    @Published var partial = ""
    @Published var talking = false
    @Published var logLines: [String] = []

    private var client: XfClient?
    private var session: VoiceSession?
    private var eventsTask: Task<Void, Never>?
    private var ttsPlayer: AVAudioPlayer?
    private let recorder = PcmRecorder()
    private let player = PcmPlayer()

    private let defaults = UserDefaults.standard
    private static let defaultREST = "https://transcribe.azopenai.com"
    private static let defaultWS = "wss://transcribe.azopenai.com"
    private static let chatModel = "gpt-5.4-nano"

    init() {
        restURL = defaults.string(forKey: "restURL") ?? Self.defaultREST
        wsURL = defaults.string(forKey: "wsURL") ?? Self.defaultWS
        deviceId = defaults.string(forKey: "deviceId") ?? ""
        macId = defaults.string(forKey: "macId") ?? ""
        secret = defaults.string(forKey: "secret") ?? ""
        productKey = defaults.string(forKey: "productKey") ?? ""
        if !trimmed(deviceId).isEmpty && !trimmed(secret).isEmpty { initClient() }
    }

    // MARK: 配置

    func saveAndInit() {
        save()
        initClient()
    }

    private func save() {
        defaults.set(trimmed(restURL), forKey: "restURL")
        defaults.set(trimmed(wsURL), forKey: "wsURL")
        defaults.set(trimmed(deviceId), forKey: "deviceId")
        defaults.set(trimmed(macId), forKey: "macId")
        defaults.set(trimmed(secret), forKey: "secret")
        defaults.set(trimmed(productKey), forKey: "productKey")
    }

    private func initClient() {
        hangUp()
        client = nil
        let id = trimmed(deviceId)
        let key = trimmed(secret)
        guard !id.isEmpty, !key.isEmpty else {
            log("请先填 deviceId 和 deviceSecret，或用产品 Key 注册")
            return
        }
        guard let rest = URL(string: trimmed(restURL)), let ws = URL(string: trimmed(wsURL)) else {
            log("地址格式不对")
            return
        }
        // secret 每次签名时现取，SDK 不缓存
        let credentials = DeviceCredentials(deviceId: id, macId: trimmed(macId)) { key }
        client = XfClient(config: .init(restBaseURL: rest, wsBaseURL: ws, credentials: credentials))
        log("已初始化 deviceId=\(id) rest=\(rest) ws=\(ws)")
    }

    private func requireClient() -> XfClient? {
        if client == nil { log("还没初始化，先点「保存并初始化」") }
        return client
    }

    // MARK: REST

    func register() {
        let key = trimmed(productKey)
        let mac = trimmed(macId)
        guard !key.isEmpty, !mac.isEmpty else {
            log("注册需要产品 API Key 和 macId")
            return
        }
        guard let rest = URL(string: trimmed(restURL)) else {
            log("REST 地址格式不对")
            return
        }
        let previousId = trimmed(deviceId)
        log("注册中 macId=\(mac) …")
        Task {
            do {
                let reg = try await DeviceRegistrar(restBaseURL: rest)
                    .register(productApiKey: key, macId: mac, deviceId: previousId.isEmpty ? nil : previousId)
                deviceId = reg.deviceId
                secret = reg.deviceSecret
                log("注册成功 \(reg)")
                saveAndInit()
            } catch {
                logError("注册", error)
            }
        }
    }

    func translate() {
        guard let client = requireClient() else { return }
        let text = trimmed(inputText)
        log("翻译 zh-Hans → en：\(text)")
        Task {
            do {
                let result = try await client.translate.text(text, from: "zh-Hans", to: "en")
                log("译文：\(result.text)（计费 \(result.used) 字）")
            } catch {
                logError("翻译", error)
            }
        }
    }

    func synthesize() {
        guard let client = requireClient() else { return }
        let text = trimmed(inputText)
        log("合成 zh-CN-XiaoxiaoNeural：\(text)")
        Task {
            do {
                let result = try await client.tts.synthesize(
                    TTSRequest(text: text, languageCode: "zh-CN", voiceName: "zh-CN-XiaoxiaoNeural"))
                log("音频 \(result.audio.count) 字节，格式 \(result.audioFormat ?? result.contentType ?? "?")")
                activateAudioSession()
                ttsPlayer = try AVAudioPlayer(data: result.audio)
                ttsPlayer?.play()
            } catch {
                logError("合成", error)
            }
        }
    }

    func chat() {
        guard let client = requireClient() else { return }
        let text = trimmed(inputText)
        log("Chat：\(text)")
        Task {
            var answer = ""
            do {
                for try await chunk in client.chat.stream(ChatAPI.request(model: Self.chatModel, messages: [.user(text)])) {
                    if let delta = chunk.delta {
                        answer += delta
                        partial = answer
                    }
                }
                log("回答：\(answer)")
            } catch {
                logError("Chat（已收到：\(answer)）", error)
            }
        }
    }

    // MARK: 语音翻译

    func startTalking() {
        talking = true
        Task {
            guard await Self.requestMicPermission() else {
                talking = false
                log("没有麦克风权限：设置 → XF SDK Demo → 麦克风")
                return
            }
            // 权限弹窗期间可能已经松手
            guard talking, let session = ensureSession() else { return }
            activateAudioSession()
            player.flush()
            partial = ""
            // connect() 之后可以立刻 start / 发音频，SDK 会排队到 configOk
            session.start()
            do {
                try recorder.start { [weak session] pcm in session?.sendPCM(pcm) }
            } catch {
                log("麦克风打开失败：\(error)")
            }
        }
    }

    func stopTalking() {
        guard talking else { return }
        talking = false
        recorder.stop()
        session?.stop()
    }

    func hangUp() {
        recorder.stop()
        talking = false
        session?.close()
        session = nil
        eventsTask?.cancel()
        eventsTask = nil
    }

    private func ensureSession() -> VoiceSession? {
        if let session = session { return session }
        guard let client = requireClient() else { return nil }
        let voice = trimmed(voiceName)
        var config = StreamConfig.voiceTranslation(from: trimmed(fromLang), to: trimmed(toLang))
        if !voice.isEmpty { config.tts(voiceName: voice) }
        // 下发原始 PCM，PcmPlayer 直接播；默认是 mp3
        config.outputFormat = "pcm"
        log("连接语音翻译 \(trimmed(fromLang)) → \(trimmed(toLang))，播报 \(voice.isEmpty ? "关" : voice)")

        let session = client.voiceSession(config)
        self.session = session
        session.connect()
        eventsTask = Task { [weak self] in
            do {
                for try await event in session.events {
                    self?.handle(event)
                }
                self?.sessionEnded(session, error: nil)
            } catch {
                self?.sessionEnded(session, error: error)
            }
        }
        return session
    }

    private func handle(_ event: StreamEvent) {
        switch event {
        case .asrPartial(let text, _):
            partial = text
        case .asrFinal(let text, _, _, _):
            log("识别：\(text)")
        case .translation(_, let translated, _, _):
            log("译文：\(translated)")
        case .ttsAudio(_, _, let audio):
            player.enqueue(audio)
        case .audioInterrupt:
            player.flush()
        case .ready:
            log("会话就绪")
        case .serverError(let message, let code):
            log("服务端错误：\(message) code=\(code ?? "nil")")
        case .ttsEnd, .ttsComplete:
            break
        default:
            log("事件：\(event)")
        }
    }

    private func sessionEnded(_ ended: VoiceSession, error: Error?) {
        // 断开后马上重连时，旧会话晚到的结束不能清掉新会话
        guard session === ended else { return }
        session = nil
        recorder.stop()
        talking = false
        guard let error = error else {
            log("会话关闭")
            return
        }
        logError("语音会话", error)
        if (error as? XfError)?.kind == .signatureInvalid {
            log("握手被拒：检查 deviceId / secret；手机时间不准时先点一次「翻译」等 REST 接口校准时钟")
        }
    }

    // MARK: 音频

    private func activateAudioSession() {
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try audio.setActive(true)
        } catch {
            log("音频会话设置失败：\(error)")
        }
    }

    private static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
        }
    }

    // MARK: 日志

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func log(_ message: String) {
        logLines.append("\(Self.timeFormatter.string(from: Date()))  \(message)")
    }

    private func logError(_ what: String, _ error: Error) {
        if let xf = error as? XfError {
            log("\(what) 失败：kind=\(xf.kind) serverCode=\(xf.serverCode.map(String.init) ?? "nil") \(xf.message)")
        } else {
            log("\(what) 失败：\(error)")
        }
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
