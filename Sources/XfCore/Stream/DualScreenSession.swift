import Foundation

/// 双屏互译的一侧
public enum DualScreenSide: String, CaseIterable {
    case a = "A"
    case b = "B"

    public var opposite: DualScreenSide { self == .a ? .b : .a }

    var wireByte: UInt8 { self == .a ? 0x41 : 0x42 }

    init?(wireByte: UInt8) {
        switch wireByte {
        case 0x41: self = .a
        case 0x42: self = .b
        default: return nil
        }
    }
}

/// 双屏互译的 config。languageA、languageB 是两侧使用者说的语言，不能相同。
///
/// 方向由 side 决定、收音常开，所以 StreamConfig 里的 candidateLanguages、vadAutoStop 这里没有；
/// 通过 `ext` 传了服务端也会忽略。字段与 Android 的 DualScreenConfig 一一对应。
public struct DualScreenConfig {
    public let languageA: String
    public let languageB: String
    public var asrProvider = "microsoft"
    /// microsoft 只把语音段送识别；microsoft-stream 有翻译中间结果，但静音也持续送识别，常开时成本更高
    public var speechProvider = "microsoft"
    /// 非空即开启译文播报
    public var ttsProvider: String?
    /// A 侧使用者听到的音色，不设按语言取默认
    public var voiceA: String?
    /// B 侧使用者听到的音色，不设按语言取默认
    public var voiceB: String?
    public var outputFormat: String?
    public var audioFormat: StreamConfig.AudioFormat = .pcm
    public var sampleRate: Int?
    public var ext: [String: Any] = [:]
    public var extra: [String: Any] = [:]

    public init(languageA: String, languageB: String) {
        self.languageA = languageA
        self.languageB = languageB
    }

    /// 开启译文播报
    public mutating func tts(voiceA: String? = nil, voiceB: String? = nil, provider: String = "microsoft") {
        ttsProvider = provider
        self.voiceA = voiceA
        self.voiceB = voiceB
    }

    var json: [String: Any] {
        var sideA: [String: Any] = ["language": languageA]
        sideA["voiceName"] = voiceA
        var sideB: [String: Any] = ["language": languageB]
        sideB["voiceName"] = voiceB

        var params: [String: Any] = [
            "asrProvider": asrProvider,
            "speechProvider": speechProvider,
            "audioFormat": audioFormat.rawValue,
            "sides": ["A": sideA, "B": sideB],
        ]
        params["ttsProvider"] = ttsProvider
        params["outputFormat"] = outputFormat
        params["sampleRate"] = sampleRate
        if !ext.isEmpty { params["ext"] = ext }
        params.merge(extra) { _, new in new }
        return ["command": "config", "params": params]
    }
}

/// /ws/v1/dual-screen-translation：一台设备两块屏幕的面对面互译，一条连接承载 A、B 两侧。
///
/// `connect()` 后服务端自动开始两侧收音，App 持续调用 `sendPCM` 发送两侧音频即可，没有开始、结束的操作。
/// 属于某一侧的事件以 `.dualScreen` 下发，连接级事件（`.ready`、不带 side 的错误）照常下发。
public final class DualScreenSession: StreamSession {

    private let sideLock = NSLock()
    /// 两侧同时播报时帧会交错，tts_chunk 要按目标侧分别和音频帧配对
    private var ttsMetaBySide: [DualScreenSide: [[String: Any]]] = [:]
    /// 两侧是两路独立的音频流，Opus 序号和时间戳各算各的
    private var opusSeq: [DualScreenSide: UInt32] = [:]
    private var opusStart: [DualScreenSide: Date] = [:]

    /// 16kHz / 16bit / 单声道小端 PCM。每次只发一侧的音频，不要把两侧混成一路
    public func sendPCM(side: DualScreenSide, _ pcm: Data) {
        guard !pcm.isEmpty else { return }
        sendAudio(Self.prefixed(side, pcm))
    }

    /// 发送一侧的一个 Opus 包（config 需设置 `.opus`），SDK 自动做 XOP1 封装。
    /// - Parameter endOfTurn: 本句最后一个包
    public func sendOpus(side: DualScreenSide, _ opusPacket: Data, frameMs: UInt8 = 20, endOfTurn: Bool = false) {
        sideLock.lock()
        let now = Date()
        let start = opusStart[side] ?? now
        opusStart[side] = start
        let seq = opusSeq[side] ?? 0
        opusSeq[side] = seq &+ 1
        sideLock.unlock()
        let elapsed = UInt64(max(0, now.timeIntervalSince(start) * 1000))
        let frame = Xop1Frame.wrap(opusPacket, seq: seq, timestampMs: elapsed, frameMs: frameMs, endOfTurn: endOfTurn)
        sendAudio(Self.prefixed(side, frame))
    }

    /// 恢复收音，不带 side 表示两侧。连接后会自动开始，只有调用过 stop 才需要
    public func start(side: DualScreenSide? = nil) { sendCommand(Self.command("start", side)) }

    /// 暂停一侧收音，比如屏幕熄灭时。已说的内容继续翻译和播报。不带参数的 stop() 暂停两侧
    public func stop(side: DualScreenSide) { sendCommand(Self.command("stop", side)) }

    /// 中断 side 说话产生的译文播报，不带 side 表示两侧，不停止收音
    public func interrupt(side: DualScreenSide? = nil) { sendCommand(Self.command("audio_interrupt", side)) }

    static func command(_ name: String, _ side: DualScreenSide?) -> [String: Any] {
        var command: [String: Any] = ["command": name]
        command["side"] = side?.rawValue
        return command
    }

    static func prefixed(_ side: DualScreenSide, _ data: Data) -> Data {
        var frame = Data(capacity: data.count + 1)
        frame.append(side.wireByte)
        frame.append(data)
        return frame
    }

    override func recordTTSMeta(_ meta: [String: Any]) {
        guard let target = meta.str("targetSide").flatMap(DualScreenSide.init(rawValue:)) else { return }
        sideLock.lock(); defer { sideLock.unlock() }
        ttsMetaBySide[target, default: []].append(meta)
    }

    override func audioEvent(_ data: Data) -> StreamEvent? {
        guard let first = data.first else { return nil }
        guard let target = DualScreenSide(wireByte: first) else {
            return .serverError(message: "audio frame has invalid side byte: \(first)", code: nil)
        }
        sideLock.lock()
        var meta: [String: Any]?
        if ttsMetaBySide[target]?.isEmpty == false {
            meta = ttsMetaBySide[target]?.removeFirst()
        }
        sideLock.unlock()
        return .dualScreen(side: target.opposite, targetSide: target, utteranceId: meta?.str("utteranceId"),
                           event: .ttsAudio(messageIndex: meta?.int64("messageIndex") ?? -1,
                                            chunkIndex: meta?.int64("indexId") ?? -1,
                                            audio: Data(data.dropFirst())))
    }

    override func decorate(_ event: StreamEvent, json: [String: Any]) -> StreamEvent {
        guard let side = json.str("side").flatMap(DualScreenSide.init(rawValue:)) else { return event }
        let target = json.str("targetSide").flatMap(DualScreenSide.init(rawValue:)) ?? side.opposite
        return .dualScreen(side: side, targetSide: target, utteranceId: json.str("utteranceId"), event: event)
    }
}
