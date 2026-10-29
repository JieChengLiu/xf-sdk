import Foundation

/// 端侧降噪：16kHz / 16bit / 单声道 PCM，纯 Swift 实现，不依赖模型和原生库。
///
/// 算法：512 点短时傅里叶变换（32ms 帧、16ms 帧移、sqrt-Hann 窗），每个频点用 MCRA 最小值跟踪
/// 估计噪声谱，按判决引导的先验信噪比做维纳滤波，增益不低于 `maxAttenuationDb` 对应的下限。
///
/// - 对风扇、空调、电流声、车内等稳态噪声有效；旁人说话、键盘、音乐这类非稳态噪声压不干净。
/// - 噪声谱需要约 1 秒自适应，刚开始的一小段降噪效果偏弱。
/// - 输出比输入固定延迟 `latencySamples` 个样本（32ms），`process` 返回与输入等长的数据，可直接接 sendPCM。
/// - 一个实例对应一路连续音频，不是线程安全的；换一段不相关的音频前调用 `reset()`。
///
/// 与 Android 版 NoiseSuppressor.kt 逐步对应，两端用 test-vectors/noise-suppressor.json 校验输出一致。
public final class NoiseSuppressor {

    public static let sampleRate = 16_000
    /// 输出相对输入的固定延迟（样本数）
    public static let latencySamples = 512

    private static let frame = 512
    private static let hop = 256
    private static let bins = frame / 2 + 1

    private static let smoothPower = 0.8      // 功率谱时间平滑
    private static let minWindowFrames = 62   // 最小值跟踪窗口 ≈ 1s
    private static let presenceRatio = 5.0    // 平滑功率 / 最小值超过它判为有语音
    private static let smoothPresence = 0.2   // 语音存在概率平滑
    private static let smoothNoise = 0.95     // 无语音时噪声谱更新的平滑系数
    private static let decisionDirected = 0.98
    private static let eps = 1e-12

    private static let window: [Double] = (0..<frame).map { (0.5 - 0.5 * cos(2.0 * Double.pi * Double($0) / Double(frame))).squareRoot() }
    private static let cosTable: [Double] = (0..<frame / 2).map { cos(2.0 * Double.pi * Double($0) / Double(frame)) }
    private static let sinTable: [Double] = (0..<frame / 2).map { sin(2.0 * Double.pi * Double($0) / Double(frame)) }
    private static let bitReverse: [Int] = (0..<frame).map { i in
        var reversed = 0
        var value = i
        var bits = frame.trailingZeroBitCount
        while bits > 0 {
            reversed = (reversed << 1) | (value & 1)
            value >>= 1
            bits -= 1
        }
        return reversed
    }

    private let gainFloor: Double

    private var previousHop = [Double](repeating: 0, count: hop)
    private var currentHop = [Double](repeating: 0, count: hop)
    private var hopFill = 0
    private var overlap = [Double](repeating: 0, count: hop)
    private var output = [Int16](repeating: 0, count: hop * 4)
    private var outputStart = 0
    private var outputCount = 0
    private var framesProcessed = 0

    private var re = [Double](repeating: 0, count: frame)
    private var im = [Double](repeating: 0, count: frame)
    private var smoothed = [Double](repeating: 0, count: bins)
    private var minimum = [Double](repeating: 0, count: bins)
    private var minimumCandidate = [Double](repeating: 0, count: bins)
    private var presence = [Double](repeating: 0, count: bins)
    private var noise = [Double](repeating: 0, count: bins)
    private var previousGain = [Double](repeating: 1, count: bins)
    private var previousSnr = [Double](repeating: 1, count: bins)
    private var gain = [Double](repeating: 0, count: bins)

    /// - Parameter maxAttenuationDb: 最大衰减量（dB），越大降噪越狠、越可能伤到语音；0 表示不降噪只延迟。默认 15。
    public init(maxAttenuationDb: Double = 15) {
        precondition((0...60).contains(maxAttenuationDb), "maxAttenuationDb must be within 0..60: \(maxAttenuationDb)")
        gainFloor = pow(10.0, -maxAttenuationDb / 20.0)
        reset()
    }

    /// 清空所有状态，下一次 `process` 当作新的一段音频开始
    public func reset() {
        for i in 0..<Self.hop { previousHop[i] = 0; overlap[i] = 0; output[i] = 0 }
        hopFill = 0
        outputStart = 0
        // 帧 k 处理完才能输出第 k-1 个帧移的样本；再预置一个帧移的静音，保证任意长度的调用都能返回等长数据。
        // 两者合起来就是 latencySamples。
        outputCount = Self.hop
        framesProcessed = 0
        for k in 0..<Self.bins { presence[k] = 0; previousGain[k] = 1; previousSnr[k] = 1 }
    }

    /// 处理一段 PCM 样本，返回等长的降噪结果（整体延迟 `latencySamples`）
    public func process(_ pcm: [Int16]) -> [Int16] {
        for sample in pcm {
            currentHop[hopFill] = Double(sample) / 32768.0
            hopFill += 1
            if hopFill == Self.hop {
                processFrame()
                hopFill = 0
            }
        }
        var result = [Int16](repeating: 0, count: pcm.count)
        for i in 0..<pcm.count {
            result[i] = output[outputStart]
            outputStart = (outputStart + 1) % output.count
        }
        outputCount -= pcm.count
        return result
    }

