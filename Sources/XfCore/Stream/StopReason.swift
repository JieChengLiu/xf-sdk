import Foundation

/// `.stopped(reason:)` 的结束原因，与 Android 的 `StopReason` 一一对应。
/// 服务端以后可能新增原因，老版本 SDK 收到不认识的值时是 `.unknown`，按正常结束处理即可；
/// 原始字符串仍在 `.stopped(reason:)` 里。
public enum StopReason: Equatable {
    /// 客户端发了 stop，正常结束
    case manualStop
    /// 开启 vadAutoStop 时检测到说话结束，正常结束一轮；常开收音可重新 start
    case silenceDetected
    /// 连续 noSpeechTimeoutSeconds 秒（默认 120）没有识别结果，空闲回收；需要继续收音就重新 start
    case noSpeechTimeout
    /// ASR 时长额度已用完。不要自动重新 start，提示用户充值或联系管理员
    case asrTimeBudgetExhausted
    /// 未携带原因，或当前 SDK 版本不认识的原因
    case unknown

    public init(reason: String?) {
        switch reason {
        case "manual_stop": self = .manualStop
        case "silence_detected": self = .silenceDetected
        case "no_speech_timeout": self = .noSpeechTimeout
        case "asr_time_budget_exhausted": self = .asrTimeBudgetExhausted
        default: self = .unknown
        }
    }

    /// 服务端下发的原始值；`.unknown` 没有固定值
    public var wireValue: String? {
        switch self {
        case .manualStop: return "manual_stop"
        case .silenceDetected: return "silence_detected"
        case .noSpeechTimeout: return "no_speech_timeout"
        case .asrTimeBudgetExhausted: return "asr_time_budget_exhausted"
        case .unknown: return nil
        }
    }
}

public extension StreamEvent {
    /// 是 `.stopped` 时返回对应的 `StopReason`，其他事件返回 nil
    var stopReason: StopReason? {
        if case .stopped(let reason) = self {
            return StopReason(reason: reason)
        }
        return nil
    }
}