    /// 小端 16bit PCM 字节版本，可直接把麦克风数据传进来、结果传给 sendPCM。字节数必须是偶数
    public func process(_ pcm: Data) -> Data {
        precondition(pcm.count % 2 == 0, "PCM16 byte length must be even: \(pcm.count)")
        let bytes = [UInt8](pcm)
        var samples = [Int16](repeating: 0, count: bytes.count / 2)
        for i in 0..<samples.count {
            samples[i] = Int16(bitPattern: UInt16(bytes[i * 2]) | (UInt16(bytes[i * 2 + 1]) << 8))
        }
        let processed = process(samples)
        var out = [UInt8](repeating: 0, count: bytes.count)
        for i in 0..<processed.count {
            let v = UInt16(bitPattern: processed[i])
            out[i * 2] = UInt8(v & 0xff)
            out[i * 2 + 1] = UInt8(v >> 8)
        }
        return Data(out)
    }

    private func processFrame() {
        let hop = Self.hop, frame = Self.frame
        for i in 0..<hop {
            re[i] = previousHop[i] * Self.window[i]
            re[hop + i] = currentHop[i] * Self.window[hop + i]
        }
        for i in 0..<frame { im[i] = 0 }
        fft(inverse: false)
        estimateGain()
        for k in 0..<Self.bins {
            re[k] *= gain[k]
            im[k] *= gain[k]
            if k >= 1 && k < frame / 2 {
                re[frame - k] *= gain[k]
                im[frame - k] *= gain[k]
            }
        }
        fft(inverse: true)

        framesProcessed += 1
        for i in 0..<hop { appendOutput(overlap[i] + re[i] * Self.window[i]) }
        for i in 0..<hop { overlap[i] = re[hop + i] * Self.window[hop + i] }
        for i in 0..<hop { previousHop[i] = currentHop[i] }
    }

    private func estimateGain() {
        let first = framesProcessed == 0
        let restartWindow = framesProcessed > 0 && framesProcessed % Self.minWindowFrames == 0
        for k in 0..<Self.bins {
            let power = re[k] * re[k] + im[k] * im[k]
            if first {
                smoothed[k] = power
                minimum[k] = power
                minimumCandidate[k] = power
                noise[k] = power
            } else {
                smoothed[k] = Self.smoothPower * smoothed[k] + (1 - Self.smoothPower) * power
                if restartWindow {
                    minimum[k] = min(minimumCandidate[k], smoothed[k])
                    minimumCandidate[k] = smoothed[k]
                } else {
                    minimum[k] = min(minimum[k], smoothed[k])
                    minimumCandidate[k] = min(minimumCandidate[k], smoothed[k])
                }
                let speech = smoothed[k] > Self.presenceRatio * max(minimum[k], Self.eps) ? 1.0 : 0.0
                presence[k] = Self.smoothPresence * presence[k] + (1 - Self.smoothPresence) * speech
                let alpha = Self.smoothNoise + (1 - Self.smoothNoise) * presence[k]
                noise[k] = alpha * noise[k] + (1 - alpha) * power
            }
            let snr = power / max(noise[k], Self.eps)
            let prior = Self.decisionDirected * previousGain[k] * previousGain[k] * previousSnr[k] +
                (1 - Self.decisionDirected) * max(snr - 1, 0)
            let g = max(prior / (1 + prior), gainFloor)
            gain[k] = g
            previousGain[k] = g
            previousSnr[k] = snr
        }
    }

    private func appendOutput(_ value: Double) {
        if outputCount == output.count {
            var grown = [Int16](repeating: 0, count: output.count * 2)
            for i in 0..<outputCount { grown[i] = output[(outputStart + i) % output.count] }
            output = grown
            outputStart = 0
        }
        let scaled = (value * 32768.0 + 0.5).rounded(.down)
        output[(outputStart + outputCount) % output.count] = Int16(min(32767.0, max(-32768.0, scaled)))
        outputCount += 1
    }

    /// 原地基 2 复数 FFT；逆变换带 1/N
    private func fft(inverse: Bool) {
        let n = Self.frame
        for i in 0..<n {
            let j = Self.bitReverse[i]
            if j > i {
                re.swapAt(i, j)
                im.swapAt(i, j)
            }
        }
        let sign = inverse ? 1.0 : -1.0
        var size = 2
        while size <= n {
            let half = size / 2
            let step = n / size
            var start = 0
            while start < n {
                for j in 0..<half {
                    let wr = Self.cosTable[j * step]
                    let wi = sign * Self.sinTable[j * step]
                    let a = start + j
                    let b = a + half
                    let tr = re[b] * wr - im[b] * wi
                    let ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr
                    im[b] = im[a] - ti
                    re[a] += tr
                    im[a] += ti
                }
                start += size
            }
            size *= 2
        }
        if inverse {
            for i in 0..<n {
                re[i] = re[i] / Double(n)
                im[i] = im[i] / Double(n)
            }
        }
    }
}
